"""Native conduit tools projected through the existing provider gateway."""

from __future__ import annotations

from .hosts import execute_connector_operation, load_instances, select_instance

PROVIDER_ID = "bimbridge.conduit.v1"
TOOLS = {
    "get_conduit_ends": ("conduit.ends", "read", "Read the indexed endpoints, coordinates and connection state of two straight Revit conduits."),
    "connect_conduits": ("conduit.connect", "write", "Connect two same-diameter Revit conduits at explicit endpoint indices using a direct connection, an elbow, or a bridge and two elbows."),
}
OPERATIONS = {operation: access for operation, access, _ in TOOLS.values()}
IDENTITY = {"instanceId": {"type": "string", "minLength": 1},
            "documentTitle": {"type": "string", "minLength": 1}}


def input_schema(operation, *, include_target=False):
    element_id = {"type": "integer", "minimum": 1, "maximum": 2**63 - 1}
    end_index = {"type": "integer", "enum": [0, 1]}
    properties = {"firstId": element_id, "secondId": element_id}
    if operation == "conduit.connect":
        properties.update(firstEnd=end_index, secondEnd=end_index)
    if include_target:
        properties.update(IDENTITY)
    required = list(properties)
    properties.update(taskId={"type": "string", "minLength": 1},
                      taskToken={"type": "string", "minLength": 1})
    return {"type": "object", "properties": properties, "required": required,
            "dependentRequired": {"taskId": ["taskToken"], "taskToken": ["taskId"]},
            "additionalProperties": False}


def descriptor(probe=False):
    instances, _ = load_instances()
    ready = any("conduit.connect" in instance.get("capabilities", ()) for instance in instances)
    return {"id": PROVIDER_ID, "displayName": "BIM Bridge Conduit Connect", "version": "1",
            "application": "revit", "source": "builtin-host", "toolCount": len(TOOLS),
            "status": "ready" if ready else "unavailable" if probe else "configured",
            "error": None if ready or not probe else "No Revit connector advertises conduit.connect"}


def schema(name):
    if name not in TOOLS:
        raise ValueError("Unknown conduit tool")
    operation, access, description = TOOLS[name]
    return {"provider": PROVIDER_ID, "access": access, "tool": {
        "name": name, "description": description,
        "inputSchema": input_schema(operation, include_target=True),
        "annotations": {"readOnlyHint": access == "read", "destructiveHint": access == "write",
                        "idempotentHint": access == "read", "openWorldHint": False},
    }}


def search(query, limit):
    words = query.lower().replace("_", " ").split()
    tools = [
        {"provider": PROVIDER_ID, "name": name, "description": description, "access": access, "blocked": False}
        for name, (_, access, description) in TOOLS.items()
        if not words or any(word in description.lower() for word in words)
    ]
    return {"tools": tools[:limit], "errors": []}


def validate(operation, arguments, *, include_target=False):
    shape = input_schema(operation, include_target=include_target)
    if (not isinstance(arguments, dict) or not set(shape["required"]) <= arguments.keys()
            or arguments.keys() - shape["properties"].keys()):
        raise ValueError("Invalid conduit tool arguments")
    if ("taskId" in arguments) != ("taskToken" in arguments):
        raise ValueError("taskId and taskToken must be supplied together")
    for key, value in arguments.items():
        field = shape["properties"][key]
        if field["type"] == "string":
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"{key} must be a non-empty string")
        elif type(value) is not int:
            raise ValueError(f"{key} must be an integer")
        elif "enum" in field and value not in field["enum"]:
            raise ValueError(f"{key} must be 0 or 1")
        elif "minimum" in field and not field["minimum"] <= value <= field["maximum"]:
            raise ValueError(f"{key} is out of range")
    if arguments["firstId"] == arguments["secondId"]:
        raise ValueError("Specify two distinct conduit IDs")
    return dict(arguments)


def execute(instance, operation, arguments, access, *, dry_run=False, timeout=30):
    if OPERATIONS[operation] != access:
        raise ValueError("Conduit operation requires " + OPERATIONS[operation] + " access")
    values = validate(operation, arguments)
    task_id, task_token = values.pop("taskId", None), values.pop("taskToken", None)
    if dry_run:
        if access != "write":
            raise ValueError("Endpoint reads do not accept dryRun")
        return {"status": "succeeded", "result": {"dryRun": True, "executed": False, **values}}
    return execute_connector_operation(
        instance, operation, values, access, timeout, task_id=task_id, task_token=task_token,
    )


def invoke(runtime, name, arguments, access, dry_run, timeout):
    schema(name)
    operation, required_access, _ = TOOLS[name]
    if access != required_access:
        raise ValueError("Conduit tool requires " + required_access + " access")
    values = validate(operation, arguments, include_target=True)
    target = {key: values.pop(key) for key in IDENTITY}
    instance = select_instance({"application": "revit", **target})
    request, plan = runtime._plan_connector(instance, operation, access, values, dry_run=dry_run)
    if not dry_run:
        plan.mark_execution_started()
    try:
        result = execute(instance, operation, values, access, dry_run=dry_run, timeout=timeout)
    except Exception:
        runtime.audit.record(request["correlationId"], "execution.failed", {"operation": operation})
        raise
    status = "previewed" if dry_run else result.get("status", "failed")
    runtime.audit.record(request["correlationId"], "execution.completed", {"status": status})
    return {"status": status, "provider": PROVIDER_ID, "tool": name, "access": access,
            "dryRun": dry_run, "simulationLevel": "gateway" if dry_run else "none",
            "result": result, **({"willExecute": False} if dry_run else {})}
