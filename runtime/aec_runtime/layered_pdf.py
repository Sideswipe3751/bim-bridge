"""Layered PDF capabilities over the existing instance-aware host transport."""
from __future__ import annotations

import re
from .hosts import execute_connector_operation, load_instances, select_instance

PROVIDER_ID = "bimbridge.layered_pdf.v1"
TOOLS = {
    "list_layered_pdf_sheets": ("layered_pdf.catalog", "read", "List printable Revit sheets, placed viewports and saved PDF export setups for layered PDF overlay."),
    "export_layered_pdf": ("layered_pdf.export", "write", "Overlay viewports from selected Revit sheets onto one PDF page, with one switchable Bluebeam-compatible layer per viewport, grouped by source sheet. Temporary isolation is rolled back. Writes a new file under BIM Bridge exports."),
}
OPERATIONS = {operation: access for operation, access, _ in TOOLS.values()}
IDENTITY = {"instanceId": {"type": "string", "minLength": 1},
            "documentTitle": {"type": "string", "minLength": 1}}


def input_schema(operation, *, include_target=False):
    if operation not in OPERATIONS:
        raise ValueError("Unknown Layered PDF operation")
    props = dict(IDENTITY) if include_target else {}
    required = list(props)
    if operation == "layered_pdf.export":
        element = {"type": "integer", "minimum": 1, "maximum": 2**63 - 1}
        props.update(baseSheetId=element, sheetIds={"type": "array", "items": element,
                     "minItems": 1, "maxItems": 100, "uniqueItems": True},
                     setupName={"type": "string", "minLength": 1, "maxLength": 256},
                     fileStem={"type": "string", "pattern": "^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$", "default": "layered-pdf"},
                     includeSheetAndDetail={"type": "boolean", "default": True},
                     createBoxLayers={"type": "boolean", "default": False})
        required += ["baseSheetId", "sheetIds"]
    props.update(taskId={"type": "string", "minLength": 1}, taskToken={"type": "string", "minLength": 1})
    return {"type": "object", "properties": props, "required": required,
            "dependentRequired": {"taskId": ["taskToken"], "taskToken": ["taskId"]}, "additionalProperties": False}


def output_schema(operation):
    if operation == "layered_pdf.catalog":
        return {"type": "object", "required": ["sheets", "setupNames", "composerAvailable"],
                "properties": {"sheets": {"type": "array"}, "setupNames": {"type": "array", "items": {"type": "string"}},
                               "composerAvailable": {"type": "boolean"}}}
    return {"type": "object", "required": ["path", "sha256", "pageCount", "viewportLayerCount", "modelRestored"],
            "properties": {"path": {"type": "string"}, "sha256": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
                           "pageCount": {"const": 1}, "viewportLayerCount": {"type": "integer", "minimum": 1},
                           "modelRestored": {"const": True}}}


def validate(operation, arguments, *, include_target=False):
    shape = input_schema(operation, include_target=include_target)
    if (not isinstance(arguments, dict) or not set(shape["required"]) <= arguments.keys()
            or arguments.keys() - shape["properties"].keys()):
        raise ValueError("Invalid Layered PDF arguments")
    if ("taskId" in arguments) != ("taskToken" in arguments):
        raise ValueError("taskId and taskToken must be supplied together")
    for key, value in arguments.items():
        field = shape["properties"][key]
        if field["type"] == "string":
            if not isinstance(value, str) or not value.strip() or len(value) > field.get("maxLength", 4096):
                raise ValueError(key + " must be a bounded non-empty string")
        elif field["type"] == "boolean":
            if type(value) is not bool:
                raise ValueError(key + " must be boolean")
        elif field["type"] == "integer":
            if type(value) is not int or not 1 <= value <= 2**63 - 1:
                raise ValueError(key + " must be a positive 64-bit integer")
        elif (not isinstance(value, list) or not 1 <= len(value) <= 100
              or any(type(i) is not int or not 1 <= i <= 2**63 - 1 for i in value)
              or len(set(value)) != len(value)):
            raise ValueError("sheetIds must contain 1-100 distinct positive IDs")
    stem = arguments.get("fileStem", "layered-pdf")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", stem) or re.fullmatch(
            r"CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]", stem, re.I):
        raise ValueError("fileStem must be a safe filename stem")
    return dict(arguments)


def descriptor(probe=False):
    instances, _ = load_instances()
    available = {op for item in instances if item.get("application") == "revit"
                 for op in item.get("capabilities", ()) if op in OPERATIONS}
    return {"id": PROVIDER_ID, "displayName": "BIM Bridge Layered PDF", "version": "1",
            "application": "revit", "source": "builtin-host", "toolCount": len(TOOLS),
            "status": "ready" if available else "unavailable" if probe else "configured",
            "availableOperations": sorted(available),
            "error": None if available or not probe else "No connector advertises Layered PDF; build and load the updated connector"}


def schema(name):
    if name not in TOOLS:
        raise ValueError("Unknown Layered PDF tool")
    op, access, description = TOOLS[name]
    return {"provider": PROVIDER_ID, "access": access, "tool": {
        "name": name, "description": description, "inputSchema": input_schema(op, include_target=True),
        "annotations": {"readOnlyHint": access == "read", "destructiveHint": access == "write",
                        "idempotentHint": access == "read", "openWorldHint": False}}}


def search(query, limit):
    words = query.lower().replace("_", " ").split()
    return {"tools": [{"provider": PROVIDER_ID, "name": name, "description": description,
                       "access": access, "blocked": False}
                      for name, (_, access, description) in TOOLS.items()
                      if not words or any(w in (description + " " + name).lower() for w in words)][:limit], "errors": []}


def execute(instance, operation, arguments, access, *, dry_run=False, timeout=300):
    if OPERATIONS.get(operation) != access:
        raise ValueError("Incorrect Layered PDF access mode")
    values = validate(operation, arguments)
    if type(timeout) is not int or not 1 <= timeout <= 300:
        raise ValueError("Layered PDF timeout must be between 1 and 300 seconds")
    task_id, task_token = values.pop("taskId", None), values.pop("taskToken", None)
    if dry_run:
        if access != "write":
            raise ValueError("Catalog reads do not accept dryRun")
        return {"status": "succeeded", "result": {"dryRun": True, "executed": False,
                "nativeValidation": False, "fileOverwrite": False, **values}}
    return execute_connector_operation(instance, operation, values, access, timeout,
                                       task_id=task_id, task_token=task_token)


def invoke(runtime, name, arguments, access, dry_run, timeout):
    schema(name)
    operation, required_access, _ = TOOLS[name]
    if access != required_access:
        raise ValueError("Layered PDF tool requires " + required_access + " access")
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
    runtime.audit.record(request["correlationId"], "execution.completed", {"status": status, "rolledBack": result.get("rolledBack")})
    return {"status": status, "provider": PROVIDER_ID, "tool": name, "access": access,
            "dryRun": dry_run, "simulationLevel": "gateway" if dry_run else "none",
            "result": result, **({"willExecute": False} if dry_run else {})}
