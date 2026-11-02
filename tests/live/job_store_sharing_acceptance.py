"""Windows real FILE_SHARE_DELETE contention acceptance for atomic JobStore.

Uses only a disposable temporary store. It never launches or contacts Autodesk.
Run after native benchmark timing has finished, not during it.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import sys
import tempfile
import threading
import time
from ctypes import wintypes
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'runtime'))
from aec_runtime.jobs import JobStore


def run_acceptance(hold_seconds: float = .2) -> dict:
    if os.name != 'nt':
        return {'status': 'unsupported', 'reason': 'Windows CreateFile sharing semantics required'}
    if not .1 <= hold_seconds <= .4:
        raise ValueError('Hold must be 100 through 400 ms, within the one-second promotion budget')
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                  wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    generic_read, share_read_write, open_existing, normal = 0x80000000, 0x3, 3, 0x80
    invalid = ctypes.c_void_p(-1).value
    report = {'schemaVersion': 1, 'startedUtc': datetime.now(timezone.utc).isoformat(),
              'scope': 'Temporary JobStore only; real Windows non-delete-sharing reader; no Autodesk',
              'configuredHoldSeconds': hold_seconds, 'shareFlags': 'FILE_SHARE_READ | FILE_SHARE_WRITE (no FILE_SHARE_DELETE)'}
    with tempfile.TemporaryDirectory(prefix='bimbridge-job-share-') as directory:
        store = JobStore(directory)
        store.seal()  # Establish a valid initial state without a prepared/native job.
        state_path = Path(directory) / 'state.json'
        original = state_path.read_bytes()
        handle = kernel.CreateFileW(str(state_path), generic_read, share_read_write, None, open_existing, normal, None)
        if handle in (None, invalid):
            raise ctypes.WinError(ctypes.get_last_error())
        entered = threading.Event()
        completed = threading.Event()
        callback_count = []
        failures = []
        timing = {}
        def change(state):
            callback_count.append(1)
            # Mutate legitimate queue metadata, not a mock state schema.
            state['sealed'] = False
            timing['callbackUtc'] = datetime.now(timezone.utc).isoformat()
            entered.set()
        def update():
            timing['updateStarted'] = time.perf_counter()
            try:
                store.update(change)
            except Exception as error:
                failures.append({'errorType': type(error).__name__, 'message': str(error),
                                 'winerror': getattr(error, 'winerror', None)})
            finally:
                timing['updateCompleted'] = time.perf_counter()
                completed.set()
        worker = threading.Thread(target=update, name='job-store-sharing-acceptance')
        worker.start()
        old_state_valid = False
        blocked_until_release = False
        release_time = None
        try:
            if not entered.wait(5):
                raise RuntimeError('Update callback did not enter within five seconds')
            held_start = time.perf_counter()
            # While the real handle is open, replace must remain blocked and
            # the original valid JSON must remain byte-identical.
            completed.wait(hold_seconds)
            actual_hold = time.perf_counter() - held_start
            blocked_until_release = not completed.is_set()
            old_state_valid = state_path.read_bytes() == original and json.loads(state_path.read_bytes())['sealed'] is True
            report['actualHoldSeconds'] = actual_hold
        finally:
            release_time = time.perf_counter()
            if not kernel.CloseHandle(handle):
                raise ctypes.WinError(ctypes.get_last_error())
            worker.join(5)
        if worker.is_alive():
            raise RuntimeError('Update did not terminate after sharing handle release')
        final = store.snapshot()
        duration = timing['updateCompleted'] - timing['updateStarted']
        report.update(callbackCount=len(callback_count), blockedUntilHandleRelease=blocked_until_release,
                      originalStateValidWhileLocked=old_state_valid, updateWallSeconds=duration,
                      afterHandleReleaseSeconds=max(0, timing['updateCompleted'] - release_time),
                      finalStateValid=final['schemaVersion'] == 1 and final['sealed'] is False,
                      residualTemporaryFiles=[p.name for p in Path(directory).glob('state-*.tmp')], errors=failures)
        report['status'] = 'passed' if not failures and len(callback_count) == 1 and blocked_until_release and old_state_valid and report['finalStateValid'] and duration <= 1 and not report['residualTemporaryFiles'] else 'failed'
    report['completedUtc'] = datetime.now(timezone.utc).isoformat()
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--hold-seconds', type=float, default=.2)
    args = parser.parse_args(argv)
    try:
        report = run_acceptance(args.hold_seconds)
    except Exception as error:
        report = {'schemaVersion': 1, 'status': 'failed', 'errorType': type(error).__name__,
                  'message': str(error), 'winerror': getattr(error, 'winerror', None),
                  'completedUtc': datetime.now(timezone.utc).isoformat()}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
