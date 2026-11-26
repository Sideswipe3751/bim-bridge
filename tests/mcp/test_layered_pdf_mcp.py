"""Real stdio MCP projection against a fake authenticated connector, not Revit acceptance."""
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from test_task_coordination_mcp import Client, ROOT

PROVIDER = "bimbridge.layered_pdf.v1"


class PdfConnector(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.headers.get("Authorization") != "Bearer " + self.server.token:
            self.send_error(401)
            return
        self.server.payloads.append(payload)
        result = {"status": "succeeded", "rolledBack": payload["mode"] == "write",
                  "result": {"sheets": [], "path": "fixture.pdf", "modelRestored": True}}
        data = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class LayeredPdfMcpTests(unittest.TestCase):
    def test_discover_preview_export_and_refuse_read_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            http = ThreadingHTTPServer(("127.0.0.1", 0), PdfConnector)
            http.token, http.payloads = "test-token-" + "x" * 32, []
            worker = threading.Thread(target=http.serve_forever, daemon=True)
            worker.start()
            descriptor = {"instanceId": "revit-pdf-test", "application": "revit", "applicationVersion": "2024",
                          "processId": os.getpid(), "document": {"id": "test-document", "title": "Disposable"},
                          "capabilities": ["layered_pdf.catalog", "layered_pdf.export"], "protocolVersion": 1,
                          "url": f"http://127.0.0.1:{http.server_port}", "token": http.token,
                          "startedAtUtc": "2026-11-25T00:00:00Z"}
            Path(temporary, "fixture.json").write_text(json.dumps(descriptor), encoding="utf-8")
            config = Path(temporary, "providers.json")
            config.write_text('{"schemaVersion":1,"providers":[]}', encoding="utf-8")
            environment = {**os.environ, "BIM_BRIDGE_INSTANCE_DIR": temporary,
                           "BIM_BRIDGE_RUNTIME_ROOT": str(ROOT / "runtime"),
                           "BIM_BRIDGE_PROVIDER_CONFIG": str(config), "BIM_BRIDGE_JOURNAL_DIR": str(Path(temporary, "journal"))}
            client = None
            try:
                client = Client(environment)
                def data(response):
                    self.assertNotIn("error", response)
                    self.assertFalse(response["result"].get("isError"), response)
                    return response["result"]["structuredContent"]
                found = data(client.call("aec_search_provider_tools", {"provider": PROVIDER, "query": "PDF", "limit": 10}))
                self.assertEqual(len(found["tools"]), 2)
                shape = data(client.call("aec_get_provider_tool_schema", {"provider": PROVIDER, "toolName": "export_layered_pdf"}))
                self.assertEqual(shape["access"], "write")
                args = {"instanceId": "revit-pdf-test", "documentTitle": "Disposable"}
                data(client.call("aec_call_provider_read", {"provider": PROVIDER, "toolName": "list_layered_pdf_sheets", "arguments": args}))
                export_args = {**args, "baseSheetId": 10, "sheetIds": [10, 11]}
                def export(access, dry=False):
                    values = {"provider": PROVIDER, "toolName": "export_layered_pdf", "arguments": export_args}
                    if access == "write":
                        values["dryRun"] = dry
                    return client.call("aec_call_provider_" + access, values)
                preview = data(export("write", True))
                self.assertEqual(preview["status"], "previewed")
                self.assertEqual(len(http.payloads), 1)
                self.assertTrue(export("read")["result"]["isError"])
                self.assertEqual(len(http.payloads), 1)
                self.assertEqual(data(export("write"))["status"], "succeeded")
                self.assertEqual(len(http.payloads), 2)
                self.assertEqual(http.payloads[-1]["layeredPdf"]["sheetIds"], [10, 11])
                self.assertEqual(http.payloads[-1]["target"]["document"]["id"], "test-document")
            finally:
                if client:
                    client.close()
                http.shutdown()
                http.server_close()
                worker.join(timeout=5)
