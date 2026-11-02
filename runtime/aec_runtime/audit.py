"""Bounded, correlation-aware audit records for BIM Bridge Runtime."""

from __future__ import annotations

import hashlib
import errno
import json
import os
import threading
import time
import uuid
from contextlib import contextmanager
from copy import deepcopy
from datetime import datetime, timezone
from typing import Any, Callable
from pathlib import Path


SENSITIVE_KEYS = {
    "token",
    "taskToken",
    "sessionToken",
    "authorization",
    "code",
    "approvalGrant",
    "nonce",
    "signature",
}


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _redact(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: "[redacted]" if key.lower() in {item.lower() for item in SENSITIVE_KEYS} else _redact(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [_redact(item) for item in value]
    return value


def journal_directory(environment: dict[str, str] | None = None) -> Path:
    values = os.environ if environment is None else environment
    configured = values.get("BIM_BRIDGE_JOURNAL_DIR")
    if configured:
        return Path(configured)
    local = values.get("LOCALAPPDATA", str(Path.home()))
    return Path(local) / "BIM Bridge" / "journal"


class ExecutionJournal:
    """Append-only, hash-chained JSONL execution evidence."""

    def __init__(self, directory: Path | None = None, *, lock_timeout: float = 10.0):
        if not 0 < lock_timeout < float("inf"):
            raise ValueError("Journal lock timeout must be finite and positive")
        self.directory = journal_directory() if directory is None else Path(directory)
        self.lock_timeout = lock_timeout
        self._lock = threading.Lock()

    def write(self, record: dict[str, Any]) -> None:
        day = str(record.get("recordedAtUtc", "unknown"))[:10]
        path = self.directory / f"{day}.jsonl"
        with _journal_thread_lock(self._lock, self.lock_timeout):
            self.directory.mkdir(parents=True, exist_ok=True)
            with _journal_file_lock(path.with_suffix(path.suffix + ".lock"), self.lock_timeout):
                # Every Runtime process shares this authority. Never trust a
                # per-object cached hash after another client may have appended.
                previous = self._read_last_hash(path)
                entry = deepcopy(record)
                entry["previousHash"] = previous
                encoded = json.dumps(entry, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
                entry["recordHash"] = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
                data = (json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
                with path.open("a+b") as stream:
                    stream.seek(0, os.SEEK_END)
                    if stream.tell():
                        stream.seek(-1, os.SEEK_END)
                        if stream.read(1) != b"\n":
                            # A complete final JSON record may lack its newline.
                            # Preserve it and add the separator before appending.
                            data = b"\n" + data
                    stream.write(data)
                    stream.flush()

    @staticmethod
    def _read_last_hash(path: Path) -> str:
        if not path.is_file():
            return "0" * 64
        with path.open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            position = stream.tell()
            if position == 0:
                return "0" * 64
            tail = b""
            while position:
                count = min(position, 65536)
                position -= count
                stream.seek(position)
                tail = stream.read(count) + tail
                content = tail.rstrip(b"\r\n")
                separator = content.rfind(b"\n")
                if separator >= 0:
                    tail = content[separator + 1:]
                    break
                if position == 0:
                    tail = content
            try:
                value = json.loads(tail.decode("utf-8"))
                record_hash = value.get("recordHash") if isinstance(value, dict) else None
                if isinstance(record_hash, str) and len(record_hash) == 64 and all(c in "0123456789abcdef" for c in record_hash):
                    return record_hash
            except (UnicodeDecodeError, ValueError):
                pass
            # Never silently fork the chain or append into a partial/corrupt line.
            raise ValueError("Execution journal has an invalid final record; append refused")


@contextmanager
def _journal_thread_lock(lock: Any, timeout: float):
    if not lock.acquire(timeout=timeout):
        raise TimeoutError("Timed out acquiring execution journal thread lock")
    try:
        yield
    finally:
        lock.release()


@contextmanager
def _journal_file_lock(path: Path, timeout: float):
    """Bounded same-user process lock; the stable sidecar is never removed."""
    with path.open("a+b") as stream:
        if os.fstat(stream.fileno()).st_size == 0:
            stream.write(b"\0")
            stream.flush()
        deadline = time.monotonic() + timeout
        acquired = False
        try:
            while True:
                stream.seek(0)
                try:
                    if os.name == "nt":
                        import msvcrt
                        msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                    else:
                        import fcntl
                        fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    acquired = True
                    break
                except OSError as error:
                    if error.errno not in {errno.EACCES, errno.EAGAIN, errno.EDEADLK}:
                        raise
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError("Timed out acquiring execution journal lock") from error
                    time.sleep(min(0.01, remaining))
            yield
        finally:
            if acquired:
                stream.seek(0)
                if os.name == "nt":
                    import msvcrt
                    msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


class AuditTrail:
    def __init__(self, limit: int = 1000, sink: Callable[[dict[str, Any]], None] | None = None):
        self.limit = max(1, limit)
        self.sink = sink
        self._records: list[dict[str, Any]] = []
        self._lock = threading.Lock()

    def record(self, correlation_id: str, event: str, details: dict[str, Any]) -> str:
        audit_id = "audit-" + uuid.uuid4().hex
        record = {
            "auditId": audit_id,
            "correlationId": correlation_id,
            "event": event,
            "recordedAtUtc": _utc_now(),
            "details": _redact(deepcopy(details)),
        }
        with self._lock:
            self._records.append(record)
            del self._records[:-self.limit]
        if self.sink:
            self.sink(deepcopy(record))
        return audit_id

    def records(self, correlation_id: str | None = None) -> list[dict[str, Any]]:
        with self._lock:
            values = deepcopy(self._records)
        return [item for item in values if correlation_id in {None, item["correlationId"]}]
