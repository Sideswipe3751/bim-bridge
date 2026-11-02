#!/usr/bin/env python3
"""Dependency-free Codex MCP adapter for local BIM Bridge Runtime."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

# CPython's Windows embeddable distribution runs with an explicit ``._pth``
# file and does not automatically add the launched script's directory. Keep
# sibling modules importable in both the private runtime and normal dev Python.
SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))

runtime_candidates = []
runtime_override = os.environ.get("BIM_BRIDGE_RUNTIME_ROOT") or os.environ.get(
    "AEC_CODEX_RUNTIME_ROOT"
)
if runtime_override:
    runtime_candidates.append(Path(runtime_override))
runtime_candidates.extend(
    [
        SCRIPT_DIRECTORY / "runtime",
        SCRIPT_DIRECTORY.parents[2] / "runtime",
    ]
)
for runtime_root in runtime_candidates:
    if (runtime_root / "aec_runtime" / "__init__.py").is_file():
        if str(runtime_root) not in sys.path:
            sys.path.insert(0, str(runtime_root))
        break

from aec_runtime import (
    BimBridgeRuntime,
    ProviderError,
    RuntimeRequestError,
    TERMINAL_STATUSES,
    TargetInputError,
    normalize_target_filters,
)
from aec_runtime.coordination import COORDINATION_PROVIDER_ID


SERVER_VERSION = "1.1.0-rc.3"
SUPPORTED_MCP_VERSIONS = (
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
)
LATEST_MCP_VERSION = SUPPORTED_MCP_VERSIONS[0]
RUNTIME = BimBridgeRuntime()


TARGET_PROPERTIES = {
    "instanceId": {
        "type": "string",
        "description": "Exact connector instance ID. Prefer this when several sessions are open.",
    },
    "application": {
        "type": "string",
        "enum": ["revit", "autocad"],
        "description": "Limit routing to Revit or AutoCAD.",
    },
    "applicationVersion": {
        "type": "string",
        "pattern": "^[0-9]{4}$",
        "description": "Optional Autodesk major version, such as 2024 or 2027.",
    },
    "documentTitle": {
        "type": "string",
        "description": "Optional exact active document title.",
    },
}


def object_schema(
    properties: dict[str, Any], required: list[str] | None = None
) -> dict[str, Any]:
    schema: dict[str, Any] = {
        "type": "object",
        "properties": properties,
        "additionalProperties": False,
    }
    if required:
        schema["required"] = required
    return schema


TOOLS = [
    {
        "name": "aec_list_instances",
        "title": "List Autodesk sessions",
        "description": "List discoverable local Revit and AutoCAD connector sessions.",
        "inputSchema": object_schema(
            {
                "application": TARGET_PROPERTIES["application"],
                "applicationVersion": TARGET_PROPERTIES["applicationVersion"],
            }
        ),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_get_document_info",
        "title": "Get Autodesk document information",
        "description": "Read application, connector, active document, and capability information.",
        "inputSchema": object_schema(TARGET_PROPERTIES),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_get_selection",
        "title": "Get Autodesk selection",
        "description": "Read the current Revit element or AutoCAD entity selection.",
        "inputSchema": object_schema(TARGET_PROPERTIES),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_execute_read",
        "title": "Execute Autodesk API query code",
        "description": (
            "Run arbitrary in-process Autodesk API code intended for querying. "
            "Because the code has ambient host and OS authority, treat this as a critical operation."
        ),
        "inputSchema": object_schema(
            {
                **TARGET_PROPERTIES,
                "description": {
                    "type": "string",
                    "description": "Short explanation of the information being read.",
                },
                "code": {
                    "type": "string",
                    "description": "C# method-body code. Revit exposes uiApp, uiDoc, doc, and transaction; AutoCAD exposes document, database, editor, and transaction. Return a JSON-serializable value.",
                },
                "timeoutSeconds": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 300,
                    "default": 30,
                },
            },
            ["description", "code"],
        ),
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": True,
            "idempotentHint": False,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_execute_write",
        "title": "Execute Autodesk API write code",
        "description": (
            "Run bounded application-specific write code in a native transaction. "
            "Arbitrary write code is potentially destructive."
        ),
        "inputSchema": object_schema(
            {
                **TARGET_PROPERTIES,
                "description": {
                    "type": "string",
                    "description": "Short explanation of the requested model or drawing change.",
                },
                "code": {
                    "type": "string",
                    "description": "C# method-body code executed inside one native write transaction. Revit exposes uiApp, uiDoc, doc, and transaction; AutoCAD exposes document, database, editor, and transaction. Do not commit or start another top-level transaction.",
                },
                "timeoutSeconds": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 300,
                    "default": 30,
                },
            },
            ["description", "code"],
        ),
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": True,
            "idempotentHint": False,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_list_providers",
        "title": "List structured AEC providers",
        "description": "List installed Revit and AutoCAD structured-tool providers and optionally probe their health.",
        "inputSchema": object_schema(
            {
                "probe": {
                    "type": "boolean",
                    "default": False,
                    "description": "Start providers and count tools. This can take several seconds.",
                }
            }
        ),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_search_provider_tools",
        "title": "Search structured Autodesk tools",
        "description": "Search installed provider catalogs without loading every tool schema into context.",
        "inputSchema": object_schema(
            {
                "query": {"type": "string", "description": "Capability or Autodesk command to find."},
                "provider": {"type": "string", "description": "Optional provider id."},
                "limit": {"type": "integer", "minimum": 1, "maximum": 25, "default": 10},
            },
            ["query"],
        ),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_get_provider_tool_schema",
        "title": "Get structured Autodesk tool schema",
        "description": "Get the exact input schema and access classification for one provider tool before calling it.",
        "inputSchema": object_schema(
            {
                "provider": {"type": "string"},
                "toolName": {"type": "string"},
            },
            ["provider", "toolName"],
        ),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_call_provider_read",
        "title": "Call structured read-only Autodesk tool",
        "description": "Call one provider tool only when the provider catalog classifies it as read-only.",
        "inputSchema": object_schema(
            {
                "provider": {"type": "string"},
                "toolName": {"type": "string"},
                "arguments": {"type": "object", "additionalProperties": True},
                "timeoutSeconds": {"type": "integer", "minimum": 1, "maximum": 300, "default": 60},
            },
            ["provider", "toolName", "arguments"],
        ),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": False,
            "openWorldHint": False,
        },
    },
    {
        "name": "aec_call_provider_write",
        "title": "Call structured Autodesk write tool",
        "description": "Preview or execute one structured provider write tool. A gateway preview never calls an upstream tool that lacks native dry-run support.",
        "inputSchema": object_schema(
            {
                "provider": {"type": "string"},
                "toolName": {"type": "string"},
                "arguments": {"type": "object", "additionalProperties": True},
                "dryRun": {"type": "boolean", "default": True},
                "timeoutSeconds": {"type": "integer", "minimum": 1, "maximum": 300, "default": 60},
            },
            ["provider", "toolName", "arguments", "dryRun"],
        ),
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": True,
            "idempotentHint": False,
            "openWorldHint": False,
        },
    },
]
TOOL_BY_NAME = {tool["name"]: tool for tool in TOOLS}


class ProtocolError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


ToolInputError = TargetInputError


def _validate_call_arguments(name: str, arguments: Any) -> dict[str, Any]:
    if not isinstance(arguments, dict):
        raise ToolInputError("Tool arguments must be a JSON object")
    schema_properties = TOOL_BY_NAME[name]["inputSchema"]["properties"]
    unknown = set(arguments) - set(schema_properties)
    if unknown:
        raise ToolInputError("Unknown argument(s): " + ", ".join(sorted(unknown)))
    if name in {"aec_get_document_info", "aec_get_selection", "aec_execute_read", "aec_execute_write"}:
        normalize_target_filters(arguments)
    if name.startswith("aec_execute_"):
        for key in ("description", "code"):
            value = arguments.get(key)
            if not isinstance(value, str) or not value.strip():
                raise ToolInputError(f"{key} is required and must be a non-empty string")
        timeout = arguments.get("timeoutSeconds", 30)
        if isinstance(timeout, bool) or not isinstance(timeout, int) or not 1 <= timeout <= 300:
            raise ToolInputError("timeoutSeconds must be an integer from 1 through 300")
    if name in {"aec_search_provider_tools", "aec_get_provider_tool_schema", "aec_call_provider_read", "aec_call_provider_write"}:
        for key in ("provider", "toolName"):
            if key in arguments and (not isinstance(arguments[key], str) or not arguments[key].strip()):
                raise ToolInputError(f"{key} must be a non-empty string")
    if name == "aec_search_provider_tools":
        query = arguments.get("query")
        if not isinstance(query, str) or not query.strip():
            raise ToolInputError("query is required")
        limit = arguments.get("limit", 10)
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 25:
            raise ToolInputError("limit must be an integer from 1 through 25")
    if name.startswith("aec_call_provider_"):
        if not isinstance(arguments.get("arguments"), dict):
            raise ToolInputError("arguments must be an object")
        timeout = arguments.get("timeoutSeconds", 60)
        if isinstance(timeout, bool) or not isinstance(timeout, int) or not 1 <= timeout <= 300:
            raise ToolInputError("timeoutSeconds must be an integer from 1 through 300")
    if name == "aec_call_provider_write" and not isinstance(arguments.get("dryRun"), bool):
        raise ToolInputError("dryRun is required and must be boolean")
    return arguments


def invoke_tool(name: str, arguments: Any) -> dict[str, Any]:
    if name not in TOOL_BY_NAME:
        raise ToolInputError("Unknown tool: " + name)
    values = _validate_call_arguments(name, arguments)
    if name == "aec_list_providers":
        return RUNTIME.list_providers(probe=values.get("probe", False))
    if name == "aec_search_provider_tools":
        return RUNTIME.search_provider_tools(
            values["query"].strip(), values.get("provider"), values.get("limit", 10)
        )
    if name == "aec_get_provider_tool_schema":
        return RUNTIME.provider_schema(values["provider"].strip(), values["toolName"].strip())
    if name in {"aec_call_provider_read", "aec_call_provider_write"}:
        access = "read" if name.endswith("_read") else "write"
        return RUNTIME.invoke_provider(
            values["provider"].strip(),
            values["toolName"].strip(),
            values["arguments"],
            access,
            values.get("dryRun", False),
            values.get("timeoutSeconds", 60),
        )
    if name == "aec_list_instances":
        return RUNTIME.list_instances(values)
    if name == "aec_get_document_info":
        return RUNTIME.document_info(values)
    if name == "aec_get_selection":
        return RUNTIME.selection(values)
    mode = "read" if name == "aec_execute_read" else "write"
    return RUNTIME.execute_code(values, mode)


def tool_result(value: dict[str, Any], is_error: bool = False) -> dict[str, Any]:
    return {
        "content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}],
        "structuredContent": value,
        "isError": is_error,
    }


def execution_result_is_error(name: str, arguments: Any, value: dict[str, Any]) -> bool:
    # Coordination poll/control returns a task snapshot. Its terminal domain
    # states describe the task, rather than failure of this successful command.
    # Restrict the exception to the known neutral provider and exact controls;
    # native step failures and arbitrary provider results retain their meaning.
    if (
        name == "aec_call_provider_write"
        and isinstance(arguments, dict)
        and arguments.get("provider") == COORDINATION_PROVIDER_ID
        and arguments.get("toolName") in {"task_poll", "task_renew", "task_release", "task_cancel"}
        and isinstance(value.get("taskId"), str)
        and bool(value["taskId"].strip())
        and value.get("status") in {"queued", "active", "draining", "completed", "expired", "cancelled"}
        and "error" not in value
    ):
        return False
    return value.get("status") in TERMINAL_STATUSES - {"succeeded"}


def handle(message: Any) -> dict[str, Any] | None:
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        raise ProtocolError(-32600, "Invalid JSON-RPC request")
    method = message.get("method")
    if not isinstance(method, str):
        raise ProtocolError(-32600, "JSON-RPC method must be a string")
    params = message.get("params") or {}
    if not isinstance(params, dict):
        raise ProtocolError(-32602, "params must be an object")
    request_id = message.get("id")
    if method == "initialize":
        requested = params.get("protocolVersion")
        if not isinstance(requested, str):
            raise ProtocolError(-32602, "initialize requires protocolVersion")
        negotiated = requested if requested in SUPPORTED_MCP_VERSIONS else LATEST_MCP_VERSION
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": negotiated,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {
                    "name": "aec-codex",
                    "version": SERVER_VERSION,
                    "description": "BIM Bridge MCP adapter for local Revit and AutoCAD connectors",
                },
                "instructions": (
                    "List instances before the first Autodesk operation. Read before writing, "
                    "route to an explicit instance when multiple sessions match, and never "
                    "send a write through a read-only tool."
                ),
            },
        }
    if method == "ping":
        return {"jsonrpc": "2.0", "id": request_id, "result": {}}
    if method.startswith("notifications/"):
        return None
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": request_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        name = params.get("name")
        if not isinstance(name, str):
            raise ProtocolError(-32602, "tools/call requires a tool name")
        try:
            value = invoke_tool(name, params.get("arguments", {}))
        except (
            ToolInputError,
            ProviderError,
            RuntimeRequestError,
            RuntimeError,
            KeyError,
            ValueError,
        ) as exc:
            result = tool_result({"error": str(exc)}, is_error=True)
        else:
            result = tool_result(value, is_error=execution_result_is_error(name, params.get("arguments", {}), value))
        return {"jsonrpc": "2.0", "id": request_id, "result": result}
    raise ProtocolError(-32601, "Method not found")


def error_response(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def process_message(message: Any) -> dict[str, Any] | None:
    request_id = message.get("id") if isinstance(message, dict) else None
    try:
        return handle(message)
    except ProtocolError as exc:
        return error_response(request_id, exc.code, exc.message)
    except Exception as exc:
        return error_response(request_id, -32603, "Internal error: " + str(exc))


def process_payload(payload: Any) -> dict[str, Any] | list[dict[str, Any]] | None:
    if isinstance(payload, list):
        if not payload:
            return error_response(None, -32600, "Empty JSON-RPC batch")
        responses = [result for item in payload if (result := process_message(item)) is not None]
        return responses or None
    return process_message(payload)


def main() -> None:
    if hasattr(sys.stdin, "reconfigure"):
        sys.stdin.reconfigure(encoding="utf-8")
        sys.stdout.reconfigure(encoding="utf-8")
    for raw in sys.stdin:
        if not raw.strip():
            continue
        try:
            response = process_payload(json.loads(raw))
        except json.JSONDecodeError as exc:
            response = error_response(None, -32700, "Parse error: " + str(exc))
        if response is not None:
            print(json.dumps(response, ensure_ascii=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
