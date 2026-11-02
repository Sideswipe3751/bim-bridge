"""Agent-neutral projection of connector-owned, instance-scoped task leases.

The connector is the single authority across independent stdio Runtime processes.
This module neither owns a process-local lock nor executes agent reasoning.
"""
from __future__ import annotations

import copy
from typing import Any

from .hosts import connector_request, load_instances, select_instance

COORDINATION_PROVIDER_ID = "bimbridge.coordination.v1"

_STRING = {"type": "string", "minLength": 1, "maxLength": 512}
_IDENTITY = {"instanceId": _STRING}
_CREDENTIALS = {**_IDENTITY, "taskId": _STRING, "token": _STRING}
_LEASE = {"type": "integer", "minimum": 10, "maximum": 300}


def _tool(name: str, description: str, properties: dict[str, Any], required: list[str], *, read: bool = False) -> dict[str, Any]:
    return {
        "name": name, "description": description,
        "inputSchema": {"type": "object", "properties": properties, "required": required, "additionalProperties": False},
        "annotations": {"readOnlyHint": read, "destructiveHint": not read,
                        "idempotentHint": read, "openWorldHint": False},
    }


TOOLS = {
    "task_status": _tool("task_status", "Inspect the instance task queue without exposing ownership tokens.", _IDENTITY, ["instanceId"], read=True),
    "task_submit": _tool("task_submit", "Queue one named task for exclusive access to an exact host instance.",
                         {**_IDENTITY, "name": {**_STRING, "maxLength": 200}, "owner": {**_STRING, "maxLength": 200}, "leaseSeconds": _LEASE},
                         ["instanceId", "name", "owner"]),
    "task_poll": _tool("task_poll", "Poll the caller's task; only the lease holder may execute task steps.", _CREDENTIALS, list(_CREDENTIALS)),
    "task_renew": _tool("task_renew", "Renew an owned task lease without interrupting an in-flight step.",
                        {**_CREDENTIALS, "leaseSeconds": _LEASE}, list(_CREDENTIALS)),
    "task_release": _tool("task_release", "Release an owned task after completed execution and verification.", _CREDENTIALS, list(_CREDENTIALS)),
    "task_cancel": _tool("task_cancel", "Cancel an owned queued task or request safe cancellation of an active task.", _CREDENTIALS, list(_CREDENTIALS)),
    "task_step": _tool("task_step", "Execute explicit arbitrary in-process code under an owned task lease. Both read and write code have ambient authority and require the write tool.",
                       {**_CREDENTIALS, "description": _STRING, "documentTitle": _STRING, "documentId": _STRING,
                        "code": {"type": "string", "minLength": 1, "maxLength": 200000},
                        "mode": {"type": "string", "enum": ["read", "write"]},
                        "timeoutSeconds": {"type": "integer", "minimum": 1, "maximum": 300}},
                       [*list(_CREDENTIALS), "documentTitle", "description", "code", "mode"]),
}


def schema(name: str) -> dict[str, Any]:
    if name not in TOOLS:
        raise ValueError("Unknown coordination tool")
    return {"provider": COORDINATION_PROVIDER_ID, "tool": copy.deepcopy(TOOLS[name]),
            "access": "read" if name == "task_status" else "write"}


def search(query: str, limit: int = 20) -> dict[str, Any]:
    words = query.lower().replace("_", " ").split()
    rows = []
    for name, tool in TOOLS.items():
        haystack = (name.replace("_", " ") + " " + tool["description"] + " coordination queue lease agent").lower()
        if not words or any(word in haystack for word in words):
            rows.append({"provider": COORDINATION_PROVIDER_ID, "name": name,
                         "description": tool["description"], "access": schema(name)["access"], "blocked": False})
    return {"tools": rows[:limit], "errors": []}


def descriptor(probe: bool = False) -> dict[str, Any]:
    instances, _ = load_instances()
    available = any("task.coordination" in item.get("capabilities", []) for item in instances)
    return {"id": COORDINATION_PROVIDER_ID, "displayName": "BIM Bridge Task Coordination",
            "version": "1", "application": "revit", "source": "builtin-host",
            "status": "ready" if available else ("unavailable" if probe else "configured"),
            "toolCount": len(TOOLS), "error": None if available or not probe else "No running connector advertises task.coordination"}


