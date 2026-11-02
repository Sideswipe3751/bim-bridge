"""Smoke direct contract-v2 structured reads under an existing disposable lease."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "runtime"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--lease-file", required=True)
    parser.add_argument("--view-id", type=int, required=True)
    args = parser.parse_args()
    run = args.run_dir.resolve(strict=True)
    run.relative_to((ROOT / "output/multi-agent-2024").resolve())
    if Path(args.lease_file).name != args.lease_file:
        raise ValueError("Lease must be a filename inside the run directory")
    os.environ["BIM_BRIDGE_INSTANCE_DIR"] = str(run / "instances")
    os.environ["BIM_BRIDGE_JOURNAL_DIR"] = str(run / "owned-v2-journal")
    from aec_runtime import BimBridgeRuntime
    from aec_runtime.audit import _redact
    runtime = BimBridgeRuntime()
    lease = json.loads((run / args.lease_file).read_text(encoding="utf-8"))
    info = runtime.document_info({"instanceId": args.instance_id})
    if lease["instanceId"] != args.instance_id or not Path(info["document"]["path"]).resolve().is_relative_to(run):
        raise ValueError("Exact disposable host precondition changed")
    target = {"application": info["application"], "release": info["applicationVersion"], "apiVariant": info["applicationVersion"],
              "instanceId": info["instanceId"], "processId": info["processId"], "document": info["document"]}
    base = {"kind": "execution_request", "contractVersion": 2, "adapterSession": runtime.open_adapter_session("development-v2-acceptance"),
            "target": target, "intent": "read", "timeoutSeconds": 60, "dryRun": False}
    credentials = {"taskId": lease["task"]["taskId"], "taskToken": lease["token"]}
    selection = runtime.execute({**base, "correlationId": uuid.uuid4().hex, "capabilityId": "revit.selection.read", "arguments": credentials,
                                 "verification": {"required": True, "checks": [{"id": "owned-readback", "capabilityId": "revit.selection.read", "arguments": {},
                                                                                 "expected": {"count": 0, "elements": []}}]}})
    capture = runtime.execute({**base, "correlationId": uuid.uuid4().hex, "capabilityId": "revit.view.capture",
                               "arguments": {**credentials, "viewId": args.view_id, "fileStem": "owned-v2-readback", "pixelSize": 800}})
    report = {"passed": selection["status"] == "succeeded" and selection["verification"]["status"] == "passed" and capture["status"] == "succeeded",
              "selection": selection, "capture": capture}
    (run / "owned-v2-acceptance.json").write_text(json.dumps(_redact(report), indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "report": str(run / "owned-v2-acceptance.json")}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
