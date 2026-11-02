"""Development test client of the same Runtime/provider contract used by MCP.

No Autodesk API calls live here. Tokens stay in a local lease file, not stdout.
This is not an installer or a replacement public distribution path.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "runtime"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["submit", "poll", "renew", "release", "cancel", "status", "step", "capture", "info"])
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--owner", default="test-agent")
    parser.add_argument("--lease-file", default="task.lease.private.json")
    parser.add_argument("--name", default="Furniture modeling task")
    parser.add_argument("--code-file", type=Path)
    parser.add_argument("--mode", choices=["read", "write"], default="write")
    parser.add_argument("--document-title")
    parser.add_argument("--view-id", type=int)
    parser.add_argument("--output", default="result.json")
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    run = args.run_dir.resolve(strict=True)
    run.relative_to((ROOT / "output/multi-agent-2024").resolve())
    for name in (args.lease_file, args.output):
        if Path(name).name != name or ".." in name:
            raise ValueError("Output must be a filename inside the run directory")
    os.environ["BIM_BRIDGE_INSTANCE_DIR"] = str(run / "instances")
    os.environ["BIM_BRIDGE_JOURNAL_DIR"] = str(run / "journal-coordinated")
    from aec_runtime import BimBridgeRuntime
    from aec_runtime.coordination import COORDINATION_PROVIDER_ID
    from aec_runtime.audit import _redact
    runtime = BimBridgeRuntime()
    # Discovery is part of acceptance; the driver does not invent a capability.
    runtime.list_providers(probe=True)
    runtime.search_provider_tools("task", COORDINATION_PROVIDER_ID, 20)
    values = {"instanceId": args.instance_id}
    lease_path = run / args.lease_file
    if args.action in {"poll", "renew", "release", "cancel", "step", "capture"}:
        lease = json.loads(lease_path.read_text(encoding="utf-8"))
        if lease["instanceId"] != args.instance_id:
            raise ValueError("Lease belongs to another instance")
        values.update(taskId=lease["task"]["taskId"], token=lease["token"])
    if args.action == "info":
        result = runtime.document_info(values)
    elif args.action == "capture":
        capture = {"instanceId": args.instance_id, "taskId": values["taskId"],
                   "taskToken": values["token"], "fileStem": Path(args.output).stem.replace(".", "-"),
                   "pixelSize": 1600}
        if args.view_id is not None:
            capture["viewId"] = args.view_id
        runtime.provider_schema("revit.connector.v1", "capture_view")
        result = runtime.invoke_provider("revit.connector.v1", "capture_view", capture, "read", False, 60)
    else:
        tool = "task_" + args.action
        access = runtime.provider_schema(COORDINATION_PROVIDER_ID, tool)["access"]
        if args.action == "submit":
            if lease_path.exists():
                raise ValueError("Refusing to overwrite a task lease; poll or use a new name")
            values.update(name=args.name, owner=args.owner, leaseSeconds=300)
        if args.action == "renew":
            values["leaseSeconds"] = 300
        if args.action == "step":
            if args.code_file is None or not args.document_title:
                raise ValueError("Step requires a prepared code file and expected document title")
            values.update(code=args.code_file.read_text(encoding="utf-8-sig"),
                          description=args.name, mode=args.mode,
                          documentTitle=args.document_title, timeoutSeconds=120)
        # Preview every write before execution, retaining the existing policy path.
        preview = runtime.invoke_provider(COORDINATION_PROVIDER_ID, tool, values, access, access == "write", 120)
        result = runtime.invoke_provider(COORDINATION_PROVIDER_ID, tool, values, access, False, 120) if args.execute and access == "write" else preview
        if args.action == "submit" and args.execute:
            lease_path.write_text(json.dumps({**result, "instanceId": args.instance_id}, indent=2), encoding="utf-8")
    safe = _redact(result)
    (run / args.output).write_text(json.dumps(safe, indent=2, ensure_ascii=False), encoding="utf-8")
    status = result.get("status", (result.get("task") or {}).get("status", "ok"))
    print(json.dumps({"action": args.action, "status": status, "evidence": str(run / args.output)}, ensure_ascii=False))
    return 1 if status in {"failed", "rejected", "expired", "cancelled"} else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