def validate(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    spec = schema(name)["tool"]["inputSchema"]
    if not isinstance(arguments, dict):
        raise ValueError("Coordination arguments must be an object")
    unknown = set(arguments) - set(spec["properties"])
    missing = set(spec["required"]) - set(arguments)
    if unknown or missing:
        raise ValueError("Invalid coordination fields: unknown=" + ",".join(sorted(unknown)) + "; missing=" + ",".join(sorted(missing)))
    for key, value in arguments.items():
        rule = spec["properties"][key]
        if rule["type"] == "string":
            if not isinstance(value, str) or not value.strip() or len(value) > rule.get("maxLength", 512):
                raise ValueError(key + " must be a bounded non-empty string")
        elif rule["type"] == "integer":
            if type(value) is not int or not rule["minimum"] <= value <= rule["maximum"]:
                raise ValueError(key + " must be an integer within the declared range")
        if "enum" in rule and value not in rule["enum"]:
            raise ValueError(key + " is not an allowed value")
    return dict(arguments)


def validate_control(arguments: dict[str, Any], intent: str) -> dict[str, Any]:
    """Validate unified-contract arguments, independently of their projection."""
    if not isinstance(arguments, dict) or not isinstance(arguments.get("action"), str) or arguments["action"] not in {"status", "submit", "poll", "renew", "release", "cancel"}:
        raise ValueError("Invalid task control action")
    action = arguments["action"]
    expected_intent = "read" if action == "status" else "write"
    if intent != expected_intent:
        raise ValueError("Task control action and intent mismatch")
    values = {key: value for key, value in arguments.items() if key != "action"}
    if "instanceId" in values:
        raise ValueError("Task control instance belongs in the execution target")
    validate("task_" + action, {"instanceId": "contract-target", **values})
    return dict(arguments)


def execute_control(instance: dict[str, Any], arguments: dict[str, Any], intent: str,
                    *, dry_run: bool = False, timeout: int = 30,
                    target: dict[str, Any] | None = None) -> dict[str, Any]:
    """Dispatch an already policy-authorized task control without adapter policy."""
    control = validate_control(arguments, intent)
    if dry_run:
        return {"dryRun": True, "executed": False, "action": control["action"]}
    info = connector_request(instance, "GET", "/v1/info")
    for key in ("instanceId", "processId", "application", "applicationVersion"):
        if info.get(key) != instance.get(key):
            raise RuntimeError("Coordination target identity changed: " + key)
    if "task.coordination" not in info.get("capabilities", []):
        raise RuntimeError("Selected connector does not support task.coordination")
    if target is None:
        target = {"application": instance["application"], "release": instance["applicationVersion"],
                  "apiVariant": str(instance.get("apiVariant") or instance.get("adapterBuild") or instance["applicationVersion"]),
                  "instanceId": instance["instanceId"], "processId": instance["processId"], "document": info.get("document")}
    payload = {"mode": intent, "operation": "task.control", "description": "Task coordination: " + control["action"],
               "taskControl": control, "timeoutSeconds": timeout, "target": target}
    return connector_request(instance, "POST", "/v1/execute", payload)


def _live_instance(instance_id: str) -> dict[str, Any]:
    instance = select_instance({"instanceId": instance_id, "application": "revit"})
    info = connector_request(instance, "GET", "/v1/info")
    for key in ("instanceId", "processId", "application", "applicationVersion"):
        if info.get(key) != instance.get(key):
            raise RuntimeError("Coordination target identity changed: " + key)
    if "task.coordination" not in info.get("capabilities", []):
        raise RuntimeError("Selected connector does not support task.coordination; upgrade is required")
    # The live document is authoritative; the host revalidates it on dispatch.
    return {**instance, "document": info.get("document"), "capabilities": info["capabilities"]}


def invoke(runtime: Any, name: str, arguments: dict[str, Any], access: str,
           dry_run: bool = False, timeout: int = 30) -> dict[str, Any]:
    values = validate(name, arguments)
    if access != schema(name)["access"]:
        raise ValueError("Coordination tool access classification mismatch")
    if type(dry_run) is not bool or type(timeout) is not int or not 1 <= timeout <= 300:
        raise ValueError("Invalid dry-run or timeout")
    instance = _live_instance(values["instanceId"])
    if name == "task_step":
        document = instance.get("document") or {}
        if document.get("title") != values["documentTitle"] or ("documentId" in values and document.get("id") != values["documentId"]):
            raise RuntimeError("Task step document precondition changed")
        clean = {"application": "revit", "instanceId": instance["instanceId"],
                 "applicationVersion": instance["applicationVersion"],
                 "documentTitle": values["documentTitle"],
                 "expectedDocumentId": document.get("id"),
                 "taskId": values["taskId"], "taskToken": values["token"],
                 "description": values["description"], "code": values["code"],
                 "timeoutSeconds": values.get("timeoutSeconds", timeout)}
        if dry_run:
            runtime._plan_connector(instance, "code." + values["mode"], values["mode"], clean)
            return {"dryRun": True, "executed": False, "instanceId": instance["instanceId"], "taskId": values["taskId"], "tool": name}
        return runtime.execute_code(clean, values["mode"])
    mode = "read" if name == "task_status" else "write"
    request, plan = runtime._plan_connector(instance, "task.coordination", mode, values)
    if dry_run:
        return {"dryRun": True, "executed": False, "instanceId": instance["instanceId"], "tool": name}
    control = {key: value for key, value in values.items() if key != "instanceId"}
    control["action"] = name.removeprefix("task_")
    payload = {"mode": mode, "operation": "task.control", "description": "Task coordination: " + control["action"],
               "taskControl": control, "timeoutSeconds": timeout,
               "target": {"application": instance["application"], "release": instance["applicationVersion"],
                          "apiVariant": str(instance.get("apiVariant") or instance.get("adapterBuild") or instance["applicationVersion"]),
                          "instanceId": instance["instanceId"], "processId": instance["processId"], "document": instance.get("document")}}
    plan.mark_execution_started()
    try:
        result = connector_request(instance, "POST", "/v1/execute", payload)
        # Task control is synchronous transport coordination, not an Autodesk
        # request. Its queued/active states describe tasks, not request polling.
    except Exception:
        runtime.audit.record(request["correlationId"], "execution.failed", {"operation": "task.control", "tool": name})
        raise
    runtime.audit.record(request["correlationId"], "execution.completed", {
        "status": result.get("status", (result.get("task") or {}).get("status")),
        "operation": "task.control", "action": control["action"],
        "taskId": result.get("taskId", (result.get("task") or {}).get("taskId")),
    })
    return result
