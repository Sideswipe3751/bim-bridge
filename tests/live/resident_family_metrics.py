"""Read prepared-family execution facts through JobStore.snapshot; never query Autodesk.

Outputs are analysis artifacts only. Stage sums overlap across workers and must
not be added to makespan; native queue/save intervals are subsets of stage wall.
"""
from __future__ import annotations
import argparse
import csv
from collections import Counter, defaultdict
from datetime import datetime, timezone
import json
import hashlib
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "runtime"))
from aec_runtime.jobs import JobStore

FAILURE_ID = "deterministic-failure"

def seconds(start, end):
    if not start or not end:
        return None
    try:
        return (datetime.fromisoformat(end.replace("Z", "+00:00")) - datetime.fromisoformat(start.replace("Z", "+00:00"))).total_seconds()
    except (ValueError, TypeError):
        return None

def stats(values):
    values = sorted(float(v) for v in values if v is not None and math.isfinite(float(v)))
    def percentile(p):
        if not values:
            return None
        i = (len(values) - 1) * p
        low = int(i)
        return values[low] + (values[min(low + 1, len(values) - 1)] - values[low]) * (i - low)
    return {"n": len(values), "sum": sum(values), "median": percentile(.5), "p95": percentile(.95), "max": max(values) if values else None}

def native_snapshots(value):
    """Nested provider/lifecycle wrappers duplicate snapshots; deduplicate by ID."""
    found = {}
    def scan(v):
        if isinstance(v, dict):
            if v.get("requestId") and ("nativeMilliseconds" in v or "queueMilliseconds" in v):
                found.setdefault(v["requestId"], v)
            for child in v.values():
                scan(child)
        elif isinstance(v, list):
            for child in v:
                scan(child)
    scan(value)
    return list(found.values())

def pid(instance):
    suffix = str(instance or "").rsplit("-", 1)[-1]
    return int(suffix) if suffix.isdigit() else None

def summarize(rows, phases, selected):
    wanted = set(selected)
    chosen = [r for r in rows if r["jobId"] in wanted]
    events = [p for p in phases if p["jobId"] in wanted]
    by_stage = {}
    for stage in sorted({p["stage"] for p in events}):
        group = [p for p in events if p["stage"] == stage]
        by_stage[stage] = {"wallSeconds": stats(p["wallSeconds"] for p in group),
                           "queueMilliseconds": stats(v for p in group for v in p["queueSamples"]),
                           "nativeMilliseconds": stats(v for p in group for v in p["nativeSamples"]),
                           "saveSeconds": stats(v for p in group for v in p["saveSamples"])}
    return {"jobCount": len(chosen), "statusCounts": dict(Counter(r["status"] for r in chosen)),
            "executionSucceeded": sum(r["executionSucceeded"] for r in chosen),
            "visualReviewedPassed": sum(r["status"] == "succeeded" for r in chosen),
            "jobWallSeconds": stats(r["wallSeconds"] for r in chosen), "stages": by_stage,
            "nativeCallbackCount": sum(p["nativeCount"] for p in events),
            "queueMilliseconds": stats(v for p in events for v in p["queueSamples"]),
            "nativeMilliseconds": stats(v for p in events for v in p["nativeSamples"]),
            "saveSeconds": stats(v for p in events for v in p["saveSamples"])}

def handoffs(rows, allow_failure_fallback=False):
    by_worker = defaultdict(list)
    for r in rows:
        if r["startedUtc"] and r["instanceId"]:
            by_worker[r["instanceId"]].append(r)
    out = []
    for worker, jobs in sorted(by_worker.items()):
        jobs.sort(key=lambda j: j["startedUtc"])
        for previous, following in zip(jobs, jobs[1:]):
            end, basis = previous["completedUtc"], "job.completedUtc"
            if not end and allow_failure_fallback:
                end, basis = previous["lastPhaseCompletedUtc"], "last-history-completedUtc fallback"
            gap = seconds(end, following["startedUtc"])
            out.append({"instanceId": worker, "previousJob": previous["jobId"], "nextJob": following["jobId"],
                        "seconds": gap, "completionBasis": basis, "measured": gap is not None})
    distribution = stats(x["seconds"] for x in out)
    return {"pairs": out, "seconds": distribution, "targetP95Seconds": 2,
            "targetMet": distribution["p95"] <= 2 if distribution["p95"] is not None else None,
            "missingPairs": sum(not x["measured"] for x in out),
            "negativePairs": sum(x["seconds"] is not None and x["seconds"] < 0 for x in out)}

