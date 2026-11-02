"""Development acceptance client for resident Revit family jobs.

Never launches, kills, installs or rebuilds Autodesk. The parent launches the two
signed parking fixtures; this client uses the Runtime job API and journals.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "output" / "multi-agent-2024"
sys.path.insert(0, str(ROOT / "runtime"))


def read(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_new(path: Path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)


def run_path(path: Path) -> Path:
    if ".." in path.parts:
        raise ValueError("Traversal is forbidden")
    path = path.resolve()
    path.relative_to(OUTPUT.resolve())
    if path == OUTPUT.resolve():
        raise ValueError("A distinct run directory is required")
    return path


def result_body(value):
    while isinstance(value, dict) and isinstance(value.get("result"), dict):
        value = value["result"]
    return value


def failure_isolation_assertions(snapshot):
    """Require the intended native rollback, clean release, and later host reuse."""
    rows = snapshot.get("jobs", {})
    failed = rows.get("deterministic-failure", {})
    builds = [h for h in failed.get("history", []) if h.get("stage") == "build" and h.get("outcome") == "failed"]
    native = []
    def scan(value):
        if isinstance(value, dict):
            if value.get("kind") == "execute" and value.get("mode") == "write" and value.get("status") == "failed":
                native.append(value)
            for child in value.values():
                scan(child)
        elif isinstance(value, list):
            for child in value:
                scan(child)
    for build in builds:
        scan(build.get("evidence"))
    exact = [n for n in native if n.get("message") == "resident acceptance deterministic failure"
             and n.get("errorType") == "InvalidOperationException" and n.get("rolledBack") is True]
    cleanups = [h for h in failed.get("history", []) if h.get("stage") == "cleanup"
                and h.get("outcome") == "succeeded" and h.get("result", {}).get("safeClean") is True]
    cleaned_at = cleanups[-1].get("completedUtc", "") if cleanups else ""
    successors = [{"jobId": key, "instanceId": row.get("instanceId"), "startedUtc": row.get("startedUtc"),
                   "completedUtc": row.get("completedUtc"), "status": row.get("status")}
                  for key, row in rows.items() if key != "deterministic-failure"
                  and row.get("instanceId") == failed.get("instanceId") and cleaned_at
                  and row.get("startedUtc", "") > cleaned_at
                  and (row.get("executionSucceeded") is True or row.get("status") == "succeeded")]
    checks = {"terminalFailed": failed.get("status") == "failed",
              "failedAtBuild": failed.get("failedStage") == "build",
              "exactNativeThrowAndRollback": bool(exact),
              "cleanupSafeClean": bool(cleanups), "sameInstanceLaterSucceeded": bool(successors)}
    return {"passed": all(checks.values()), "checks": checks, "instanceId": failed.get("instanceId"),
            "failedStage": failed.get("failedStage"), "nativeFailureEvidence": exact,
            "cleanupEvidence": cleanups, "successfulSuccessors": successors}


def successful_readback(baseline: Path, job_id: str):
    # The baseline may have an explicitly recorded correction/readback. Never
    # select a failed or merely compiled write as verification evidence.
    candidates = []
    journal = baseline / "timings.jsonl"
    if journal.exists():
        for line in journal.read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            if (row.get("event") == "command_end" and row.get("jobId") == job_id
                    and "verify" in row.get("phase", "") and row.get("exitCode") == 0
                    and row.get("evidence")):
                candidates.append(baseline / row["evidence"])
    candidates.insert(0, baseline / (job_id + "-verify.json"))
    for path in reversed(candidates):
        if not path.exists():
            continue
        envelope = read(path)
        value = result_body(envelope)
        if (envelope.get("status") == "succeeded" and isinstance(value, dict)
                and (value.get("passed") is True or value.get("geometryValid") is True)):
            return path, value
    raise ValueError("No successful structured baseline readback: " + job_id)


def prepare(args):
    baseline, target = run_path(args.baseline), run_path(args.run_dir)
    jobs = read(baseline / "jobs.json")
    if len(jobs) != 30 or len({j["jobId"] for j in jobs}) != 30:
        raise ValueError("Exactly 30 distinct baseline jobs are required")
    target.mkdir(parents=True, exist_ok=True)
    prepared, evidence = [], []
    overrides = read(args.final_builds) if args.final_builds else {}
    template = args.family_template.resolve(strict=True)
    project_template = args.project_template.resolve(strict=True)
    for job in jobs:
        proof_path, measured = successful_readback(baseline, job["jobId"])
        original_build = Path(job["buildPath"])
        override = overrides.get(job["jobId"], {})
        if job["jobId"] in {"sof03", "sof05", "sof06", "sof07"} and not override:
            raise ValueError("Final corrected build provenance required: " + job["jobId"])
        build_path, verify_path = Path(override.get("buildPath", original_build)), Path(job["verifyPath"])
        build, verify = build_path.read_text(encoding="utf-8-sig"), verify_path.read_text(encoding="utf-8-sig")
        # Keep original titles: all thirty bodies contain task-specific guards.
        name = job["title"]
        if not name.startswith("BB_") or Path(name).name != name:
            raise ValueError("Unsafe baseline family title")
        dims = {}
        for axis in ("width", "depth", "height"):
            key = axis + "Mm"
            value = measured.get(key)
            if axis == "height" and value is None and "zMaxMm" in measured:
                value = measured["zMaxMm"] - measured.get("zMinMm", 0)
            dims[key] = value if value is not None else job[key]
        prepared.append({"jobId": job["jobId"], "documentName": name,
                         "templatePath": str(template), "buildCode": build, "verifyCode": verify,
                         "source": read(Path(job["sourcePath"])), "expectedDimensions": dims})
        evidence.append({"jobId": job["jobId"], "product": job["product"], "title": name,
                         "cataloguePlan": {k: job[k] for k in ("widthMm", "depthMm", "heightMm")},
                         "baselineMeasured": dims, "baselineReadback": str(proof_path),
                         "buildPath": str(build_path), "verifyPath": str(verify_path),
                         "originalBuildPath": str(original_build),
                         "originalBuildSha256": hashlib.sha256(original_build.read_bytes()).hexdigest(),
                         "finalGeometryAdjustments": override.get("reason"),
                         "buildSha256": hashlib.sha256(build.encode()).hexdigest(),
                         "verifySha256": hashlib.sha256(verify.encode()).hexdigest()})
    write_new(target / "resident-jobs.json", prepared)
    write_new(target / "baseline-provenance.json", evidence)
    for index in (1, 2):
        session = "parking" + str(index)
        parking_request = {
            "schemaVersion": 1, "runId": target.name, "sessionId": session,
            "token": secrets.token_hex(32), "version": "2024", "mode": "resident",
            "templatePath": str(project_template), "documentName": "BB_Resident_Parking%d.rvt" % index}
        request_path = target / (session + ".request.json")
        if request_path.exists():
            old = read(request_path)
            for key in parking_request:
                if key == "token":
                    continue
                equal = (Path(old[key]).resolve() == Path(parking_request[key]).resolve()
                         if key == "templatePath" else old[key] == parking_request[key])
                if not equal:
                    raise ValueError("Existing parking request differs: " + key)
        else:
            write_new(request_path, parking_request)
    # A separate opt-in scope proves deterministic failure cleanup without
    # changing any of the thirty workload jobs or their output identities.
    write_new(target / "failure-isolation-job.json", {
        "jobId": "deterministic-failure", "documentName": "BB_Deterministic_Failure",
        "templatePath": str(template), "buildCode": 'throw new InvalidOperationException("resident acceptance deterministic failure");',
        "verifyCode": "return new { passed = false };", "source": "development failure isolation",
        "expectedDimensions": {"widthMm": 1, "depthMm": 1, "heightMm": 1}})
    print(json.dumps({"status": "prepared", "runDirectory": str(target), "jobCount": len(prepared),
                      "parkingRequestPaths": [str(target / ("parking%d.request.json" % i)) for i in (1, 2)],
                      "familyWorkspace": str(target / "resident-families")}))


def run(args):
    run_dir = run_path(args.run_dir)
    ids = args.instance_id
    if len(ids) != args.workers or len(set(ids)) != len(ids):
        raise ValueError("Supply exactly one distinct instance ID per worker")
    os.environ["BIM_BRIDGE_INSTANCE_DIR"] = str(run_dir / "instances")
    os.environ["BIM_BRIDGE_JOURNAL_DIR"] = str(run_dir / "journal-runtime")
    from aec_runtime import BimBridgeRuntime
    from aec_runtime.jobs import JobStore, JobScheduler
    from aec_runtime.job_backend import RuntimeJobBackend
    runtime = BimBridgeRuntime()
    runtime.list_providers(probe=True)
    infos = [runtime.document_info({"instanceId": value}) for value in ids]
    for info in infos:
        doc = info.get("document") or {}
        if (info.get("applicationVersion") != "2024" or not doc.get("title", "").startswith("BB_Resident_Parking")
                or not Path(doc.get("path", "")).resolve().is_relative_to(run_dir)):
            raise ValueError("Exact disposable Revit 2024 parking document required")
    store = JobStore(run_dir / "job-state", max_jobs=128)
    manifest = read(run_dir / "resident-jobs.json")
    if args.failure_isolation:
        manifest = [read(run_dir / "failure-isolation-job.json")] + manifest
    for item in manifest:
        store.submit(item)
    start = time.perf_counter()
    scheduler = JobScheduler(store, RuntimeJobBackend(runtime), instance_ids=ids, lease_seconds=120)
    snapshot = scheduler.run()
    elapsed = time.perf_counter() - start
    end_infos = [runtime.document_info({"instanceId": value}) for value in ids]
    same_pids = [i.get("processId") for i in infos] == [i.get("processId") for i in end_infos]
    parked = all(before.get("document", {}).get("id") == after.get("document", {}).get("id")
                 for before, after in zip(infos, end_infos))
    rows = snapshot["jobs"]
    successful = sum(rows.get(j["jobId"], {}).get("executionSucceeded") is True or rows.get(j["jobId"], {}).get("status") == "succeeded" for j in manifest if j["jobId"] != "deterministic-failure")
    reviewed = sum(rows.get(j["jobId"], {}).get("status") == "succeeded" for j in manifest if j["jobId"] != "deterministic-failure")
    failure_assertions = failure_isolation_assertions(snapshot) if args.failure_isolation else {"requested": False, "passed": True}
    expected_failure = failure_assertions["passed"]
    phase_seconds = Counter()
    for row in rows.values():
        for event in row.get("history", []):
            phase_seconds[event["stage"]] += event["wallSeconds"]
    passed = same_pids and parked and successful == 30 and expected_failure
    # Preserve the scheduler's complete state/history, not only aggregate timings.
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    write_new(run_dir / ("acceptance-" + stamp + ".json"), {
        "workers": args.workers, "wallSeconds": elapsed, "samePids": same_pids,
        "returnedToExactParkingDocuments": parked,
        "executionChecksPassed": passed, "visualReviewComplete": reviewed == 30,
        "successfulFamilyCount": successful, "reviewedFamilyCount": reviewed,
        "jobsPerHour": successful * 3600 / elapsed if elapsed else 0,
        "phaseWallSeconds": dict(phase_seconds),
        "initialInstances": infos, "finalInstances": end_infos, "snapshot": snapshot,
        "requestedJobCount": len(manifest), "failureIsolationRequested": args.failure_isolation,
        "failureIsolationAssertions": failure_assertions})
    print(json.dumps({"status": "execution_passed_pending_visual_review" if passed else "failed", "wallSeconds": elapsed, "samePids": same_pids,
                      "successfulFamilyCount": successful,
                      "report": str(run_dir / ("acceptance-" + stamp + ".json"))}))
    return 0 if passed else 1


def simulate():
    """Offline evidence only: deterministic failure and crash/recovery fencing."""
    from aec_runtime.jobs import JobStore, JobScheduler, FailedOperation, UnknownOutcome
    class Backend:
        def __init__(self, fail=None, unknown=None):
            self.calls, self.fail, self.unknown = [], fail, unknown
        def acquire(self, instance, job, lease):
            self.calls.append((instance, job["jobId"], "acquire"))
            return {}
        def renew(self, *args):
            pass
        def stage(self, name, instance, job, context):
            self.calls.append((instance, job["jobId"], name))
            if name == "build" and job["jobId"] == self.fail:
                raise FailedOperation("deterministic simulation")
            if name == "build" and job["jobId"] == self.unknown:
                raise UnknownOutcome("simulated transport loss")
            return {"ok": True}
        def cleanup(self, *args):
            return True
        def reconcile(self, *args):
            return {"safeClean": True, "simulation": True}
    def package(job):
        return {"jobId": job, "documentName": "BB_" + job,
                "templatePath": str(ROOT / "simulated.rft"), "buildCode": "return null;",
                "verifyCode": "return true;", "source": "simulation",
                "expectedDimensions": {"widthMm": 10, "depthMm": 10, "heightMm": 10}}
    checks = []
    with tempfile.TemporaryDirectory(prefix="bimbridge-resident-acceptance-") as directory:
        store = JobStore(Path(directory) / "failure")
        store.submit(package("bad")); store.submit(package("good"))
        backend = Backend(fail="bad")
        snapshot = JobScheduler(store, backend, ["simulated-1"]).run()
        assert snapshot["jobs"]["bad"]["status"] == "failed"
        assert snapshot["jobs"]["good"].get("executionSucceeded") is True
        checks.append("deterministic failure isolated; next job succeeds on same instance")
        store = JobStore(Path(directory) / "restart")
        store.submit(package("unknown")); store.submit(package("later"))
        JobScheduler(store, Backend(unknown="unknown"), ["simulated-1"]).run()
        replacement = Backend()
        scheduler = JobScheduler(JobStore(store.directory), replacement, ["simulated-1"])
        snapshot = scheduler.run()
        assert not replacement.calls
        assert snapshot["jobs"]["unknown"]["status"] == "needs_reconcile"
        assert snapshot["jobs"]["later"]["status"] == "ready"
        scheduler.reconcile("simulated-1")
        snapshot = scheduler.run()
        assert snapshot["jobs"]["unknown"]["status"] == "failed"
        assert snapshot["jobs"]["later"].get("executionSucceeded") is True
        assert all(job != "unknown" for _, job, _ in replacement.calls)
        checks.append("restart quarantines unknown outcome; explicit reconcile never replays old job")
    print(json.dumps({"status": "passed", "scope": "offline_simulation_not_live_acceptance", "checks": checks}))
    return 0


def assembly_plan(args):
    """Stage the existing fifteen-plus-fifteen assembly only after all jobs pass."""
    run_dir, baseline = run_path(args.run_dir), run_path(args.baseline)
    from aec_runtime.jobs import JobStore
    state = JobStore(run_dir / "job-state").snapshot()
    jobs = read(run_dir / "resident-jobs.json")
    if len(jobs) != 30 or any(state["jobs"].get(j["jobId"], {}).get("status") != "succeeded" for j in jobs):
        raise ValueError("Assembly is gated on thirty successful saved/closed jobs")
    baseline_jobs = read(baseline / "jobs.json")
    original = read(baseline / "assembly30.request.json")
    # Prior assembly's first fifteen positions are preserved; remaining positions
    # match its connector-owned load code. Family titles use the new job package.
    placements = original["families"]
    if len(placements) != 15:
        raise ValueError("Expected prior fixture's fifteen-family first stage")
    artifacts = []
    for job in jobs:
        source = run_dir / "resident-families" / job["jobId"] / (job["documentName"] + ".rfa")
        source = source.resolve(strict=True)
        source.relative_to((run_dir / "resident-families").resolve())
        destination = run_dir / source.name
        if destination.exists():
            raise ValueError("Refusing staged family overwrite: " + str(destination))
        artifacts.append((source, destination))
    for source, destination in artifacts:
        with source.open("rb") as src, destination.open("xb") as dest:
            shutil.copyfileobj(src, dest)
    request = {key: original[key] for key in ("schemaVersion", "version", "mode", "templatePath")}
    request.update(runId=run_dir.name, sessionId="assembly30", token=secrets.token_hex(32),
                   documentName="BB_IKEA_Bench30_Test_Project.rvt",
                   families=[{**position, "fileName": jobs[i]["documentName"] + ".rfa"} for i, position in enumerate(placements)])
    write_new(run_dir / "assembly30.request.json", request)
    code = 'if(doc.IsFamilyDocument || doc.Title!="BB_IKEA_Bench30_Test_Project")throw new InvalidOperationException("Wrong project");\n'
    code += 'var level=new FilteredElementCollector(doc).OfClass(typeof(Level)).Cast<Level>().OrderBy(l=>Math.Abs(l.Elevation)).First();\n'
    for index, job in enumerate(jobs[15:]):
        x, y = ((12000 + index * 3500, 3500) if index < 5 else
                (33000 + (index - 5) % 5 * 1500, (index - 5) // 5 * 3500))
        path = json.dumps(str(run_dir / (job["documentName"] + ".rfa")))
        code += ('Family f{0};if(!doc.LoadFamily({1},out f{0}))throw new InvalidOperationException("Load failed");\n'
                 'var s{0}=(FamilySymbol)doc.GetElement(f{0}.GetFamilySymbolIds().First());if(!s{0}.IsActive){{s{0}.Activate();doc.Regenerate();}}\n'
                 'doc.Create.NewFamilyInstance(new XYZ({2}/304.8,{3}/304.8,level.Elevation),s{0},level,Autodesk.Revit.DB.Structure.StructuralType.NonStructural);\n').format(index, path, x, y)
    groups = {row["jobId"]: row["agent"] for row in baseline_jobs}
    code += 'var groupMap=new Dictionary<string,string>{' + ','.join(
        '{' + json.dumps(j["documentName"]) + ',' + json.dumps(groups[j["jobId"]]) + '}' for j in jobs) + '};\n'
    prior = (baseline / "assemble-remaining.cs").read_text(encoding="utf-8-sig")
    code += prior[prior.index("var all="):]
    (run_dir / "assemble-remaining.cs").write_text(code, encoding="utf-8")
    for filename in ("verify-project.cs", "project-display.cs"):
        with (run_dir / filename).open("x", encoding="utf-8") as stream:
            stream.write((baseline / filename).read_text(encoding="utf-8-sig"))
    write_new(run_dir / "assembly-artifacts.json", [
        {"source": str(s), "staged": str(d), "sha256": hashlib.sha256(d.read_bytes()).hexdigest()} for s, d in artifacts])
    print(json.dumps({"status": "assembly_prepared_not_launched", "count": 30,
                      "requestPath": str(run_dir / "assembly30.request.json"),
                      "codePath": str(run_dir / "assemble-remaining.cs")}))
    return 0


def review(args):
    """Record a completed external visual inspection against its package hash."""
    from aec_runtime.jobs import JobStore
    store = JobStore(run_path(args.run_dir) / "job-state")
    snapshot = store.snapshot()
    record = snapshot["jobs"][args.job_id]
    if record.get("executionSucceeded") is not True:
        raise ValueError("A successful delivered artifact is required for review")
    result = store.record_review(args.job_id, record["contentHash"], args.passed,
                                reviewer=args.reviewer, evidence=args.evidence)
    print(json.dumps(result))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--baseline", type=Path, default=OUTPUT / "bench-30-20261102")
    p.add_argument("--run-dir", type=Path, required=True)
    p.add_argument("--family-template", type=Path, required=True)
    p.add_argument("--project-template", type=Path, required=True)
    p.add_argument("--final-builds", type=Path, help="Job ID to final corrected buildPath/reason mapping")
    r = sub.add_parser("run")
    r.add_argument("--run-dir", type=Path, required=True)
    r.add_argument("--workers", type=int, choices=(1, 2), required=True)
    r.add_argument("--instance-id", action="append", required=True)
    r.add_argument("--failure-isolation", action="store_true")
    sub.add_parser("simulate")
    a = sub.add_parser("assembly-plan")
    a.add_argument("--run-dir", type=Path, required=True)
    a.add_argument("--baseline", type=Path, default=OUTPUT / "bench-30-20261102")
    v = sub.add_parser("review")
    v.add_argument("--run-dir", type=Path, required=True)
    v.add_argument("--job-id", required=True)
    v.add_argument("--reviewer", required=True)
    v.add_argument("--evidence", required=True, help="Actual image inspection facts and capture identity")
    decision = v.add_mutually_exclusive_group(required=True)
    decision.add_argument("--passed", dest="passed", action="store_true")
    decision.add_argument("--failed", dest="passed", action="store_false")
    args = parser.parse_args()
    if args.action == "simulate":
        return simulate()
    if args.action == "assembly-plan":
        return assembly_plan(args)
    if args.action == "review":
        return review(args)
    return prepare(args) if args.action == "prepare" else run(args)


if __name__ == "__main__":
    raise SystemExit(main())
