"""Verify independent ownership and concurrent native reads on two disposable hosts."""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "runtime"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--instances", nargs=2, required=True)
    parser.add_argument("--report", default="two-instance-acceptance.json")
    args = parser.parse_args()
    run = args.run_dir.resolve(strict=True)
    run.relative_to((ROOT / "output/multi-agent-2024").resolve())
    if len(set(args.instances)) != 2 or Path(args.report).name != args.report:
        raise ValueError("Two distinct exact instances and a report filename are required")
    os.environ["BIM_BRIDGE_INSTANCE_DIR"] = str(run / "instances")
    os.environ["BIM_BRIDGE_JOURNAL_DIR"] = str(run / "two-instance-journal")
    from aec_runtime import BimBridgeRuntime
    from aec_runtime.coordination import COORDINATION_PROVIDER_ID as provider
    from aec_runtime.audit import _redact
    runtime = BimBridgeRuntime()
    report = {"passed": False, "startedAtUtc": datetime.now(timezone.utc).isoformat(), "targets": [], "ownership": [], "results": []}
    owned = []
    try:
        for instance in args.instances:
            info = runtime.document_info({"instanceId": instance})
            document = info.get("document") or {}
            if info["applicationVersion"] != "2024" or not Path(document.get("path", "")).resolve().is_relative_to(run):
                raise ValueError("Only exact disposable Revit 2024 documents may be tested")
            queue = runtime.invoke_provider(provider, "task_status", {"instanceId": instance}, "read", False, 30)
            if any(item["status"] in {"queued", "active", "draining"} for item in queue["tasks"]):
                raise ValueError("Wait until furniture agents release their tasks")
            values = {"instanceId": instance, "owner": "two-instance-test", "name": "Concurrent native read", "leaseSeconds": 300}
            runtime.invoke_provider(provider, "task_submit", values, "write", True, 30)
            submitted = runtime.invoke_provider(provider, "task_submit", values, "write", False, 30)
            credentials = {"instanceId": instance, "taskId": submitted["task"]["taskId"], "token": submitted["token"]}
            owned.append(credentials)
            report["targets"].append({"instanceId": instance, "processId": info["processId"], "document": document})
        # Prove both leases remain simultaneously active before either is released.
        report["ownership"] = [runtime.invoke_provider(provider, "task_poll", credential, "write", False, 30) for credential in owned]
        if any(item["status"] != "active" for item in report["ownership"]):
            raise RuntimeError("One instance blocked ownership of the other")
        def read(index):
            document = report["targets"][index]["document"]
            values = {**owned[index], "documentTitle": document["title"], "documentId": document["id"],
                      "mode": "read", "description": "Concurrent disposable host query", "code": "return new { title = doc.Title, modified = doc.IsModified };", "timeoutSeconds": 30}
            runtime.invoke_provider(provider, "task_step", values, "write", True, 30)
            return runtime.invoke_provider(provider, "task_step", values, "write", False, 30)
        with ThreadPoolExecutor(max_workers=2) as pool:
            report["results"] = list(pool.map(read, range(2)))
        if any(item["status"] != "succeeded" for item in report["results"]):
            raise RuntimeError("A native read failed; no replay attempted")
        report["passed"] = True
    except Exception as error:
        report["error"] = str(error)[:1000]
    finally:
        for credentials in owned:
            try:
                runtime.invoke_provider(provider, "task_release", credentials, "write", True, 30)
                runtime.invoke_provider(provider, "task_release", credentials, "write", False, 30)
            except Exception:
                report["passed"] = False
                report["cleanupRequiresAttention"] = True
        report["endedAtUtc"] = datetime.now(timezone.utc).isoformat()
        (run / args.report).write_text(json.dumps(_redact(report), indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "report": str(run / args.report)}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