def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))

def serial_comparison(run, main_snapshot, prepared_ids, wall):
    path = run / "serial-control-result.json"
    if not path.exists():
        return {"available": False}
    control = read_json(path)
    serial_dir = run / "serial-state"
    if not serial_dir.is_dir():
        return {"available": True, "source": path.name, "scopeVerified": False, "reason": "serial-state unavailable"}
    serial_snapshot = JobStore(serial_dir).snapshot(include_packages=True)
    serial_rows = serial_snapshot["jobs"]
    mapped = {key.removeprefix("serial-"): value for key, value in serial_rows.items()}
    def digest(package):
        if not isinstance(package, dict):
            return None
        value = {k: v for k, v in package.items() if k != "jobId"}
        return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")).hexdigest()
    matches = []
    comparison_ids = sorted(main_snapshot["jobs"])
    for key in comparison_ids:
        main_hash = digest(main_snapshot["jobs"][key].get("package"))
        serial_hash = digest(mapped.get(key, {}).get("package"))
        matches.append({"jobId": key, "mainPackageWithoutJobIdSha256": main_hash,
                        "serialPackageWithoutJobIdSha256": serial_hash,
                        "equal": main_hash is not None and main_hash == serial_hash})
    matching = set(mapped) == set(comparison_ids) and all(m["equal"] for m in matches)
    serial_wall = control.get("wallSeconds")
    return {"available": True, "source": path.name, "scopeVerified": matching, "packageComparisons": matches,
            "serialJobCount": len(serial_rows), "parallelJobCount": len(main_snapshot["jobs"]), "parallelPreparedJobIds": prepared_ids,
            "serialPhysicalSuccessCount": sum(r.get("executionSucceeded") is True for k, r in mapped.items() if k != FAILURE_ID),
            "serialStatusCounts": dict(Counter(r.get("status") for r in serial_rows.values())),
            "serialExecutionChecksPassed": control.get("executionChecksPassed"),
            "serialWallSeconds": serial_wall, "parallelInclusiveWallSeconds": wall,
            "serialWorkers": 1, "parallelWorkers": len({r.get("instanceId") for r in main_snapshot["jobs"].values() if r.get("instanceId")}),
            "observedRatioSerialOverParallelSameScope": serial_wall / wall if matching and isinstance(serial_wall, (int, float)) and wall and wall > 0 else None,
            "scope": "All 31 prepared packages match except jobId: 30 physical families plus one deliberate failure on each side. Ratio compares prepared execution with one versus two workers, not agent research/thinking speedup.",
            "failureCost": "Failure stage worker-resource seconds are separately retained; subtracting them directly from parallel wall would be invalid."}

