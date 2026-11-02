"""Real independent stdio MCP processes against one shared FAKE connector.

This verifies cross-process projection/transport, not Autodesk or the C# scheduler.
The C# scheduler and real HTTP listener are covered in TaskCoordinatorTests.
"""
from __future__ import annotations

import json
import importlib.util
import os
import queue
import secrets
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "plugins/aec-codex/mcp-server/aec_mcp_server.py"
PROVIDER = "bimbridge.coordination.v1"


class Client:
    def __init__(self, environment):
        self.process = subprocess.Popen([sys.executable, str(SERVER)], env=environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, encoding="utf-8")
        self.lines = queue.Queue()
        self.counter = 0
        def read():
            for line in self.process.stdout:
                self.lines.put(line)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                    "clientInfo": {"name": "coordination-test", "version": "1"}})

    def request(self, method, params):
        self.counter += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.counter,
                                             "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        response = json.loads(self.lines.get(timeout=20))
        if response.get("id") != self.counter:
            raise AssertionError("MCP response correlation mismatch")
        return response

    def call(self, name, arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})

    def tool(self, name, arguments, *, access="write", dry=False):
        values = {"provider": PROVIDER, "toolName": name, "arguments": arguments}
        if access == "write":
            values["dryRun"] = dry
        return self.call("aec_call_provider_" + access, values)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.reader.join(timeout=2)
        self.process.stdout.close()
        self.process.stderr.close()


