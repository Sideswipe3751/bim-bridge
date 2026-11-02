"""Bounded, agent-neutral ready queue for prepared family jobs.

This scheduler stores execution facts, never reasoning. Autodesk work belongs to
an injected backend using the ordinary Runtime policy and connector task gate.
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
import os
import re
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Protocol

from .audit import _journal_file_lock, _redact, _utc_now

MAX_STATE_BYTES = 128 * 1024 * 1024
MAX_HISTORY_BYTES = 256 * 1024
MAX_ROW_BYTES = 10 * 1024 * 1024
MAX_HISTORY = 32
MAX_REVIEWS = 128

STAGES = ("begin", "build", "verify", "prepare_view", "capture", "save_close", "release")
_SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$")


class JobError(RuntimeError):
    pass


class FailedOperation(JobError):
    """Known terminal failure: backend has authoritative non-running evidence."""
    def __init__(self, message: str, *, evidence: dict | None = None):
        super().__init__(message)
        self.evidence = evidence


class UnknownOutcome(JobError):
    """Execution may have committed or still be running; quarantine the instance."""


class JobBackend(Protocol):
    def acquire(self, instance_id: str, job: dict, lease_seconds: int) -> dict: ...
    def renew(self, instance_id: str, context: dict, lease_seconds: int) -> None: ...
    def stage(self, name: str, instance_id: str, job: dict, context: dict) -> dict: ...
    def cleanup(self, instance_id: str, job: dict, context: dict) -> bool: ...
    def reconcile(self, instance_id: str, record: dict) -> dict: ...


def validate_job(value: dict) -> dict:
    required = {"jobId", "templatePath", "documentName", "buildCode", "verifyCode", "source", "expectedDimensions"}
    if not isinstance(value, dict) or set(value) != required:
        raise ValueError("Job fields must be exactly " + ", ".join(sorted(required)))
    item = copy.deepcopy(value)
    for name in ("jobId", "documentName"):
        if not isinstance(item[name], str) or not _SAFE_NAME.fullmatch(item[name]):
            raise ValueError(name + " must be a safe bounded filename stem")
    path = item["templatePath"]
    if not isinstance(path, str) or len(path) > 2048 or not Path(path).is_absolute() or Path(path).suffix.lower() != ".rft":
        raise ValueError("templatePath must be an absolute .rft path")
    for name in ("buildCode", "verifyCode"):
        if not isinstance(item[name], str) or not item[name].strip() or len(item[name]) > 200000:
            raise ValueError(name + " must be bounded non-empty code")
    dims = item["expectedDimensions"]
    if not isinstance(dims, dict) or not {"widthMm", "depthMm", "heightMm"} <= set(dims) or set(dims) - {"widthMm", "depthMm", "heightMm", "toleranceMm"}:
        raise ValueError("expectedDimensions requires widthMm/depthMm/heightMm")
    for name, number in dims.items():
        if type(number) not in (int, float) or not math.isfinite(number) or number <= 0 or number > 100000:
            raise ValueError("Invalid expected dimension: " + name)
    if not isinstance(item["source"], (str, dict)) or len(json.dumps(item["source"], allow_nan=False)) > 16384:
        raise ValueError("source must be bounded reference metadata")
    encoded = json.dumps(item, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    if len(encoded.encode("utf-8")) > 512000:
        raise ValueError("Job package exceeds 512 KB")
    return item


def content_hash(job: dict) -> str:
    return hashlib.sha256(json.dumps(job, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")).hexdigest()


def _json_bytes(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")


def _bounded_evidence(value: Any) -> tuple[Any, bool]:
    safe = _redact(value)
    encoded = _json_bytes(safe)
    if len(encoded) <= MAX_HISTORY_BYTES - 2048:
        return safe, False
    identity = safe
    while isinstance(identity, dict) and "requestId" not in identity and isinstance(identity.get("result"), dict):
        identity = identity["result"]
    identity = identity if isinstance(identity, dict) else {}
    return {"truncated": True, "sizeBytes": len(encoded),
            "sha256": hashlib.sha256(encoded).hexdigest(), "hashBasis": "canonical-redacted-json-utf8",
            "requestId": str(identity.get("requestId", ""))[:512],
            "status": str(identity.get("status", ""))[:128],
            "fullEvidence": "Inspect the original Host audit by requestId; no automatic replay"}, True


class JobStore:
    """Atomic on-disk state, protected across threads and independent clients."""
    def __init__(self, directory: Path | str, *, max_jobs: int = 128):
        if type(max_jobs) is not int or not 1 <= max_jobs <= 128:
            raise ValueError("max_jobs must be 1 through 128")
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.max_jobs = max_jobs
        self._mutex = threading.RLock()

    def _validate_state(self, state: dict) -> None:
        if not isinstance(state, dict) or state.get("schemaVersion") != 1 or not isinstance(state.get("jobs"), dict) or not isinstance(state.get("instances"), dict):
            raise JobError("Invalid job state; refusing recovery")
        state.setdefault("sealed", False)
        if type(state["sealed"]) is not bool or type(state.get("nextSequence")) is not int or state["nextSequence"] < 0:
            raise JobError("Invalid queue sequence/seal state")
        if len(state["jobs"]) > self.max_jobs or len(state["instances"]) > 128:
            raise JobError("Persisted queue exceeds capacity")
        sequences = set()
        statuses = {"ready", "running", "in_flight", "needs_reconcile", "failed", "awaiting_review", "succeeded", "review_failed"}
        for key, row in state["jobs"].items():
            if not isinstance(row, dict) or len(_json_bytes(row)) > MAX_ROW_BYTES:
                raise JobError("Invalid or oversized job row")
            try:
                package = validate_job(row["package"])
                valid_hash = key == row["jobId"] == package["jobId"] and content_hash(package) == row["contentHash"]
            except (KeyError, TypeError, ValueError) as error:
                raise JobError("Invalid persisted job package") from error
            if not valid_hash:
                raise JobError("Job content hash mismatch; refusing execution")
            sequence = row.get("sequence")
            if type(sequence) is not int or sequence < 0 or sequence in sequences or sequence >= state["nextSequence"] or row.get("status") not in statuses:
                raise JobError("Invalid job status/FIFO sequence")
            sequences.add(sequence)
            history = row.get("history")
            if not isinstance(history, list) or len(history) > MAX_HISTORY or any(not isinstance(h, dict) or len(_json_bytes(h)) > MAX_HISTORY_BYTES for h in history):
                raise JobError("Persisted stage history exceeds bounds")
            reviews = row.get("reviews", [])
            if not isinstance(reviews, list) or len(reviews) > MAX_REVIEWS:
                raise JobError("Persisted visual review history exceeds bounds")
            for review in reviews:
                if not isinstance(review, dict) or type(review.get("passed")) is not bool or not isinstance(review.get("reviewer"), str) or not 1 <= len(review["reviewer"]) <= 200 or not isinstance(review.get("evidence"), str) or not 1 <= len(review["evidence"]) <= 4096 or len(_json_bytes(review)) > 32768:
                    raise JobError("Invalid persisted visual review")
        for instance_id, instance in state["instances"].items():
            if not isinstance(instance_id, str) or not 1 <= len(instance_id) <= 512 or not isinstance(instance, dict) or instance.get("status") not in {"idle", "busy", "quarantined"}:
                raise JobError("Invalid persisted worker")
            if instance["status"] != "idle" and instance.get("jobId") not in state["jobs"]:
                raise JobError("Worker refers to missing job")

    def _read(self) -> dict:
        path = self.directory / "state.json"
        if not path.exists():
            return {"schemaVersion": 1, "nextSequence": 0, "sealed": False, "jobs": {}, "instances": {}}
        if path.stat().st_size > MAX_STATE_BYTES:
            raise JobError("Persisted job state exceeds 128 MiB")
        with path.open("rb") as stream:
            encoded = stream.read(MAX_STATE_BYTES + 1)
        if len(encoded) > MAX_STATE_BYTES:
            raise JobError("Persisted job state exceeds 128 MiB")
        state = json.loads(encoded)
        self._validate_state(state)
        return state

    def _write(self, state: dict) -> None:
        self._validate_state(state)
        encoded = _json_bytes(state)
        if len(encoded) > MAX_STATE_BYTES:
            raise JobError("Job state exceeds 128 MiB; existing state preserved")
        temp = self.directory / ("state-" + uuid.uuid4().hex + ".tmp")
        try:
            with temp.open("xb") as stream:
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            # Retry only promotion of this exact fsynced file. A Windows reader
            # can briefly omit FILE_SHARE_DELETE (including sync/AV readers).
            # Never rerun the update callback or any backend/native operation.
            deadline = time.monotonic() + 1.0
            delay = .01
            while True:
                try:
                    os.replace(temp, self.directory / "state.json")
                    break
                except OSError as error:
                    remaining = deadline - time.monotonic()
                    if getattr(error, "winerror", None) not in {5, 32, 33} or remaining <= 0:
                        raise
                    time.sleep(min(delay, remaining))
                    delay = min(delay * 2, .1)
        finally:
            if temp.exists():
                temp.unlink()

    def update(self, change):
        with self._mutex, _journal_file_lock(self.directory / "state.lock", 10):
            state = self._read()
            result = change(state)
            self._write(state)
            return copy.deepcopy(result)

    def snapshot(self, *, include_packages: bool = False) -> dict:
        with self._mutex, _journal_file_lock(self.directory / "state.lock", 10):
            state = copy.deepcopy(self._read())
        if not include_packages:
            for row in state["jobs"].values():
                row.pop("package", None)
        return state

    def seal(self) -> dict:
        """Close this finite producer session; workers drain all accepted jobs."""
        def close(state):
            state["sealed"] = True
            return {"sealed": True}
        return self.update(close)

    def record_review(self, job_id: str, digest: str, passed: bool, *, reviewer: str, evidence: str) -> dict:
        if type(passed) is not bool or not isinstance(reviewer, str) or not reviewer.strip() or len(reviewer) > 200 or not isinstance(evidence, str) or not evidence.strip() or len(evidence) > 4096:
            raise ValueError("Review requires explicit result, reviewer and bounded evidence")
        def review(state):
            row = state["jobs"].get(job_id)
            if not row or row["contentHash"] != digest or row.get("executionSucceeded") is not True:
                raise JobError("Review must bind a physically delivered job and its content hash")
            entry = {"passed": passed, "reviewer": reviewer, "evidence": evidence, "reviewedUtc": _utc_now()}
            if len(row.get("reviews", [])) >= MAX_REVIEWS:
                raise JobError("Review history capacity reached")
            row.setdefault("reviews", []).append(entry)
            row.update(status="succeeded" if passed else "review_failed", visualReviewStatus="passed" if passed else "failed", complete=passed)
            return {k: v for k, v in row.items() if k != "package"}
        return self.update(review)

    def submit(self, value: dict) -> dict:
        job = validate_job(value)
        digest = content_hash(job)
        def add(state):
            old = state["jobs"].get(job["jobId"])
            if old:
                if old["contentHash"] != digest:
                    raise JobError("jobId already binds different content")
                return {k: v for k, v in old.items() if k != "package"}
            if state.get("sealed") is True:
                raise JobError("Prepared job session is sealed")
            if len(state["jobs"]) >= self.max_jobs:
                raise JobError("Ready queue capacity reached")
            row = {"jobId": job["jobId"], "contentHash": digest, "package": job,
                   "sequence": state["nextSequence"], "status": "ready", "createdUtc": _utc_now(), "history": []}
            state["nextSequence"] += 1
            state["jobs"][job["jobId"]] = row
            return {k: v for k, v in row.items() if k != "package"}
        return self.update(add)


class JobScheduler:
    """One serial worker per fixed instance, with a maximum of two instances.

    A write-ahead in_flight marker closes the crash/replay gap. Unknown outcomes
    stop that worker. Restart never retries a running job or switches its host.
    """
    def __init__(self, store: JobStore, backend: JobBackend, instance_ids: list[str], *, lease_seconds: int = 120):
        if not isinstance(instance_ids, (list, tuple)) or not 1 <= len(instance_ids) <= 2 or any(not isinstance(i, str) or not i.strip() or len(i) > 512 for i in instance_ids) or len(set(instance_ids)) != len(instance_ids):
            raise ValueError("Choose one or two distinct fixed instance IDs")
        if type(lease_seconds) is not int or not 10 <= lease_seconds <= 300:
            raise ValueError("lease_seconds must be 10 through 300")
        self.store, self.backend = store, backend
        self.instance_ids, self.lease_seconds = tuple(instance_ids), lease_seconds

    def _recover(self):
        def recover(state):
            for row in state["jobs"].values():
                if row["status"] in {"running", "in_flight"}:
                    row["status"] = "needs_reconcile"
                    row["error"] = "Previous scheduler stopped during execution; no replay"
                    state["instances"][row["instanceId"]] = {"status": "quarantined", "jobId": row["jobId"]}
        self.store.update(recover)

    def _claim(self, instance_id):
        def claim(state):
            if state["instances"].get(instance_id, {}).get("status") == "quarantined":
                return None
            ready = sorted((r for r in state["jobs"].values() if r["status"] == "ready"), key=lambda r: r["sequence"])
            if not ready:
                return None
            row = ready[0]
            row.update(status="running", instanceId=instance_id, startedUtc=_utc_now())
            state["instances"][instance_id] = {"status": "busy", "jobId": row["jobId"]}
            return row
        return self.store.update(claim)

    def _mark(self, job_id, **values):
        def mark(state):
            row = state["jobs"][job_id]
            if row.get("executionSucceeded") is True:
                raise JobError("Successful delivery is immutable")
            row.update(values)
        self.store.update(mark)

    def _quarantine(self, instance_id, job_id, phase, error):
        def mark(state):
            state["jobs"][job_id].update(status="needs_reconcile", failedStage=phase, error=type(error).__name__)
            state["instances"][instance_id] = {"status": "quarantined", "jobId": job_id}
        self.store.update(mark)

    def _call(self, phase, instance_id, row, callback):
        self._mark(row["jobId"], status="in_flight", stage=phase)
        started = time.monotonic()
        started_utc = _utc_now()
        def record(outcome, **details):
            def append(state):
                state["jobs"][row["jobId"]]["history"].append({
                    "stage": phase, "startedUtc": started_utc, "completedUtc": _utc_now(),
                    "wallSeconds": time.monotonic() - started, "outcome": outcome, **details})
                state["jobs"][row["jobId"]]["status"] = "running"
            self.store.update(append)
        try:
            result = callback()
        except Exception as error:
            evidence, oversized = _bounded_evidence(getattr(error, "evidence", None))
            record("unknown" if oversized or not isinstance(error, FailedOperation) else "failed",
                   errorType=type(error).__name__, evidence=evidence)
            if oversized:
                raise UnknownOutcome("Oversized failure evidence retained by digest; inspect Host audit") from error
            raise
        safe, oversized = _bounded_evidence(result)
        if oversized:
            record("unknown", errorType="EvidenceLimitExceeded", evidence=safe)
            raise UnknownOutcome("Oversized result evidence retained by digest; inspect Host audit")
        record("succeeded", result=safe)
        return result

    def _worker(self, instance_id):
        idle_started = None
        while True:
            row = self._claim(instance_id)
            if row is None:
                if not self._wait_for_seal:
                    return
                state = self.store.snapshot()
                if state["instances"].get(instance_id, {}).get("status") == "quarantined":
                    return
                if any(job["status"] == "ready" for job in state["jobs"].values()):
                    continue
                if state.get("sealed") is True:
                    return
                idle_started = time.monotonic() if idle_started is None else idle_started
                remaining = self._idle_timeout - (time.monotonic() - idle_started)
                if remaining <= 0:
                    return
                # Sidecar locking also admits independent producer processes.
                # A short bounded wait avoids a daemon or process-local queue.
                time.sleep(min(.1, remaining))
                continue
            idle_started = None
            job, context, phase = row["package"], {}, "acquire"
            stop = threading.Event()
            renewal_error = []
            def renew():
                while not stop.wait(self.lease_seconds / 3):
                    try:
                        self.backend.renew(instance_id, context, self.lease_seconds)
                    except Exception as exc:
                        renewal_error.append(exc)
                        return
            keeper = None
            try:
                if hasattr(self.backend, "inspect"):
                    phase = "inspect"
                    context.update(self._call(phase, instance_id, row, lambda: self.backend.inspect(instance_id)))
                phase = "acquire"
                acquired = self._call(phase, instance_id, row, lambda: self.backend.acquire(instance_id, job, self.lease_seconds))
                if context.get("parkingDocument") and context["parkingDocument"] != acquired.get("parkingDocument"):
                    raise UnknownOutcome("Parking document changed between inspection and acquisition")
                context.update(acquired)
                keeper = threading.Thread(target=renew, name="family-job-lease", daemon=True)
                keeper.start()
                for phase in STAGES:
                    if renewal_error:
                        raise UnknownOutcome("Lease renewal failed")
                    if phase == "release":
                        stop.set()
                        keeper.join()
                        if renewal_error:
                            raise UnknownOutcome("Lease renewal failed before release")
                    result = self._call(phase, instance_id, row, lambda: self.backend.stage(phase, instance_id, job, context))
                    context.update(result)
                def delivered(state):
                    state["jobs"][job["jobId"]].update(status="awaiting_review", executionSucceeded=True, visualReviewStatus="pending", complete=False, completedUtc=_utc_now())
                    state["instances"][instance_id] = {"status": "idle"}
                self.store.update(delivered)
            except FailedOperation as error:
                stop.set()
                if keeper:
                    keeper.join()
                try:
                    clean = not renewal_error and self._call("cleanup", instance_id, row, lambda: {"safeClean": self.backend.cleanup(instance_id, job, context)}).get("safeClean") is True
                except Exception:
                    clean = False
                if clean:
                    def failed(state):
                        state["jobs"][job["jobId"]].update(status="failed", failedStage=phase, error=type(error).__name__)
                        state["instances"][instance_id] = {"status": "idle"}
                    self.store.update(failed)
                else:
                    self._quarantine(instance_id, job["jobId"], phase, error)
                    return
            except Exception as error:
                self._quarantine(instance_id, job["jobId"], phase, error)
                return
            finally:
                stop.set()
                if keeper:
                    keeper.join()

    def run(self, *, wait_for_seal: bool = False, idle_timeout_seconds: float = 60) -> dict:
        if type(wait_for_seal) is not bool or type(idle_timeout_seconds) not in (int, float) or not math.isfinite(idle_timeout_seconds) or not 0 < idle_timeout_seconds <= 300:
            raise ValueError("Streaming idle timeout must be positive and at most 300 seconds")
        with _journal_file_lock(self.store.directory / "run.lock", .05):
            self._wait_for_seal, self._idle_timeout = wait_for_seal, idle_timeout_seconds
            self._recover()
            worker_errors = []
            def worker_main(instance_id):
                try:
                    self._worker(instance_id)
                except Exception as error:
                    # Persistence failures cannot disappear inside a Thread.
                    worker_errors.append(error)
            workers = [threading.Thread(target=worker_main, args=(i,), name="family-job-" + i) for i in self.instance_ids]
            for worker in workers:
                worker.start()
            for worker in workers:
                worker.join()
            if worker_errors:
                raise JobError("Worker stopped without durable terminal evidence") from worker_errors[0]
        return self.store.snapshot()

    def reconcile(self, instance_id: str) -> dict:
        """Explicit inspection only. Reconciled jobs never return to ready."""
        if instance_id not in self.instance_ids:
            raise ValueError("Instance is not a configured worker")
        with _journal_file_lock(self.store.directory / "run.lock", .05):
            state = self.store.snapshot(include_packages=True)
            entry = state["instances"].get(instance_id, {})
            if entry.get("status") != "quarantined":
                raise JobError("Instance does not need reconciliation")
            row = state["jobs"][entry["jobId"]]
            evidence = self.backend.reconcile(instance_id, row)
            if evidence.get("safeClean") is not True:
                raise UnknownOutcome("Instance is not confirmed clean")
            def finish(current):
                current["jobs"][row["jobId"]].update(status="failed", reconciliation=_redact(evidence))
                current["instances"][instance_id] = {"status": "idle"}
            self.store.update(finish)
        return self.store.snapshot()
