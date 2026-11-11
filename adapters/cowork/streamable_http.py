"""Loopback Streamable HTTP projection of BIM Bridge's document.info read."""

import argparse
import hashlib
import hmac
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "runtime"))
from aec_runtime import BimBridgeRuntime
from aec_runtime.hosts import select_instance


VERSIONS = ("2025-11-25", "2025-06-18", "2025-03-26")
UNIT_FIELDS = ("length", "area", "volume", "angle")
TOOL = {
    "name": "get_revit_test_document_units",
    "title": "Get Revit test document units",
    "description": "Read the Revit version and display units of the configured test document.",
    "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    "annotations": {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False},
}


class DocumentUnavailable(Exception):
    pass


def matches_document(snapshot, document_hash):
    document_id = (snapshot.get("document") or {}).get("id")
    return (isinstance(document_id, str)
            and hashlib.sha256(document_id.encode("utf-8")).hexdigest() == document_hash)


def read_document(runtime, instance_id, document_hash):
    target = {"application": "revit", "instanceId": instance_id}
    instance = select_instance(target)
    if not matches_document(instance, document_hash):
        raise DocumentUnavailable("Configured Revit test document is unavailable")
    info = runtime.document_info(target)
    version = info.get("applicationVersion")
    units = info.get("documentUnits")
    if (info.get("application") != "revit" or info.get("instanceId") != instance_id
            or not matches_document(info, document_hash)
            or not isinstance(version, str) or not re.fullmatch(r"[0-9]{4}", version)):
        raise DocumentUnavailable("Configured Revit test document is unavailable")
    if not isinstance(units, dict) or not all(
        isinstance(units.get(key), str) and re.fullmatch(r"autodesk\.unit\.unit:[a-zA-Z0-9_.-]+", units[key])
        for key in UNIT_FIELDS
    ):
        raise DocumentUnavailable("Connector does not report document units")
    return {"applicationVersion": version, "documentUnits": {key: units[key] for key in UNIT_FIELDS}}


class McpHandler(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(5)
        super().setup()

    def log_message(self, *_args):
        pass

    def respond(self, status, payload=None, headers=None):
        body = b"" if payload is None else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        if payload is not None:
            self.send_header("Content-Type", "application/json")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        if self.path != "/mcp":
            self.respond(404)
        elif self.headers.get("Host") not in self.server.allowed_hosts or "Origin" in self.headers:
            self.respond(403)
        elif not hmac.compare_digest(
            self.headers.get("Authorization", "").encode("utf-8"), self.server.authorization
        ):
            self.respond(401, headers={"WWW-Authenticate": "Bearer"})
        else:
            return True
        return False

    def do_GET(self):
        if self.authorized():
            self.respond(405, headers={"Allow": "POST"})

    do_DELETE = do_GET

    def do_POST(self):
        if not self.authorized():
            return
        if self.headers.get("MCP-Protocol-Version", "2025-03-26") not in VERSIONS:
            self.respond(400)
            return
        if self.headers.get_content_type() != "application/json":
            self.respond(415)
            return
        accept = {item.split(";")[0].strip() for item in self.headers.get("Accept", "").split(",")}
        if not {"application/json", "text/event-stream"} <= accept:
            self.respond(406)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 16384 or "Transfer-Encoding" in self.headers:
                self.respond(400)
                return
            message = json.loads(self.rfile.read(length))
        except (ValueError, RecursionError, TimeoutError):
            self.respond(400)
            return
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            self.respond(400)
            return
        if "id" not in message:
            self.respond(202)
            return
        request_id = message["id"]
        if type(request_id) not in (str, int):
            self.respond(400)
            return
        response = {"jsonrpc": "2.0", "id": request_id}
        params = message.get("params", {})
        if not isinstance(params, dict):
            response["error"] = {"code": -32602, "message": "Invalid parameters"}
        else:
            response.update(self.dispatch(message.get("method"), params))
        self.respond(200, response)

    def dispatch(self, method, params):
        if method == "initialize":
            requested = params.get("protocolVersion")
            return {"result": {
                "protocolVersion": requested if requested in VERSIONS else VERSIONS[0],
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "bim-bridge-cowork", "version": "0.1.0"},
            }}
        if method == "ping":
            return {"result": {}}
        if method == "tools/list":
            return {"result": {"tools": [TOOL]}}
        if method != "tools/call":
            return {"error": {"code": -32601, "message": "Method not found"}}
        if (params.get("name") != TOOL["name"]
                or set(params) - {"name", "arguments", "_meta"}
                or params.get("arguments", {}) != {}):
            return {"error": {"code": -32602, "message": "Unknown tool or invalid arguments"}}
        try:
            value = self.server.read_document()
        except DocumentUnavailable as exc:
            print("tools/call failed", file=sys.stderr, flush=True)
            return {"result": {"isError": True, "content": [{"type": "text", "text": str(exc)}]}}
        except Exception:
            print("tools/call failed", file=sys.stderr, flush=True)
            return {"result": {"isError": True, "content": [
                {"type": "text", "text": "Revit connector read failed"}
            ]}}
        print("tools/call succeeded", file=sys.stderr, flush=True)
        return {"result": {"structuredContent": value, "content": [
            {"type": "text", "text": json.dumps(value)}
        ]}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--document-sha256", required=True)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    token = os.environ.pop("BIM_BRIDGE_COWORK_LOOPBACK_TOKEN", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token):
        parser.error("Set BIM_BRIDGE_COWORK_LOOPBACK_TOKEN to a high-entropy URL-safe token")
    if not re.fullmatch(r"[a-f0-9]{64}", args.document_sha256):
        parser.error("Provide the SHA-256 of the exact connector document ID")
    runtime = BimBridgeRuntime()
    with HTTPServer(("127.0.0.1", args.port), McpHandler) as server:
        port = server.server_port
        server.allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
        server.authorization = ("Bearer " + token).encode("ascii")
        server.read_document = lambda: read_document(runtime, args.instance_id, args.document_sha256)
        print(f"Listening on http://127.0.0.1:{port}/mcp", file=sys.stderr, flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