class SharedFakeConnector(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def write(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        if self.headers.get("Authorization") != "Bearer " + self.server.token:
            self.write(401, {"error": "unauthorized"})
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        if self.path == "/v1/info":
            self.write(200, self.server.info)
        elif self.path == "/v1/selection":
            with self.server.lock:
                reserved = any(t["status"] in ("active", "queued") for t in self.server.tasks)
                if reserved:
                    self.server.denials += 1
                    self.write(429, {"error": "instance_reserved"})
                else:
                    self.write(200, {"ids": []})
        else:
            self.write(404, {"error": "not_found"})

    def do_POST(self):
        if not self.authorized():
            return
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        with self.server.lock:
            if payload.get("operation") != "task.control":
                holder = next((t for t in self.server.tasks if t["status"] == "active"), None)
                if holder and (payload.get("taskId") != holder["taskId"] or payload.get("taskToken") != holder["token"]):
                    self.server.denials += 1
                    self.write(429, {"error": "instance_reserved"})
                    return
                self.server.executions.append(payload)
                self.write(200, {"requestId": "fake-step", "status": "succeeded", "result": {"ok": True}, "rolledBack": False})
                return
            control = payload["taskControl"]
            action = control["action"]
            self.server.controls.append(action)
            if action == "submit":
                pending = any(t["status"] in ("active", "queued") for t in self.server.tasks)
                task = {"taskId": secrets.token_hex(12), "token": secrets.token_hex(32),
                        "name": control["name"], "owner": control["owner"],
                        "status": "queued" if pending else "active"}
                self.server.tasks.append(task)
                self.write(200, {"task": self.public(task), "token": task["token"]})
            elif action == "status":
                self.write(200, {"tasks": [self.public(t) for t in self.server.tasks]})
            else:
                task = next((t for t in self.server.tasks if t["taskId"] == control.get("taskId") and t["token"] == control.get("token")), None)
                if task is None:
                    self.write(409, {"error": "task_token_invalid"})
                    return
                if action in ("release", "cancel"):
                    task["status"] = "completed" if action == "release" else "cancelled"
                    if not any(t["status"] == "active" for t in self.server.tasks):
                        next_task = next((t for t in self.server.tasks if t["status"] == "queued"), None)
                        if next_task:
                            next_task["status"] = "active"
                self.write(200, self.public(task))

    @staticmethod
    def public(task):
        return {key: value for key, value in task.items() if key != "token"}


class CoordinationMcpTests(unittest.TestCase):
    def test_task_domain_terminal_states_are_successful_commands_only_for_known_controls(self):
        spec = importlib.util.spec_from_file_location("coordination_mcp_projection", SERVER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        def response(tool, value, provider=PROVIDER, name="aec_call_provider_write"):
            arguments = {"provider": provider, "toolName": tool, "arguments": {}, "dryRun": False}
            with patch.object(module, "invoke_tool", return_value=value):
                return module.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": {"name": name, "arguments": arguments}})["result"]
        for tool in ("task_poll", "task_renew", "task_release", "task_cancel"):
            for status in ("queued", "active", "draining", "completed", "expired", "cancelled"):
                with self.subTest(tool=tool, status=status):
                    result = response(tool, {"taskId": "task-1", "status": status})
                    self.assertFalse(result["isError"])
                    self.assertEqual(status, result["structuredContent"]["status"])
        for tool, provider, value in (
            ("task_cancel", "another-provider", {"taskId": "task-1", "status": "cancelled"}),
            ("task_step", PROVIDER, {"taskId": "task-1", "status": "cancelled"}),
            ("task_step", PROVIDER, {"status": "failed"}),
            ("task_step", PROVIDER, {"status": "rejected"}),
            ("task_poll", PROVIDER, {"status": "expired"}),
            ("task_poll", PROVIDER, {"taskId": 1, "status": "expired"}),
            ("task_poll", PROVIDER, {"taskId": " ", "status": "expired"}),
            ("task_poll", PROVIDER, {"taskId": "task-1", "status": "cancelled", "error": "command_failed"}),
        ):
            with self.subTest(tool=tool, provider=provider, value=value):
                self.assertTrue(response(tool, value, provider)["isError"])
        with patch.object(module, "invoke_tool", side_effect=RuntimeError("task_token_invalid")):
            result = module.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                    "params": {"name": "aec_call_provider_write", "arguments": {
                                        "provider": PROVIDER, "toolName": "task_cancel"}}})["result"]
            self.assertTrue(result["isError"])

    def test_two_independent_mcp_processes_share_host_queue(self):
        with tempfile.TemporaryDirectory() as temporary:
            http = ThreadingHTTPServer(("127.0.0.1", 0), SharedFakeConnector)
            http.token = "test-host-" + secrets.token_hex(24)
            http.info = {"instanceId": "revit-task-fixture", "application": "revit", "applicationVersion": "2024",
                         "processId": os.getpid(), "document": {"id": "disposable-doc", "title": "Disposable"},
                         "capabilities": ["document.info", "selection.read", "code.read", "code.write", "task.coordination"]}
            http.lock = threading.Lock()
            http.tasks, http.controls, http.executions = [], [], []
            http.denials = 0
            thread = threading.Thread(target=http.serve_forever, daemon=True)
            thread.start()
            descriptor = {**http.info, "protocolVersion": 1, "url": f"http://127.0.0.1:{http.server_port}",
                          "token": http.token, "startedAtUtc": "2026-11-01T00:00:00Z"}
            Path(temporary, "fixture.json").write_text(json.dumps(descriptor), encoding="utf-8")
            provider_config = Path(temporary, "providers.json")
            provider_config.write_text('{"schemaVersion":1,"providers":[]}', encoding="utf-8")
            environment = {**os.environ, "AEC_CODEX_INSTANCE_DIR": temporary,
                           "BIM_BRIDGE_INSTANCE_DIR": temporary, "AEC_CODEX_RUNTIME_ROOT": str(ROOT / "runtime"),
                           "BIM_BRIDGE_RUNTIME_ROOT": str(ROOT / "runtime"),
                           "AEC_CODEX_PROVIDER_CONFIG": str(provider_config), "BIM_BRIDGE_PROVIDER_CONFIG": str(provider_config)}
            clients = []
            try:
                clients = [Client(environment), Client(environment)]
                first, second = clients
                self.assertNotEqual(first.process.pid, second.process.pid)
                def data(result):
                    self.assertNotIn("error", result)
                    self.assertFalse(result["result"].get("isError"), result)
                    return result["result"]["structuredContent"]
                listing = data(first.call("aec_search_provider_tools", {"provider": PROVIDER, "query": "task", "limit": 20}))
                self.assertEqual(7, len(listing["tools"]))
                for tool in listing["tools"]:
                    schema = data(first.call("aec_get_provider_tool_schema", {"provider": PROVIDER, "toolName": tool["name"]}))
                    self.assertEqual("read" if tool["name"] == "task_status" else "write", schema["access"])
                args = {"instanceId": "revit-task-fixture", "name": "LACK", "owner": "agent-table"}
                before = len(http.controls)
                self.assertFalse(data(first.tool("task_submit", args, dry=True))["executed"])
                self.assertEqual(before, len(http.controls), "dry run mutated shared host queue")
                a = data(first.tool("task_submit", args))
                b = data(second.tool("task_submit", {**args, "name": "LAUTERS", "owner": "agent-lamp"}))
                self.assertEqual("active", a["task"]["status"])
                self.assertEqual("queued", b["task"]["status"])
                credentials_a = {"instanceId": args["instanceId"], "taskId": a["task"]["taskId"], "token": a["token"]}
                credentials_b = {"instanceId": args["instanceId"], "taskId": b["task"]["taskId"], "token": b["token"]}
                status = data(second.tool("task_status", {"instanceId": args["instanceId"]}, access="read"))
                self.assertNotIn(a["token"], json.dumps(status))
                self.assertNotIn(b["token"], json.dumps(status))
                self.assertEqual("queued", data(second.tool("task_poll", credentials_b))["status"])
                rejected = second.call("aec_execute_write", {"instanceId": args["instanceId"], "application": "revit",
                                                             "documentTitle": "Disposable", "description": "tokenless", "code": "return 1;"})
                self.assertTrue(rejected.get("error") or rejected.get("result", {}).get("isError"), rejected)
                self.assertEqual(1, http.denials, "no connector denial evidence for tokenless operation")
                step = {**credentials_a, "description": "LACK reference step", "documentTitle": "Disposable", "mode": "write", "code": "return 1;"}
                self.assertFalse(data(first.tool("task_step", step, dry=True))["executed"])
                self.assertEqual([], http.executions)
                data(first.tool("task_step", step))
                self.assertEqual(1, len(http.executions))
                self.assertEqual(credentials_a["taskId"], http.executions[0]["taskId"])
                data(first.tool("task_release", credentials_a))
                self.assertEqual("active", data(second.tool("task_poll", credentials_b))["status"])
                data(second.tool("task_release", credentials_b))
            finally:
                for client in clients:
                    client.close()
                http.shutdown()
                http.server_close()
                thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