def main(argv=None):
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    run = args.run_dir.resolve()
    if not (run / "job-state").is_dir():
        parser.error("Existing run-dir/job-state is required")
    snapshot = JobStore(run / "job-state").snapshot(include_packages=True)
    rows, phases, seen = [], [], set()
    for job_id, row in sorted(snapshot["jobs"].items(), key=lambda pair: pair[1].get("sequence", 0)):
        history = row.get("history", [])
        for index, h in enumerate(history):
            natives = []
            for n in native_snapshots(h):
                if n["requestId"] not in seen:
                    seen.add(n["requestId"])
                    natives.append(n)
            saves = [seconds(n.get("saveStartedAtUtc"), n.get("saveCompletedAtUtc")) for n in natives]
            phases.append({"jobId": job_id, "instanceId": row.get("instanceId"), "pid": pid(row.get("instanceId")),
                "phaseIndex": index, "stage": h.get("stage"), "outcome": h.get("outcome"),
                "startedUtc": h.get("startedUtc"), "completedUtc": h.get("completedUtc"),
                "wallSeconds": h.get("wallSeconds"), "intentionalFailureJob": job_id == FAILURE_ID,
                "nativeMilliseconds": sum(n.get("nativeMilliseconds", 0) or 0 for n in natives),
                "queueMilliseconds": sum(n.get("queueMilliseconds", 0) or 0 for n in natives),
                "saveSeconds": sum(s for s in saves if s is not None),
                "nativeCount": len(natives), "requestIds": [n["requestId"] for n in natives],
                "nativeSamples": [n["nativeMilliseconds"] for n in natives if n.get("nativeMilliseconds") is not None],
                "queueSamples": [n["queueMilliseconds"] for n in natives if n.get("queueMilliseconds") is not None],
                "saveSamples": [s for s in saves if s is not None],
                "incompleteSaveBoundaries": sum(bool(n.get("saveStartedAtUtc")) and not n.get("saveCompletedAtUtc") for n in natives),
                "nativeFailed": [dict(requestId=n["requestId"], status=n.get("status"), rolledBack=n.get("rolledBack"), errorType=n.get("errorType"), message=n.get("message")) for n in natives if n.get("status") in ("failed", "rejected", "cancelled", "expired")]})
        rows.append({"jobId": job_id, "sequence": row.get("sequence"), "status": row.get("status"),
            "instanceId": row.get("instanceId"), "pid": pid(row.get("instanceId")),
            "intentionalFailureJob": job_id == FAILURE_ID, "executionSucceeded": row.get("executionSucceeded") is True,
            "complete": row.get("complete") is True, "visualReviewStatus": row.get("visualReviewStatus"),
            "startedUtc": row.get("startedUtc"), "completedUtc": row.get("completedUtc"),
            "lastPhaseCompletedUtc": history[-1].get("completedUtc") if history else None,
            "wallSeconds": seconds(row.get("startedUtc"), row.get("completedUtc")),
            "phaseWallSeconds": sum(h.get("wallSeconds", 0) for h in history),
            "failedStage": row.get("failedStage"), "error": row.get("error")})
    acceptance_files = sorted(run.glob("acceptance-*.json"))
    acceptance_path = acceptance_files[-1] if acceptance_files else None
    acceptance = read_json(acceptance_path) if acceptance_path else {}
    wall = acceptance.get("wallSeconds")
    prepared_ids = [r["jobId"] for r in rows if not r["intentionalFailureJob"]]
    failures = [p for p in phases if p["intentionalFailureJob"]]
    result = {"schemaVersion": 1, "generatedUtc": datetime.now(timezone.utc).isoformat(), "runDir": str(run),
        "stateRead": "JobStore.snapshot(include_packages=True); code never emitted, packages used only for canonical hash comparison", "snapshotSealed": snapshot.get("sealed"),
        "inclusive": summarize(rows, phases, [r["jobId"] for r in rows]),
        "preparedFamiliesExcludingDeliberateFailure": summarize(rows, phases, prepared_ids),
        "finalNativeWallSeconds": wall, "finalWallSource": acceptance_path.name if acceptance_path else None,
        "workers": len({r["instanceId"] for r in rows if r["instanceId"]}), "pids": sorted({r["pid"] for r in rows if r["pid"] is not None}),
        "instances": snapshot.get("instances"), "handoff": handoffs(rows),
        "handoffWithFailureHistoryFallback": handoffs(rows, True),
        "intentionalFailureEvidence": {"jobPresent": FAILURE_ID in snapshot["jobs"],
            "job": next((r for r in rows if r["intentionalFailureJob"]), None), "phases": failures,
            "workerResourceSeconds": sum(p["wallSeconds"] or 0 for p in failures)},
        "serialControl": serial_comparison(run, snapshot, prepared_ids, wall),
        "definitions": ["Percentiles use linear interpolation; stage wall sums overlap between workers and are not makespan.",
            "Native callback/queue/save intervals are components of stage wall, never additional time.",
            "created/started/completed timestamps are Host observations; nativeMilliseconds is monotonic callback wall, not CPU time.",
            "Latest acceptance file supplies final prepared-native execution wall only; all job/phase facts come from the locked current snapshot.",
            "Inclusive and excluding-deliberate-failure statistics are both retained; inclusive final makespan is not silently failure-adjusted.",
            "Incomplete job wall and save intervals remain missing; no duration is invented.",
            "Same-worker handoff is next.startedUtc - previous.completedUtc, not agent research or human orchestration time.",
            "Cold startup, assembly, visual review and agent thinking are outside this prepared execution scope."]}
    (run / "resident-family-metrics.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    for filename, data in (("resident-family-jobs.csv", rows), ("resident-family-phases.csv", phases)):
        with (run / filename).open("w", encoding="utf-8-sig", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(data[0]) if data else ["jobId"])
            writer.writeheader()
            for row in data:
                writer.writerow({k: json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v for k, v in row.items()})
    print(json.dumps({"metrics": str(run / "resident-family-metrics.json"), "jobs": len(rows), "nativeCallbacks": len(seen), "finalNativeWallSeconds": wall}))
    return result

if __name__ == "__main__":
    main()
