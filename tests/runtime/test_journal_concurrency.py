from __future__ import annotations

import hashlib
import json
import multiprocessing
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "runtime"))
from aec_runtime.audit import ExecutionJournal, AuditTrail, _journal_file_lock

DAY = "2026-11-02"


def _writer(directory, worker, count, start):
    journal = ExecutionJournal(Path(directory))
    if not start.wait(15):
        raise RuntimeError("Writer start was not signalled")
    for number in range(count):
        journal.write({"recordedAtUtc": DAY + "T00:00:00Z", "worker": worker,
                       "number": number, "payload": "家具" * 1000})


def _holder(path, ready, release):
    with _journal_file_lock(Path(path), 5):
        ready.set()
        if not release.wait(15):
            raise RuntimeError("Lock release was not signalled")


class JournalConcurrencyTests(unittest.TestCase):
    def assert_chain(self, path, expected_count):
        records = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(expected_count, len(records))
        previous = "0" * 64
        for record in records:
            self.assertEqual(previous, record["previousHash"])
            digest = record.pop("recordHash")
            encoded = json.dumps(record, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
            self.assertEqual(digest, hashlib.sha256(encoded.encode("utf-8")).hexdigest())
            previous = digest
        return records

    def test_two_journal_objects_alternate_without_cached_hash_fork(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first, second = ExecutionJournal(root), ExecutionJournal(root)
            for number, writer in enumerate((first, second, first, second)):
                writer.write({"recordedAtUtc": DAY, "number": number})
            self.assert_chain(root / (DAY + ".jsonl"), 4)

    def test_two_real_processes_append_one_valid_shared_chain(self):
        context = multiprocessing.get_context("spawn")
        with tempfile.TemporaryDirectory() as directory:
            start = context.Event()
            workers = [context.Process(target=_writer, args=(directory, worker, 80, start)) for worker in ("a", "b")]
            try:
                for worker in workers:
                    worker.start()
                start.set()
                for worker in workers:
                    worker.join(30)
                    self.assertFalse(worker.is_alive(), "Journal worker exceeded bounded timeout")
                    self.assertEqual(0, worker.exitcode)
                records = self.assert_chain(Path(directory) / (DAY + ".jsonl"), 160)
                self.assertEqual({(worker, number) for worker in ("a", "b") for number in range(80)},
                                 {(record["worker"], record["number"]) for record in records})
            finally:
                for worker in workers:
                    if worker.is_alive():
                        worker.terminate()
                        worker.join(5)

    def test_last_record_larger_than_64k_is_read_in_full(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ExecutionJournal(root).write({"recordedAtUtc": DAY, "payload": "柜" * 100000})
            ExecutionJournal(root).write({"recordedAtUtc": DAY, "event": "after-large"})
            self.assert_chain(root / (DAY + ".jsonl"), 2)

    def test_valid_unterminated_final_line_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            journal = ExecutionJournal(root)
            journal.write({"recordedAtUtc": DAY, "event": "first"})
            path = root / (DAY + ".jsonl")
            path.write_bytes(path.read_bytes().rstrip(b"\n"))
            original = path.read_bytes()
            journal.write({"recordedAtUtc": DAY, "event": "second"})
            self.assertTrue(path.read_bytes().startswith(original + b"\n"))
            self.assert_chain(path, 2)

    def test_corrupt_tail_refuses_append_without_touching_existing_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / (DAY + ".jsonl")
            original = b'{"partial":'
            path.write_bytes(original)
            with self.assertRaisesRegex(ValueError, "invalid final record"):
                ExecutionJournal(root).write({"recordedAtUtc": DAY})
            self.assertEqual(original, path.read_bytes())

    def test_process_lock_timeout_is_bounded_and_does_not_modify_journal(self):
        context = multiprocessing.get_context("spawn")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            journal = ExecutionJournal(root, lock_timeout=0.1)
            journal.write({"recordedAtUtc": DAY, "event": "before"})
            path = root / (DAY + ".jsonl")
            original = path.read_bytes()
            ready, release = context.Event(), context.Event()
            holder = context.Process(target=_holder, args=(str(path) + ".lock", ready, release))
            try:
                holder.start()
                self.assertTrue(ready.wait(15))
                started = time.monotonic()
                with self.assertRaisesRegex(TimeoutError, "journal lock"):
                    journal.write({"recordedAtUtc": DAY, "event": "blocked"})
                self.assertLess(time.monotonic() - started, 2)
                self.assertEqual(original, path.read_bytes())
            finally:
                release.set()
                holder.join(15)
                if holder.is_alive():
                    holder.terminate()
                    holder.join(5)
            self.assertEqual(0, holder.exitcode)
            journal.write({"recordedAtUtc": DAY, "event": "after"})
            self.assert_chain(path, 2)

    def test_task_tokens_remain_redacted_before_shared_journal_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            journal = ExecutionJournal(root)
            trail = AuditTrail(sink=journal.write)
            trail.record("correlation", "task", {"taskToken": "private-task", "token": "private-owner"})
            path = next(root.glob("*.jsonl"))
            self.assertNotIn("private-task", path.read_text())
            self.assertNotIn("private-owner", path.read_text())
            self.assert_chain(path, 1)

    def test_same_object_thread_lock_timeout_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = ExecutionJournal(Path(directory), lock_timeout=0.05)
            journal._lock.acquire()
            try:
                started = time.monotonic()
                with self.assertRaisesRegex(TimeoutError, "journal thread lock"):
                    journal.write({"recordedAtUtc": DAY})
                self.assertLess(time.monotonic() - started, 1)
                self.assertFalse(list(Path(directory).glob("*.jsonl")))
            finally:
                journal._lock.release()


if __name__ == "__main__":
    unittest.main()
