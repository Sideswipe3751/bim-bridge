from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
import threading
import unittest
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SERVER_PATH = (
    Path(__file__).parents[2]
    / "plugins"
    / "aec-codex"
    / "mcp-server"
    / "aec_mcp_server.py"
)
LAUNCHER_PATH = SERVER_PATH.parents[1] / "scripts" / "Start-AecCodexMcp.ps1"
sys.path.insert(0, str(SERVER_PATH.parent))
SPEC = importlib.util.spec_from_file_location("aec_mcp_server", SERVER_PATH)
assert SPEC and SPEC.loader
MCP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MCP)


class FakeConnector(BaseHTTPRequestHandler):
    token = "t" * 48
    last_execute = None

    def log_message(self, *_args):
        pass

    def _authorized(self):
        return self.headers.get("Authorization") == "Bearer " + self.token

    def _write(self, status, value):
        body = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self._authorized():
            self._write(401, {"error": "unauthorized"})
        elif self.path == "/v1/info":
            self._write(200, {"application": "revit", "version": "2024", "document": "Test"})
        elif self.path == "/v1/selection":
            self._write(200, {"ids": [42]})
        elif self.path == "/v1/requests/request-1":
            self._write(200, {"requestId": "request-1", "status": "succeeded", "result": {"ok": True}})
        else:
            self._write(404, {"error": "not found"})

    def do_POST(self):
        if not self._authorized():
            self._write(401, {"error": "unauthorized"})
            return
        size = int(self.headers.get("Content-Length", "0"))
        FakeConnector.last_execute = json.loads(self.rfile.read(size).decode("utf-8"))
        self._write(202, {"requestId": "request-1", "status": "queued"})


class McpServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.previous = os.environ.get("AEC_CODEX_INSTANCE_DIR")
        os.environ["AEC_CODEX_INSTANCE_DIR"] = self.temp.name
        self.previous_provider_config = os.environ.get("AEC_CODEX_PROVIDER_CONFIG")
        provider_config = Path(self.temp.name, "providers.json")
        provider_config.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "providers": [
                        {
                            "id": "fake-provider",
                            "application": "revit",
                            "displayName": "Fake Provider",
                            "version": "1.0.0",
                            "command": sys.executable,
                            "args": [str(Path(__file__).with_name("fake_provider.py"))],
                            "enabled": True,
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        os.environ["AEC_CODEX_PROVIDER_CONFIG"] = str(provider_config)
        MCP.RUNTIME.providers.reload(force=True)
        self.http = ThreadingHTTPServer(("127.0.0.1", 0), FakeConnector)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.write_descriptor("revit-one", self.http.server_port)

    def tearDown(self):
        MCP.RUNTIME.providers.close()
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(timeout=2)
        if self.previous is None:
            os.environ.pop("AEC_CODEX_INSTANCE_DIR", None)
        else:
            os.environ["AEC_CODEX_INSTANCE_DIR"] = self.previous
        if self.previous_provider_config is None:
            os.environ.pop("AEC_CODEX_PROVIDER_CONFIG", None)
        else:
            os.environ["AEC_CODEX_PROVIDER_CONFIG"] = self.previous_provider_config
        self.temp.cleanup()

    def write_descriptor(self, instance_id, port, url=None):
        value = {
            "protocolVersion": 1,
            "instanceId": instance_id,
            "application": "revit",
            "applicationVersion": "2024",
            "processId": 1234,
            "url": url or f"http://127.0.0.1:{port}",
            "token": FakeConnector.token,
            "startedAtUtc": "2026-08-10T00:00:00Z",
            "document": {"id": "doc-1", "title": "Test", "path": None},
            "capabilities": [
                "document.info",
                "selection.read",
                "view.capture",
                "conduit.ends",
                "conduit.connect",
                "code.read",
                "code.write",
            ],
        }
        Path(self.temp.name, instance_id + ".json").write_text(json.dumps(value), encoding="utf-8")

    def test_tool_annotations_separate_read_and_write(self):
        tools = {item["name"]: item for item in MCP.TOOLS}
        self.assertFalse(tools["aec_execute_read"]["annotations"]["readOnlyHint"])
        self.assertTrue(tools["aec_execute_read"]["annotations"]["destructiveHint"])
        self.assertFalse(tools["aec_execute_write"]["annotations"]["readOnlyHint"])
        self.assertTrue(tools["aec_execute_write"]["annotations"]["destructiveHint"])

    def test_list_does_not_expose_token(self):
        result = MCP.invoke_tool("aec_list_instances", {})
        self.assertEqual(1, len(result["instances"]))
        self.assertNotIn("token", result["instances"][0])

    def test_document_and_selection_proxy(self):
        info = MCP.invoke_tool("aec_get_document_info", {"instanceId": "revit-one"})
        selection = MCP.invoke_tool("aec_get_selection", {"instanceId": "revit-one"})
        self.assertEqual("Test", info["document"])
        self.assertEqual([42], selection["ids"])

    def test_execute_modes_are_forced_by_tool(self):
        arguments = {"instanceId": "revit-one", "description": "Read title", "code": "return doc.Title;"}
        result = MCP.invoke_tool("aec_execute_read", arguments)
        self.assertEqual("succeeded", result["status"])
        self.assertEqual("read", FakeConnector.last_execute["mode"])
        arguments["description"] = "Change model"
        MCP.invoke_tool("aec_execute_write", arguments)
        self.assertEqual("write", FakeConnector.last_execute["mode"])

    def test_ambiguous_routing_requires_instance_id(self):
        self.write_descriptor("revit-two", self.http.server_port)
        with self.assertRaisesRegex(RuntimeError, "More than one connector"):
            MCP.invoke_tool("aec_get_document_info", {"application": "revit"})
        with self.assertRaisesRegex(RuntimeError, "cannot target one of several"):
            MCP.invoke_tool(
                "aec_call_provider_read",
                {"provider": "fake-provider", "toolName": "get_model_info", "arguments": {}},
            )

    def test_non_loopback_descriptor_is_ignored(self):
        self.write_descriptor("bad", self.http.server_port, "http://example.com:1234")
        result = MCP.invoke_tool("aec_list_instances", {})
        self.assertEqual(1, len(result["instances"]))
        self.assertTrue(any("loopback" in warning for warning in result["warnings"]))

    def test_json_rpc_initialize_and_tools_list(self):
        initialized = MCP.process_message(
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}}
        )
        listed = MCP.process_message({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self.assertEqual("aec-codex", initialized["result"]["serverInfo"]["name"])
        self.assertEqual(10, len(listed["result"]["tools"]))

    @unittest.skipUnless(os.name == "nt", "PowerShell launcher is Windows-only")
    def test_powershell_launcher_preserves_stdio(self):
        messages = "\n".join(
            [
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {"protocolVersion": "2025-11-25"},
                    }
                ),
                json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
            ]
        ) + "\n"
        environment = os.environ.copy()
        environment["LOCALAPPDATA"] = self.temp.name
        completed = subprocess.run(
            [
                "powershell.exe",
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(LAUNCHER_PATH),
            ],
            input=messages,
            text=True,
            capture_output=True,
            timeout=20,
            env=environment,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        responses = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
        self.assertEqual("1.1.0-rc.3", responses[0]["result"]["serverInfo"]["version"])
        self.assertEqual(10, len(responses[1]["result"]["tools"]))

    def test_provider_discovery_schema_and_calls(self):
        listed = MCP.invoke_tool("aec_list_providers", {"probe": True})
        self.assertEqual("ready", listed["providers"][0]["status"])
        self.assertEqual(3, listed["providers"][0]["toolCount"])
        searched = MCP.invoke_tool("aec_search_provider_tools", {"query": "wall"})
        self.assertEqual("create_wall", searched["tools"][0]["name"])
        schema = MCP.invoke_tool(
            "aec_get_provider_tool_schema",
            {"provider": "fake-provider", "toolName": "get_model_info"},
        )
        self.assertEqual("read", schema["access"])
        read = MCP.invoke_tool(
            "aec_call_provider_read",
            {"provider": "fake-provider", "toolName": "get_model_info", "arguments": {}},
        )
        self.assertEqual("succeeded", read["status"])
        dry = MCP.invoke_tool(
            "aec_call_provider_write",
            {
                "provider": "fake-provider",
                "toolName": "create_wall",
                "arguments": {"length": 10},
                "dryRun": True,
            },
        )
        self.assertTrue(dry["result"]["arguments"]["dryRun"])
        preview = MCP.invoke_tool(
            "aec_call_provider_write",
            {
                "provider": "fake-provider",
                "toolName": "set_name",
                "arguments": {"name": "A"},
                "dryRun": True,
            },
        )
        self.assertEqual("previewed", preview["status"])
        self.assertEqual("gateway", preview["simulationLevel"])
        self.assertFalse(preview["willExecute"])
        with self.assertRaisesRegex(RuntimeError, "Missing required provider argument"):
            MCP.invoke_tool(
                "aec_call_provider_write",
                {
                    "provider": "fake-provider",
                    "toolName": "set_name",
                    "arguments": {},
                    "dryRun": True,
                },
            )

    def test_provider_read_boundary_and_blocked_code(self):
        with self.assertRaisesRegex(RuntimeError, "not classified read-only"):
            MCP.invoke_tool(
                "aec_call_provider_read",
                {"provider": "fake-provider", "toolName": "create_wall", "arguments": {}},
            )
        with self.assertRaisesRegex(RuntimeError, "does not expose"):
            MCP.invoke_tool(
                "aec_get_provider_tool_schema",
                {"provider": "fake-provider", "toolName": "send_code_to_revit"},
            )

    def test_builtin_revit_capture_is_discoverable_and_directly_callable(self):
        searched = MCP.invoke_tool(
            "aec_search_provider_tools", {"query": "screenshot", "provider": "revit.connector.v1"}
        )
        self.assertEqual("capture_view", searched["tools"][0]["name"])
        schema = MCP.invoke_tool(
            "aec_get_provider_tool_schema",
            {"provider": "revit.connector.v1", "toolName": "capture_view"},
        )
        self.assertEqual("read", schema["access"])
        result = MCP.invoke_tool(
            "aec_call_provider_read",
            {
                "provider": "revit.connector.v1",
                "toolName": "capture_view",
                "arguments": {
                    "instanceId": "revit-one",
                    "viewName": "{3D}",
                    "fileStem": "qa",
                    "pixelSize": 1400,
                    "dpi": 150,
                },
            },
        )
        self.assertEqual("succeeded", result["status"])
        self.assertEqual("view.capture", FakeConnector.last_execute["operation"])
        self.assertEqual("{3D}", FakeConnector.last_execute["viewCapture"]["viewName"])
        self.assertNotIn("code", FakeConnector.last_execute)


    def test_builtin_conduit_preview_and_exact_target_dispatch(self):
        provider = "bimbridge.conduit.v1"
        arguments = {"instanceId": "revit-one", "documentTitle": "Test", "firstId": 42, "secondId": 43}
        self.write_descriptor("revit-two", self.http.server_port)
        tools = MCP.invoke_tool("aec_search_provider_tools", {"query": "conduit", "provider": provider})
        self.assertEqual({"get_conduit_ends", "connect_conduits"}, {tool["name"] for tool in tools["tools"]})
        read = {"provider": provider, "toolName": "get_conduit_ends", "arguments": arguments}
        self.assertEqual("succeeded", MCP.invoke_tool("aec_call_provider_read", read)["status"])
        self.assertEqual("conduit.ends", FakeConnector.last_execute["operation"])

        arguments.update(firstEnd=1, secondEnd=0, taskId="owner", taskToken="token")
        write = {"provider": provider, "toolName": "connect_conduits", "arguments": arguments}
        FakeConnector.last_execute = None
        result = MCP.invoke_tool("aec_call_provider_write", {**write, "dryRun": True})
        self.assertEqual("previewed", result["status"])
        self.assertFalse(result["willExecute"])
        self.assertIsNone(FakeConnector.last_execute)
        with self.assertRaisesRegex(ValueError, "write access"):
            MCP.invoke_tool("aec_call_provider_read", write)
        with self.assertRaisesRegex(ValueError, "must be 0 or 1"):
            MCP.invoke_tool("aec_call_provider_write", {
                **write, "dryRun": False, "arguments": {**arguments, "firstEnd": 2}
            })
        self.assertIsNone(FakeConnector.last_execute)

        result = MCP.invoke_tool("aec_call_provider_write", {**write, "dryRun": False})
        self.assertEqual("succeeded", result["status"])
        sent = FakeConnector.last_execute
        self.assertEqual("conduit.connect", sent["operation"])
        self.assertEqual("write", sent["mode"])
        self.assertEqual("revit-one", sent["target"]["instanceId"])
        self.assertEqual("doc-1", sent["target"]["document"]["id"])
        self.assertEqual("owner", sent["taskId"])
        self.assertEqual("token", sent["taskToken"])
        self.assertEqual({"firstId": 42, "secondId": 43, "firstEnd": 1, "secondEnd": 0}, sent["conduit"])
        self.assertNotIn("code", sent)


if __name__ == "__main__":
    unittest.main()
