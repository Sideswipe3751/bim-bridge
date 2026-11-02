from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Mapping
from pathlib import Path
from typing import Any


APPLICATIONS = {"revit", "autocad"}
TERMINAL_STATUSES = {"succeeded", "failed", "rejected", "expired", "cancelled"}
MAX_DESCRIPTOR_BYTES = 64 * 1024
TARGET_FILTER_KEYS = ("instanceId", "application", "applicationVersion", "documentTitle")


class TargetInputError(ValueError):
    """A target selector is malformed before routing begins."""


def instance_directory(environment: Mapping[str, str] | None = None) -> Path:
    values = os.environ if environment is None else environment
    configured = values.get("BIM_BRIDGE_INSTANCE_DIR") or values.get("AEC_CODEX_INSTANCE_DIR")
    if configured:
        return Path(configured)
    app_data = values.get("APPDATA", str(Path.home()))
    current = Path(app_data) / "BIM Bridge" / "instances"
    legacy = Path(app_data) / "AEC Codex" / "instances"
    return current if current.exists() or not legacy.exists() else legacy


def validate_descriptor(value: Any, source: Path) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{source.name}: descriptor must be an object")
    required = {
        "protocolVersion",
        "instanceId",
        "application",
        "applicationVersion",
        "processId",
        "url",
        "token",
        "startedAtUtc",
        "capabilities",
    }
    missing = required - set(value)
    if missing:
        raise ValueError(f"{source.name}: missing {', '.join(sorted(missing))}")
    if value["protocolVersion"] != 1:
        raise ValueError(f"{source.name}: unsupported connector protocol")
    if not isinstance(value["instanceId"], str) or not value["instanceId"]:
        raise ValueError(f"{source.name}: invalid instanceId")
    if value["application"] not in APPLICATIONS:
        raise ValueError(f"{source.name}: invalid application")
    version = value["applicationVersion"]
    if not isinstance(version, str) or len(version) != 4 or not version.isdigit():
        raise ValueError(f"{source.name}: invalid applicationVersion")
    if isinstance(value["processId"], bool) or not isinstance(value["processId"], int):
        raise ValueError(f"{source.name}: invalid processId")
    if value["processId"] < 1:
        raise ValueError(f"{source.name}: invalid processId")
    parsed = urllib.parse.urlsplit(value["url"])
    if (
        parsed.scheme != "http"
        or parsed.hostname != "127.0.0.1"
        or parsed.port is None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError(f"{source.name}: connector URL must be loopback HTTP")
    if not isinstance(value["token"], str) or len(value["token"]) < 32:
        raise ValueError(f"{source.name}: invalid token")
    if not isinstance(value["capabilities"], list) or not all(
        isinstance(item, str) and item for item in value["capabilities"]
    ):
        raise ValueError(f"{source.name}: invalid capabilities")
    document = value.get("document")
    if document is not None and not isinstance(document, dict):
        raise ValueError(f"{source.name}: invalid document")
    return value


def load_instances(directory: Path | None = None) -> tuple[list[dict[str, Any]], list[str]]:
    root = instance_directory() if directory is None else Path(directory)
    if not root.exists():
        return [], []
    instances: list[dict[str, Any]] = []
    warnings: list[str] = []
    for path in sorted(root.glob("*.json")):
        try:
            if path.stat().st_size > MAX_DESCRIPTOR_BYTES:
                raise ValueError(f"{path.name}: descriptor is too large")
            value = json.loads(path.read_text(encoding="utf-8-sig"))
            instances.append(validate_descriptor(value, path))
        except (OSError, ValueError, json.JSONDecodeError) as exception:
            warnings.append(str(exception))
    return instances, warnings


def public_instance(instance: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in instance.items() if key != "token"}


def normalize_target_filters(arguments: dict[str, Any]) -> dict[str, str]:
    filters: dict[str, str] = {}
    for key in TARGET_FILTER_KEYS:
        value = arguments.get(key)
        if value is None:
            continue
        if not isinstance(value, str) or not value.strip():
            raise TargetInputError(f"{key} must be a non-empty string")
        filters[key] = value.strip()
    if "application" in filters and filters["application"] not in APPLICATIONS:
        raise TargetInputError("application must be revit or autocad")
    version = filters.get("applicationVersion")
    if version and (len(version) != 4 or not version.isdigit()):
        raise TargetInputError("applicationVersion must be a four-digit year")
    return filters


def select_instance(
    arguments: dict[str, Any], directory: Path | None = None
) -> dict[str, Any]:
    filters = normalize_target_filters(arguments)
    instances, warnings = load_instances(directory)
    matches = []
    for instance in instances:
        document = instance.get("document") or {}
        if filters.get("instanceId") not in {None, instance["instanceId"]}:
            continue
        if filters.get("application") not in {None, instance["application"]}:
            continue
        if filters.get("applicationVersion") not in {None, instance["applicationVersion"]}:
            continue
        if filters.get("documentTitle") not in {None, document.get("title")}:
            continue
        matches.append(instance)
    if len(matches) == 1:
        return matches[0]
    if not matches:
        suffix = f" Invalid descriptors: {'; '.join(warnings)}" if warnings else ""
        raise RuntimeError("No matching Revit or AutoCAD connector is running." + suffix)
    choices = [public_instance(item) for item in matches]
    raise RuntimeError(
        "More than one connector matches. Pass instanceId explicitly: "
        + json.dumps(choices, ensure_ascii=False)
    )


def select_exact_target(
    target: dict[str, Any], directory: Path | None = None
) -> dict[str, Any]:
    """Resolve every execution identity field before dispatching a v2 request."""
    if not isinstance(target, dict):
        raise RuntimeError("Execution target must be an object")
    instances, warnings = load_instances(directory)
    document = target.get("document")
    if not isinstance(document, dict):
        raise RuntimeError("Execution target must include an exact document")
    matches = []
    for instance in instances:
        actual_document = instance.get("document")
        if not isinstance(actual_document, dict):
            continue
        if (
            instance.get("application") == target.get("application")
            and instance.get("applicationVersion") == target.get("release")
            and instance.get("instanceId") == target.get("instanceId")
            and instance.get("processId") == target.get("processId")
            and actual_document.get("id") == document.get("id")
            and actual_document.get("title") == document.get("title")
        ):
            matches.append(instance)
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        raise RuntimeError("More than one connector reported the same exact execution target")
    suffix = f" Invalid descriptors: {'; '.join(warnings)}" if warnings else ""
    raise RuntimeError("The exact execution target is no longer available." + suffix)


def connector_request(
    instance: dict[str, Any],
    method: str,
    path: str,
    payload: dict[str, Any] | None = None,
    timeout: float = 10,
) -> dict[str, Any]:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        instance["url"].rstrip("/") + path,
        data=body,
        method=method,
        headers={
            "Authorization": "Bearer " + instance["token"],
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exception:
        detail = exception.read().decode("utf-8", errors="replace")[:2000]
        raise RuntimeError(f"Connector HTTP {exception.code}: {detail}") from exception
    except urllib.error.URLError as exception:
        raise RuntimeError("Connector is unavailable: " + str(exception.reason)) from exception
    except json.JSONDecodeError as exception:
        raise RuntimeError("Connector returned invalid JSON") from exception
    if not isinstance(result, dict):
        raise RuntimeError("Connector response must be a JSON object")
    return result


def execute_connector_request(
    instance: dict[str, Any], arguments: dict[str, Any], mode: str
) -> dict[str, Any]:
    if arguments.get("expectedDocumentId") is not None and (instance.get("document") or {}).get("id") != arguments["expectedDocumentId"]:
        raise RuntimeError("Task step document identity changed before dispatch")
    timeout_seconds = arguments.get("timeoutSeconds", 30)
    payload = {
        "mode": mode,
        "description": arguments["description"].strip(),
        "code": arguments["code"].strip(),
        "timeoutSeconds": timeout_seconds,
        "taskId": arguments.get("taskId"),
        "taskToken": arguments.get("taskToken"),
        "target": {
            "application": instance["application"],
            "release": instance["applicationVersion"],
            "apiVariant": str(
                instance.get("apiVariant")
                or instance.get("adapterBuild")
                or instance["applicationVersion"]
            ),
            "instanceId": instance["instanceId"],
            "processId": instance["processId"],
            "document": instance.get("document"),
        },
    }
    created = connector_request(instance, "POST", "/v1/execute", payload)
    if created.get("status") in TERMINAL_STATUSES:
        return created
    request_id = created.get("requestId")
    if not isinstance(request_id, str) or not request_id:
        raise RuntimeError("Connector did not return a requestId")
    deadline = time.monotonic() + timeout_seconds + 15
    while time.monotonic() < deadline:
        result = connector_request(instance, "GET", "/v1/requests/" + request_id)
        if result.get("status") in TERMINAL_STATUSES:
            return result
        time.sleep(0.2)
    try:
        connector_request(instance, "POST", "/v1/requests/" + request_id + "/cancel")
    except RuntimeError:
        # The host may already be running a non-cancellable Autodesk operation.
        # Preserve the timeout while the journal records that cancellation was
        # requested but not confirmed.
        pass
    raise RuntimeError(f"Timed out waiting for connector request {request_id}; cancellation requested")


def execute_connector_operation(
    instance: dict[str, Any],
    operation: str,
    arguments: dict[str, Any],
    mode: str = "read",
    timeout_seconds: int = 30,
    *,
    task_id: str | None = None,
    task_token: str | None = None,
) -> dict[str, Any]:
    payload = {
        "mode": mode,
        "operation": operation,
        "taskId": task_id,
        "taskToken": task_token,
        "description": "Capture a focused Revit view" if operation == "view.capture" else operation,
        "viewCapture": arguments if operation == "view.capture" else None,
        "familySession": arguments if operation == "family.session" else None,
        "timeoutSeconds": timeout_seconds,
        "target": {
            "application": instance["application"],
            "release": instance["applicationVersion"],
            "apiVariant": str(
                instance.get("apiVariant")
                or instance.get("adapterBuild")
                or instance["applicationVersion"]
            ),
            "instanceId": instance["instanceId"],
            "processId": instance["processId"],
            "document": instance.get("document"),
        },
    }
    created = connector_request(instance, "POST", "/v1/execute", payload)
    if created.get("status") in TERMINAL_STATUSES:
        return created
    request_id = created.get("requestId")
    if not isinstance(request_id, str) or not request_id:
        raise RuntimeError("Connector did not return a requestId")
    deadline = time.monotonic() + timeout_seconds + 15
    while time.monotonic() < deadline:
        result = connector_request(instance, "GET", "/v1/requests/" + request_id)
        if result.get("status") in TERMINAL_STATUSES:
            return result
        time.sleep(0.2)
    try:
        connector_request(instance, "POST", "/v1/requests/" + request_id + "/cancel")
    except RuntimeError:
        pass
    raise RuntimeError(
        f"Timed out waiting for connector request {request_id}; cancellation requested"
    )
