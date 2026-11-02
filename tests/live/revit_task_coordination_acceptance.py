"""Read-code-only live acceptance of 15 independent MCP clients on one Revit.

Requires an exact, saved disposable Revit 2024 project under --test-root. This
driver does not create, save, close, restart, or modify any Autodesk document.
It mutates only the connector's in-memory task queue. It never retries code.
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "plugins/aec-codex/mcp-server/aec_mcp_server.py"
PROVIDER = "bimbridge.coordination.v1"
SECRETS = {"token", "tasktoken", "sessiontoken", "authorization", "code"}


def safe(value):
    if isinstance(value, dict):
        return {key: "[redacted]" if key.lower() in SECRETS else safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [safe(item) for item in value]
    return value


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


class Client:
    def __init__(self, environment):
        self.process = subprocess.Popen([sys.executable, str(SERVER)], env=environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, encoding="utf-8",
                                        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        self.lines = queue.Queue()
        self.counter = 0
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        self.err_reader = threading.Thread(target=self._drain, daemon=True)
        self.err_reader.start()
        self.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                    "clientInfo": {"name": "revit-task-live-acceptance", "version": "1"}})
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}) + "\n")
        self.process.stdin.flush()

    def _read(self):
        for line in self.process.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def _drain(self):
        # Intentionally discard stderr: diagnostic text must not expose secrets.
        for _ in self.process.stderr:
            pass

    def request(self, method, params):
        self.counter += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.counter,
                                             "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            line = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            if line is None:
                raise RuntimeError("MCP process exited")
            result = json.loads(line)
            if result.get("id") == self.counter:
                return result
        raise TimeoutError("MCP response deadline exceeded")

    def raw_call(self, name, arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})

    def call(self, name, arguments):
        value = self.raw_call(name, arguments)
        require("error" not in value and not value.get("result", {}).get("isError"), "MCP tool rejected: " + name)
        data = value.get("result", {}).get("structuredContent")
        require(isinstance(data, dict), "Missing structured MCP result: " + name)
        return data

    def task(self, name, arguments, *, dry=False, read=False):
        values = {"provider": PROVIDER, "toolName": name, "arguments": arguments}
        if not read:
            values["dryRun"] = dry
        return self.call("aec_call_provider_read" if read else "aec_call_provider_write", values)

    def task_raw(self, name, arguments):
        return self.raw_call("aec_call_provider_write", {"provider": PROVIDER, "toolName": name,
                                                        "arguments": arguments, "dryRun": False})

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            self.process.kill()
            self.process.wait(timeout=5)
        self.reader.join(timeout=1)
        self.err_reader.join(timeout=1)
        self.process.stdout.close()
        self.process.stderr.close()


def rejected(value):
    return bool(value.get("error") or value.get("result", {}).get("isError"))


def error_evidence(value):
    """Retain bounded connector denial evidence while stripping model/code data."""
    data = value.get("result", {}).get("structuredContent") or value.get("error") or {}
    text = json.dumps(safe(data), ensure_ascii=False)
    return text[:1000]


def run(args, report):
    clients, owned = [], []
    with tempfile.TemporaryDirectory(prefix="bimbridge-task-live-") as scratch:
        config = Path(scratch, "providers.json")
        config.write_text('{"schemaVersion":1,"providers":[]}', encoding="utf-8")
        environment = {**os.environ, "BIM_BRIDGE_RUNTIME_ROOT": str(ROOT / "runtime"),
                       "AEC_CODEX_RUNTIME_ROOT": str(ROOT / "runtime"),
                       "BIM_BRIDGE_PROVIDER_CONFIG": str(config), "AEC_CODEX_PROVIDER_CONFIG": str(config),
                       "BIM_BRIDGE_JOURNAL_DIR": str(args.report.parent / (args.report.stem + "-journal"))}
        if args.instance_directory:
            environment["BIM_BRIDGE_INSTANCE_DIR"] = str(args.instance_directory)
            environment["AEC_CODEX_INSTANCE_DIR"] = str(args.instance_directory)
        try:
            for _ in range(15):
                clients.append(Client(environment))
            require(len({client.process.pid for client in clients}) == 15, "MCP clients must have distinct OS processes")
            first = clients[0]
            listing = first.call("aec_list_instances", {"application": "revit", "applicationVersion": "2024"})
            match = [i for i in listing["instances"] if i.get("instanceId") == args.instance_id]
            require(len(match) == 1, "Exact Revit 2024 instance not discovered")
            require(match[0]["processId"] == args.process_id, "Revit PID changed")
            info = first.call("aec_get_document_info", {"application": "revit", "instanceId": args.instance_id})
            document = info.get("document") or {}
            require(info.get("instanceId") == args.instance_id and info.get("processId") == args.process_id, "Live connector identity changed")
            require(info.get("applicationVersion") == "2024" and "task.coordination" in info.get("capabilities", []), "Target lacks 2024 task coordination")
            require(document.get("title") == args.document_title and document.get("id") == args.document_id, "Disposable document identity mismatch")
            require(bool(document.get("path")), "Live acceptance requires a saved disposable project")
            project = Path(document["path"]).resolve()
            require(project.is_relative_to(args.test_root.resolve()), "Document is outside the disposable test root")
            report["target"] = {"instanceId": args.instance_id, "processId": args.process_id, "document": document}
            report["mcpProcessIds"] = [client.process.pid for client in clients]
            tools = first.call("aec_search_provider_tools", {"provider": PROVIDER, "query": "task", "limit": 20})["tools"]
            require(len(tools) == 7, "Expected seven coordination tools")
            for item in tools:
                shape = first.call("aec_get_provider_tool_schema", {"provider": PROVIDER, "toolName": item["name"]})
                require(shape["access"] == ("read" if item["name"] == "task_status" else "write"), "Tool risk classification changed")
            empty_status = first.task("task_status", {"instanceId": args.instance_id}, read=True)
            require(not any(t["status"] in {"active", "queued", "draining"} for t in empty_status["tasks"]), "Target already has reserved tasks")
            submit = {"instanceId": args.instance_id, "name": "acceptance-0", "owner": "acceptance-client-0", "leaseSeconds": 300}
            preview = first.task("task_submit", submit, dry=True)
            require(preview.get("executed") is False, "Submit preview did not report non-execution")
            require(first.task("task_status", {"instanceId": args.instance_id}, read=True) == empty_status, "Submit preview changed task queue")
            report["checks"].append({"name": "discovery_schema_submit_preview", "passed": True})
            for index, client in enumerate(clients):
                value = client.task("task_submit", {**submit, "name": "acceptance-" + str(index), "owner": "acceptance-client-" + str(index)})
                cred = {"instanceId": args.instance_id, "taskId": value["task"]["taskId"], "token": value["token"]}
                owned.append((client, cred))
                require(value["task"]["status"] == ("active" if index == 0 else "queued"), "Unexpected task admission order")
                report["submissionOrder"].append(cred["taskId"])
            status = first.task("task_status", {"instanceId": args.instance_id}, read=True)
            for _, cred in owned:
                require(cred["token"] not in json.dumps(status), "Public task status leaked a token")
            legacy = first.raw_call("aec_execute_read", {"application": "revit", "applicationVersion": "2024",
                                      "instanceId": args.instance_id, "documentTitle": args.document_title,
                                      "description": "Tokenless read-only code denial test", "code": "return doc.Title;", "timeoutSeconds": 15})
            require(rejected(legacy), "Tokenless legacy code bypassed task reservation")
            report["checks"].append({"name": "legacy_tokenless_denied", "passed": True, "evidence": error_evidence(legacy)})
            completed = []
            for index, (client, cred) in enumerate(owned):
                # Renew all outstanding tasks, so UI/compilation latency cannot expire
                # the tail of the queue. Renewal does not change FIFO positions.
                for other_client, other_cred in owned[index:]:
                    other_client.task("task_renew", {**other_cred, "leaseSeconds": 300})
                state = client.task("task_poll", cred)
                require(state["status"] == "active", "FIFO handoff failed")
                step = {**cred, "documentTitle": args.document_title, "documentId": args.document_id,
                        "description": "Read-only native evidence for independent client " + str(index),
                        "mode": "read", "timeoutSeconds": 30,
                        "code": "return new { title = doc.Title, modified = doc.IsModified };"}
                require(client.task("task_step", step, dry=True).get("executed") is False, "Step preview executed code")
                result = client.task("task_step", step)
                require(result.get("status") == "succeeded", "Native read step failed; no retry attempted")
                evidence = result.get("result") or {}
                require(evidence.get("title") == args.document_title, "Native step ran against an unexpected document")
                report["nativeReadEvidence"].append({"taskId": cred["taskId"], "title": evidence["title"], "modified": evidence.get("modified")})
                release = client.task("task_release", cred)
                require(release["status"] == "completed", "Task release did not complete")
                completed.append(cred["taskId"])
            require(completed == report["submissionOrder"], "Completed task order differs from submission FIFO")
            report["checks"].append({"name": "fifteen_distinct_mcp_clients_fifo_native_reads", "passed": True, "count": len(completed)})
            old_client, old = owned[0]
            stale_step = {**old, "documentTitle": args.document_title, "documentId": args.document_id,
                          "description": "Completed lease must not execute", "mode": "read", "code": "return doc.Title;", "timeoutSeconds": 10}
            denial = old_client.task_raw("task_step", stale_step)
            require(rejected(denial), "Completed task token executed another step")
            report["checks"].append({"name": "completed_token_step_denied", "passed": True, "evidence": error_evidence(denial)})
            holder = first.task("task_submit", {**submit, "name": "cancellation-holder"})
            waiter = clients[1].task("task_submit", {**submit, "name": "cancelled-waiter", "owner": "acceptance-client-1"})
            holder_cred = {"instanceId": args.instance_id, "taskId": holder["task"]["taskId"], "token": holder["token"]}
            waiter_cred = {"instanceId": args.instance_id, "taskId": waiter["task"]["taskId"], "token": waiter["token"]}
            owned.extend([(first, holder_cred), (clients[1], waiter_cred)])
            require(holder["task"]["status"] == "active" and waiter["task"]["status"] == "queued", "Cancellation fixture not queued")
            require(clients[1].task("task_cancel", waiter_cred)["status"] == "cancelled", "Waiting task did not cancel")
            require(rejected(clients[1].task_raw("task_renew", waiter_cred)), "Cancelled task was renewed")
            first.task("task_release", holder_cred)
            final = first.task("task_status", {"instanceId": args.instance_id}, read=True)
            require(not any(t["status"] in {"active", "queued", "draining"} for t in final["tasks"]), "Acceptance left an active task")
            report["checks"].append({"name": "waiting_cancellation_and_terminal_token_rejection", "passed": True})
            report["finalTasks"] = final["tasks"]
            report["passed"] = True
        finally:
            # This cleanup only requests task cancellation. It never stops Revit,
            # replays a native request, or assumes an in-flight operation stopped.
            for client, cred in reversed(owned):
                try:
                    client.task("task_cancel", cred)
                except Exception:
                    pass
            for client in clients:
                client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--process-id", required=True, type=int)
    parser.add_argument("--document-title", required=True)
    parser.add_argument("--document-id", required=True)
    parser.add_argument("--test-root", required=True, type=Path)
    parser.add_argument("--instance-directory", type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    report = {"kind": "revit_task_coordination_live_acceptance", "startedAtUtc": datetime.now(timezone.utc).isoformat(),
              "passed": False, "checks": [], "submissionOrder": [], "nativeReadEvidence": [],
              "scope": "read-code-only; no furniture or document mutation; exact disposable Revit 2024 project"}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    try:
        run(args, report)
    except Exception as exc:
        # Tool errors may embed arguments; only our bounded static exception text
        # is recorded, and recursive sensitive-key redaction applies at output.
        report["failure"] = {"type": type(exc).__name__, "message": str(exc)[:500]}
    report["endedAtUtc"] = datetime.now(timezone.utc).isoformat()
    args.report.write_text(json.dumps(safe(report), ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "report": str(args.report), "checks": len(report["checks"])}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
