"""Unified, agent-independent BIM Bridge Runtime service."""

from __future__ import annotations

import time
import uuid
from typing import Any, Iterable

from .audit import AuditTrail, ExecutionJournal
from . import conduit_tools, coordination, family_sessions, job_provider
from .capabilities import (
    CapabilityDefinition,
    CapabilityRegistry,
    ProviderCandidate,
    RoutePlan,
    default_registry,
)
from .hosts import (
    APPLICATIONS,
    connector_request,
    execute_connector_request,
    execute_connector_operation,
    load_instances,
    normalize_target_filters,
    public_instance,
    select_instance,
    select_exact_target,
)
from .policy import PolicyEngine, canonical_hash
from .providers import MANAGER, ProviderManager
from .verification import VerificationOrchestrator, normalize_execution_result, verification_result


class RuntimeRequestError(RuntimeError):
    """A BIM Bridge request cannot be planned or executed safely."""


KNOWN_LEGACY_PROVIDER_IDS = {"revit-community", "autocad-pro"}
REVIT_HOST_PROVIDER_ID = "revit.connector.v1"
REVIT_CAPTURE_TOOL = {
    "name": "capture_view",
    "title": "Capture Revit view",
    "description": (
        "Export the active or explicitly selected Revit view to a PNG in the bounded "
        "BIM Bridge capture directory without changing the model."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "instanceId": {"type": "string", "description": "Exact running Revit instance."},
            "taskId": {"type": "string", "minLength": 1},
            "taskToken": {"type": "string", "minLength": 1},
            "applicationVersion": {"type": "string", "pattern": "^[0-9]{4}$"},
            "documentTitle": {"type": "string"},
            "viewId": {"type": "integer", "minimum": 1},
            "viewUniqueId": {"type": "string"},
            "viewName": {"type": "string"},
            "fileStem": {"type": "string", "maxLength": 80},
            "pixelSize": {"type": "integer", "minimum": 256, "maximum": 4096, "default": 1600},
            "dpi": {"type": "integer", "enum": [72, 150, 300, 600], "default": 150},
            "fitDirection": {
                "type": "string",
                "enum": ["horizontal", "vertical"],
                "default": "horizontal",
            },
        },
        "additionalProperties": False,
    },
    "annotations": {
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": False,
        "openWorldHint": False,
    },
}


def _capture_search_match(query: str) -> bool:
    words = [word for word in query.lower().replace("_", " ").split() if word]
    haystack = "capture view screenshot image png export revit"
    return not words or any(word in haystack for word in words)


def _validate_capture_arguments(arguments: dict[str, Any]) -> dict[str, Any]:
    schema = REVIT_CAPTURE_TOOL["inputSchema"]
    properties = schema["properties"]
    unknown = sorted(set(arguments) - set(properties))
    if unknown:
        raise RuntimeRequestError("Unknown capture argument(s): " + ", ".join(unknown))
    if ("taskId" in arguments) != ("taskToken" in arguments):
        raise RuntimeRequestError("Capture taskId and taskToken must be supplied together")
    for key in ("taskId", "taskToken"):
        if key in arguments and (not isinstance(arguments[key], str) or not arguments[key].strip()):
            raise RuntimeRequestError("Capture task credentials must be non-empty strings")
    selectors = [name for name in ("viewId", "viewUniqueId", "viewName") if name in arguments]
    if len(selectors) > 1:
        raise RuntimeRequestError("Pass only one of viewId, viewUniqueId, or viewName")
    pixel_size = arguments.get("pixelSize", 1600)
    if isinstance(pixel_size, bool) or not isinstance(pixel_size, int) or not 256 <= pixel_size <= 4096:
        raise RuntimeRequestError("pixelSize must be an integer from 256 through 4096")
    if arguments.get("dpi", 150) not in {72, 150, 300, 600}:
        raise RuntimeRequestError("dpi must be one of 72, 150, 300, or 600")
    if arguments.get("fitDirection", "horizontal") not in {"horizontal", "vertical"}:
        raise RuntimeRequestError("fitDirection must be horizontal or vertical")
    for name in ("instanceId", "applicationVersion", "documentTitle", "viewUniqueId", "viewName", "fileStem"):
        if name in arguments and (
            not isinstance(arguments[name], str) or not arguments[name].strip()
        ):
            raise RuntimeRequestError(f"{name} must be a non-empty string")
    view_id = arguments.get("viewId")
    if view_id is not None and (
        isinstance(view_id, bool) or not isinstance(view_id, int) or view_id < 1
    ):
        raise RuntimeRequestError("viewId must be a positive integer")
    return arguments


def _target_from_instance(instance: dict[str, Any]) -> dict[str, Any]:
    target: dict[str, Any] = {
        "application": instance["application"],
        "release": instance["applicationVersion"],
        "apiVariant": str(
            instance.get("apiVariant")
            or instance.get("adapterBuild")
            or instance["applicationVersion"]
        ),
        "instanceId": instance["instanceId"],
        "processId": instance["processId"],
    }
    if instance.get("runtimeVariant"):
        target["runtimeVariant"] = str(instance["runtimeVariant"])
    document = instance.get("document")
    if isinstance(document, dict) and document.get("id") and document.get("title"):
        target["document"] = {
            key: document.get(key) for key in ("id", "title", "path") if key in document
        }
    return target


class BimBridgeRuntime:
    def __init__(
        self,
        *,
        providers: ProviderManager | None = None,
        capabilities: CapabilityRegistry | None = None,
        policy: PolicyEngine | None = None,
        audit: AuditTrail | None = None,
        verifier: VerificationOrchestrator | None = None,
    ):
        self.providers = MANAGER if providers is None else providers
        self.capabilities = default_registry() if capabilities is None else capabilities
        self.policy = PolicyEngine() if policy is None else policy
        self.audit = AuditTrail(sink=ExecutionJournal().write) if audit is None else audit
        self.verifier = VerificationOrchestrator() if verifier is None else verifier

    def open_adapter_session(self, adapter_id: str, *, ttl_seconds: int | None = None) -> dict[str, Any]:
        """Open a runtime-owned session after the transport authenticates an adapter."""
        session = self.policy.sessions.open(adapter_id, ttl_seconds=ttl_seconds)
        self.audit.record(
            "",
            "session.opened",
            {
                "adapterId": session["adapterId"],
                "sessionId": session["sessionId"],
                "expiresAtUtc": session["expiresAtUtc"],
            },
        )
        return session

    def close_adapter_session(self, session_id: str) -> None:
        self.policy.sessions.close(session_id)
        self.audit.record("", "session.closed", {"sessionId": session_id})

    def issue_approval(
        self,
        request: dict[str, Any],
        decision: dict[str, Any],
        *,
        issued_by: str,
        ttl_seconds: int = 300,
    ) -> dict[str, Any]:
        """Issue a signed grant for a trusted approval-presenter decision."""
        return self.policy.approvals.issue(
            request, decision, issued_by=issued_by, ttl_seconds=ttl_seconds
        )

    def prepare(
        self,
        request: dict[str, Any],
        *,
        candidates: Iterable[ProviderCandidate] | None = None,
        host_capabilities: Iterable[str] = (),
    ) -> tuple[RoutePlan, dict[str, Any]]:
        """Validate, route, and evaluate one contract-v2 request without executing it."""
        if request.get("kind") != "execution_request" or request.get("contractVersion") != 2:
            raise RuntimeRequestError("Runtime accepts execution_request contract version 2")
        target = request.get("target")
        session = request.get("adapterSession")
        if not isinstance(target, dict) or not isinstance(session, dict):
            raise RuntimeRequestError("Request target and adapterSession must be objects")
        application = target.get("application")
        release = target.get("release")
        intent = request.get("intent")
        capability_id = request.get("capabilityId")
        if application not in APPLICATIONS or intent not in {"read", "write"}:
            raise RuntimeRequestError("Request application or intent is invalid")
        if not isinstance(release, str) or not isinstance(capability_id, str):
            raise RuntimeRequestError("Request release and capabilityId are required")
        if capability_id == f"{application}.task.coordination":
            coordination.validate_control(request.get("arguments"), intent)
            if type(request.get("dryRun")) is not bool:
                raise RuntimeRequestError("Task coordination dryRun must be boolean")
            if type(request.get("timeoutSeconds")) is not int or not 1 <= request["timeoutSeconds"] <= 1800:
                raise RuntimeRequestError("Task coordination timeoutSeconds must be an integer within contract bounds")
        if capability_id.startswith("revit.conduit."):
            conduit_tools.validate(capability_id.removeprefix("revit."), request.get("arguments"))
        if capability_id == "revit.family.session":
            family_sessions.validate(request.get("arguments"), intent)
        plan = self.capabilities.resolve(
            capability_id,
            application=application,
            release=release,
            intent=intent,
            host_capabilities=host_capabilities,
            exact_instance=bool(target.get("instanceId") and target.get("processId")),
            exact_document=isinstance(target.get("document"), dict),
            provider_preference=request.get("providerPreference"),
            candidates=candidates,
        )
        decision = self.policy.evaluate(request, plan.capability, plan)
        self.audit.record(
            str(request.get("correlationId", "")),
            "request.prepared",
            {
                "requestHash": canonical_hash(request),
                "adapter": {
                    "adapterId": session.get("adapterId"),
                    "sessionId": session.get("sessionId"),
                },
                "route": plan.effect,
                "policy": decision,
            },
        )
        return plan, decision

    def execute(self, request: dict[str, Any]) -> dict[str, Any]:
        """Execute one contract-v2 request through the unified runtime pipeline."""
        started = time.monotonic()
        correlation_id = str(request.get("correlationId", ""))
        target = request.get("target")
        if not isinstance(target, dict):
            raise RuntimeRequestError("Request target must be an object")
        try:
            instance = select_exact_target(target)
            plan, decision = self.prepare(
                request, host_capabilities=instance.get("capabilities", [])
            )
        except Exception as exc:
            audit_id = self.audit.record(
                correlation_id, "execution.rejected", {"stage": "routing", "error": str(exc)}
            )
            return normalize_execution_result(
                request,
                provider_id="unresolved",
                host_evidence=target,
                provider_result={
                    "status": "rejected",
                    "errors": [
                        {
                            "code": "runtime.target_or_route_rejected",
                            "stage": "routing",
                            "message": str(exc)[:4096],
                            "retryable": False,
                        }
                    ],
                },
                audit_id=audit_id,
                started_at=started,
            )

        if decision["status"] != "allowed":
            audit_id = self.audit.record(
                correlation_id, "execution.rejected", {"stage": "policy", "decision": decision}
            )
            return normalize_execution_result(
                request,
                provider_id=plan.selected.provider_id,
                host_evidence=_target_from_instance(instance),
                provider_result={
                    "status": "rejected",
                    "errors": [
                        {
                            "code": "runtime." + decision["status"],
                            "stage": "policy",
                            "message": ", ".join(decision["reasonCodes"]),
                            "retryable": decision["status"] == "approval_required",
                        }
                    ],
                },
                audit_id=audit_id,
                started_at=started,
            )
        if request.get("dryRun") and not plan.capability.supports_dry_run:
            audit_id = self.audit.record(
                correlation_id, "execution.rejected", {"stage": "planning", "error": "dry_run_unsupported"}
            )
            return normalize_execution_result(
                request,
                provider_id=plan.selected.provider_id,
                host_evidence=_target_from_instance(instance),
                provider_result={
                    "status": "rejected",
                    "errors": [
                        {
                            "code": "runtime.dry_run_unsupported",
                            "stage": "planning",
                            "message": "The selected capability does not support dry-run",
                            "retryable": False,
                        }
                    ],
                },
                audit_id=audit_id,
                started_at=started,
            )

        plan.mark_execution_started()
        execution_audit_id = self.audit.record(
            correlation_id, "execution.started", {"route": plan.effect, "target": target}
        )
        try:
            provider_result = self._execute_host_capability(instance, request)
            verification = (
                self.verifier.verify(
                    request.get("verification"),
                    lambda capability_id, arguments: self._execute_verification_check(
                        instance, capability_id,
                        {**arguments, **{key: request.get("arguments", {})[key] for key in ("taskId", "taskToken") if key in request.get("arguments", {})}}
                        if isinstance(arguments, dict) else arguments,
                    ),
                )
                if provider_result.get("status") == "succeeded"
                else verification_result(request.get("verification"))
            )
            result = normalize_execution_result(
                request,
                provider_id=plan.selected.provider_id,
                host_evidence=_target_from_instance(instance),
                provider_result=provider_result,
                audit_id=execution_audit_id,
                started_at=started,
                verification=verification,
            )
            self.audit.record(correlation_id, "execution.completed", {"result": result})
            return result
        except Exception as exc:
            self.audit.record(correlation_id, "execution.failed", {"error": str(exc)})
            return normalize_execution_result(
                request,
                provider_id=plan.selected.provider_id,
                host_evidence=_target_from_instance(instance),
                provider_result={
                    "status": "failed",
                    "errors": [
                        {
                            "code": "runtime.execution_failed",
                            "stage": "execution",
                            "message": str(exc)[:4096],
                            "retryable": False,
                        }
                    ],
                },
                audit_id=execution_audit_id,
                started_at=started,
            )

    @staticmethod
    def _execute_host_capability(
        instance: dict[str, Any], request: dict[str, Any]
    ) -> dict[str, Any]:
        capability_id = str(request["capabilityId"])
        if capability_id == f"{instance['application']}.task.coordination":
            value = coordination.execute_control(
                instance, request.get("arguments"), str(request["intent"]),
                dry_run=request.get("dryRun", False),
                timeout=int(request.get("timeoutSeconds", 30)), target=request["target"],
            )
            return {"status": "succeeded", "result": value}
        if capability_id == "revit.family.session":
            return family_sessions.execute(instance, request.get("arguments"), str(request["intent"]),
                dry_run=request.get("dryRun", False), timeout=int(request.get("timeoutSeconds", 30)))
        if capability_id.endswith(".document.info"):
            value = connector_request(instance, "GET", "/v1/info")
            return {"status": "succeeded", "result": value}
        if capability_id.endswith(".selection.read"):
            arguments = dict(request.get("arguments", {}))
            if arguments.get("taskId") is not None or arguments.get("taskToken") is not None:
                return execute_connector_operation(
                    instance, "selection.read", {}, "read", int(request.get("timeoutSeconds", 30)),
                    task_id=arguments.get("taskId"), task_token=arguments.get("taskToken"),
                )
            value = connector_request(instance, "GET", "/v1/selection")
            return {"status": "succeeded", "result": value}
        if capability_id.startswith("revit.conduit."):
            return conduit_tools.execute(
                instance, capability_id.removeprefix("revit."), request.get("arguments"),
                str(request["intent"]), dry_run=request.get("dryRun", False),
                timeout=int(request.get("timeoutSeconds", 30)),
            )
        if capability_id == "revit.view.capture":
            arguments = dict(request.get("arguments", {}))
            task_id, task_token = arguments.pop("taskId", None), arguments.pop("taskToken", None)
            return execute_connector_operation(
                instance,
                "view.capture",
                arguments,
                "read",
                int(request.get("timeoutSeconds", 30)),
                task_id=task_id, task_token=task_token,
            )
        if capability_id.endswith(".code.read") or capability_id.endswith(".code.write"):
            return execute_connector_request(
                instance, dict(request.get("arguments", {})), str(request["intent"])
            )
        raise RuntimeRequestError("The selected host capability has no execution binding")

    @staticmethod
    def _execute_verification_check(
        instance: dict[str, Any], capability_id: str, arguments: Any
    ) -> Any:
        if not isinstance(arguments, dict):
            raise RuntimeRequestError("Verification arguments must be an object")
        application = instance["application"]
        if capability_id == f"{application}.document.info":
            return connector_request(instance, "GET", "/v1/info")
        if capability_id == f"{application}.selection.read":
            if arguments.get("taskId") is not None or arguments.get("taskToken") is not None:
                value = execute_connector_operation(
                    instance, "selection.read", {}, "read", 30,
                    task_id=arguments.get("taskId"), task_token=arguments.get("taskToken"),
                )
                if value.get("status") != "succeeded":
                    raise RuntimeRequestError("Task-scoped selection read-back failed")
                return value.get("result")
            return connector_request(instance, "GET", "/v1/selection")
        raise RuntimeRequestError("Verification checks may use only structured read-back capabilities")

    @staticmethod
    def _legacy_request(
        capability_id: str,
        intent: str,
        target: dict[str, Any],
        arguments: dict[str, Any],
        *,
        dry_run: bool = False,
    ) -> dict[str, Any]:
        return {
            "kind": "execution_request",
            "contractVersion": 2,
            "correlationId": "legacy-" + uuid.uuid4().hex,
            "adapterSession": {
                "adapterId": "codex-mcp-v1",
                "sessionId": "embedded-stdio",
                "authenticated": True,
            },
            "target": target,
            "capabilityId": capability_id,
            "arguments": arguments,
            "intent": intent,
            "timeoutSeconds": int(arguments.get("timeoutSeconds", 60)),
            "dryRun": dry_run,
        }

    def _plan_connector(
        self,
        instance: dict[str, Any],
        capability_suffix: str,
        intent: str,
        arguments: dict[str, Any],
        *, dry_run: bool = False,
    ) -> tuple[dict[str, Any], RoutePlan]:
        target = _target_from_instance(instance)
        capability_id = f"{instance['application']}.{capability_suffix}"
        request = self._legacy_request(capability_id, intent, target, arguments, dry_run=dry_run)
        plan = self.capabilities.resolve(
            capability_id,
            application=instance["application"],
            release=instance["applicationVersion"],
            intent=intent,
            host_capabilities=instance.get("capabilities", []),
            exact_instance=True,
            exact_document="document" in target,
            compatibility_v1=True,
        )
        decision = self.policy.evaluate(request, plan.capability, plan, compatibility_v1=True)
        if decision["status"] != "allowed":
            raise RuntimeRequestError("Runtime policy rejected the compatibility request")
        self.audit.record(request["correlationId"], "route.planned", {"route": plan.effect, "policy": decision})
        return request, plan

    def list_instances(self, arguments: dict[str, Any]) -> dict[str, Any]:
        filters = normalize_target_filters(arguments)
        instances, warnings = load_instances()
        visible = [
            public_instance(instance)
            for instance in instances
            if filters.get("application") in {None, instance["application"]}
            and filters.get("applicationVersion") in {None, instance["applicationVersion"]}
        ]
        return {"instances": visible, "warnings": warnings}

    def document_info(self, arguments: dict[str, Any]) -> dict[str, Any]:
        instance = select_instance(arguments)
        request, plan = self._plan_connector(instance, "document.info", "read", arguments)
        plan.mark_execution_started()
        try:
            result = connector_request(instance, "GET", "/v1/info")
        except Exception as exc:
            self.audit.record(request["correlationId"], "execution.failed", {"error": str(exc)})
            raise
        self.audit.record(request["correlationId"], "execution.completed", {"status": result.get("status", "succeeded")})
        return result

    def selection(self, arguments: dict[str, Any]) -> dict[str, Any]:
        instance = select_instance(arguments)
        request, plan = self._plan_connector(instance, "selection.read", "read", arguments)
        plan.mark_execution_started()
        try:
            result = connector_request(instance, "GET", "/v1/selection")
        except Exception as exc:
            self.audit.record(request["correlationId"], "execution.failed", {"error": str(exc)})
            raise
        self.audit.record(request["correlationId"], "execution.completed", {"status": result.get("status", "succeeded")})
        return result

    def execute_code(self, arguments: dict[str, Any], mode: str) -> dict[str, Any]:
        instance = select_instance(arguments)
        request, plan = self._plan_connector(instance, f"code.{mode}", mode, arguments)
        plan.mark_execution_started()
        try:
            result = execute_connector_request(instance, arguments, mode)
        except Exception as exc:
            self.audit.record(request["correlationId"], "execution.failed", {"error": str(exc)})
            raise
        self.audit.record(
            request["correlationId"],
            "execution.completed",
            {"status": result.get("status"), "rolledBack": result.get("rolledBack"), "taskId": arguments.get("taskId")},
        )
        return result

    def list_providers(self, probe: bool = False) -> dict[str, Any]:
        result = self.providers.list(probe=probe)
        result["providers"].append(conduit_tools.descriptor(probe))
        result["providers"].append(coordination.descriptor(probe))
        result["providers"].append(family_sessions.descriptor(probe))
        result["providers"].append(job_provider.descriptor(probe))
        instances, warnings = load_instances()
        ready = [
            instance
            for instance in instances
            if instance.get("application") == "revit"
            and "view.capture" in instance.get("capabilities", [])
        ]
        result["providers"].append(
            {
                "id": REVIT_HOST_PROVIDER_ID,
                "displayName": "BIM Bridge Revit Connector",
                "version": "1",
                "application": "revit",
                "status": "ready" if ready else ("unavailable" if probe else "configured"),
                "toolCount": 1,
                "error": None
                if ready or not probe
                else "No running Revit connector advertises view.capture",
                "source": "builtin-host",
            }
        )
        result["warnings"] = list(result.get("warnings", [])) + warnings
        return result

    def search_provider_tools(
        self, query: str, provider_id: str | None, limit: int
    ) -> dict[str, Any]:
        if provider_id == conduit_tools.PROVIDER_ID:
            return conduit_tools.search(query, limit)
        if provider_id == job_provider.PROVIDER_ID:
            return job_provider.search(query, limit)
        if provider_id == family_sessions.PROVIDER_ID:
            return family_sessions.search(query, limit)
        if provider_id == coordination.COORDINATION_PROVIDER_ID:
            return coordination.search(query, limit)
        if provider_id == REVIT_HOST_PROVIDER_ID:
            return {
                "tools": [
                    {
                        "provider": REVIT_HOST_PROVIDER_ID,
                        "name": REVIT_CAPTURE_TOOL["name"],
                        "description": REVIT_CAPTURE_TOOL["description"],
                        "access": "read",
                        "blocked": False,
                    }
                ]
                if _capture_search_match(query)
                else [],
                "errors": [],
            }
        result = self.providers.search(query, provider_id, limit)
        if provider_id is None and _capture_search_match(query):
            result["tools"].append(
                {
                    "provider": REVIT_HOST_PROVIDER_ID,
                    "name": REVIT_CAPTURE_TOOL["name"],
                    "description": REVIT_CAPTURE_TOOL["description"],
                    "access": "read",
                    "blocked": False,
                }
            )
            result["tools"] = result["tools"][:limit]
        if provider_id is None:
            result["tools"] = (result["tools"] + conduit_tools.search(query, limit)["tools"] + coordination.search(query, limit)["tools"] + family_sessions.search(query, limit)["tools"] + job_provider.search(query, limit)["tools"])[:limit]
        return result

    def provider_schema(self, provider_id: str, tool_name: str) -> dict[str, Any]:
        if provider_id == conduit_tools.PROVIDER_ID:
            return conduit_tools.schema(tool_name)
        if provider_id == job_provider.PROVIDER_ID:
            return job_provider.schema(tool_name)
        if provider_id == family_sessions.PROVIDER_ID:
            return family_sessions.schema(tool_name)
        if provider_id == coordination.COORDINATION_PROVIDER_ID:
            return coordination.schema(tool_name)
        if provider_id == REVIT_HOST_PROVIDER_ID:
            if tool_name != REVIT_CAPTURE_TOOL["name"]:
                raise RuntimeRequestError(
                    f"Provider {provider_id} does not expose {tool_name}"
                )
            return {"provider": provider_id, "tool": REVIT_CAPTURE_TOOL, "access": "read"}
        return self.providers.schema(provider_id, tool_name)

    def _invoke_revit_capture(
        self, arguments: dict[str, Any], requested_access: str, timeout: int
    ) -> dict[str, Any]:
        if requested_access != "read":
            raise RuntimeRequestError("revit.connector.v1.capture_view is read-only")
        values = _validate_capture_arguments(dict(arguments))
        target_filters = {
            key: value
            for key, value in values.items()
            if key in {"instanceId", "applicationVersion", "documentTitle"}
        }
        target_filters["application"] = "revit"
        instance = select_instance(target_filters)
        request, plan = self._plan_connector(instance, "view.capture", "read", values)
        plan.mark_execution_started()
        capture_arguments = {
            key: value
            for key, value in values.items()
            if key
            in {
                "viewId",
                "viewUniqueId",
                "viewName",
                "fileStem",
                "pixelSize",
                "dpi",
                "fitDirection",
            }
        }
        capture_arguments.setdefault("pixelSize", 1600)
        capture_arguments.setdefault("dpi", 150)
        capture_arguments.setdefault("fitDirection", "horizontal")
        try:
            connector_result = execute_connector_operation(
                instance, "view.capture", capture_arguments, "read", timeout,
                task_id=values.get("taskId"), task_token=values.get("taskToken"),
            )
        except Exception as exc:
            self.audit.record(request["correlationId"], "execution.failed", {"error": str(exc)})
            raise
        result = {
            "status": connector_result.get("status", "failed"),
            "provider": REVIT_HOST_PROVIDER_ID,
            "providerVersion": instance.get("applicationVersion"),
            "tool": REVIT_CAPTURE_TOOL["name"],
            "access": "read",
            "dryRun": False,
            "simulationLevel": "none",
            "result": connector_result,
        }
        self.audit.record(
            request["correlationId"],
            "execution.completed",
            {"status": result["status"]},
        )
        return result

    def _provider_target(self, provider_id: str) -> tuple[str, dict[str, Any]]:
        application = self.providers.get(provider_id).descriptor.get("application")
        if application not in APPLICATIONS:
            raise RuntimeRequestError(f"Provider {provider_id} has no supported Autodesk application")
        instances, _warnings = load_instances()
        matching = [item for item in instances if item.get("application") == application]
        if len(matching) > 1:
            raise RuntimeRequestError(
                f"{provider_id} cannot target one of several {application} sessions safely. "
                "Close the extra sessions or use the instance-aware BIM Bridge connector."
            )
        if matching:
            return application, _target_from_instance(matching[0])
        return application, {
            "application": application,
            "release": str(self.providers.get(provider_id).descriptor.get("applicationVersion", "0000")),
            "apiVariant": "provider-managed",
        }

    def invoke_provider(
        self,
        provider_id: str,
        tool_name: str,
        arguments: dict[str, Any],
        requested_access: str,
        dry_run: bool,
        timeout: int,
    ) -> dict[str, Any]:
        if provider_id == conduit_tools.PROVIDER_ID:
            return conduit_tools.invoke(self, tool_name, arguments, requested_access, dry_run, timeout)
        if provider_id == job_provider.PROVIDER_ID:
            return job_provider.invoke(self, tool_name, arguments, requested_access, dry_run, timeout)
        if provider_id == family_sessions.PROVIDER_ID:
            return family_sessions.invoke(self, tool_name, arguments, requested_access, dry_run, timeout)
        if provider_id == coordination.COORDINATION_PROVIDER_ID:
            return coordination.invoke(self, tool_name, arguments, requested_access, dry_run, timeout)
        if provider_id == REVIT_HOST_PROVIDER_ID:
            if tool_name != REVIT_CAPTURE_TOOL["name"]:
                raise RuntimeRequestError(
                    f"Provider {provider_id} does not expose {tool_name}"
                )
            if dry_run:
                raise RuntimeRequestError("Read-only capture does not accept dryRun")
            return self._invoke_revit_capture(arguments, requested_access, timeout)
        schema = self.providers.schema(provider_id, tool_name)
        access = schema["access"]
        if requested_access == "read" and access != "read":
            raise RuntimeRequestError(
                f"{provider_id}.{tool_name} is not classified read-only; use the write provider tool"
            )
        application, target = self._provider_target(provider_id)
        # Application-global providers cannot present a connector task token or
        # atomically prove which instance they operate. Refuse before execution.
        instances, _ = load_instances()
        if any(item.get("application") == application and "task.coordination" in item.get("capabilities", []) for item in instances):
            raise RuntimeRequestError("This provider cannot participate in instance task coordination; use the instance-aware connector")
        capability = CapabilityDefinition(
            capability_id=f"{application}.provider.{requested_access}",
            application=application,
            intents=(requested_access,),
            risk="low" if requested_access == "read" else "high",
            supports_dry_run=bool(dry_run),
            candidates=(
                ProviderCandidate(
                    provider_id=provider_id,
                    kind="structured_mcp",
                    targeting="application",
                    trust=str(
                        self.providers.get(provider_id).descriptor.get("trust")
                        or (
                            "third_party"
                            if provider_id in KNOWN_LEGACY_PROVIDER_IDS
                            else "unknown"
                        )
                    ),
                    priority=20,
                ),
            ),
        )
        registry = CapabilityRegistry((capability,))
        request = self._legacy_request(
            capability.capability_id,
            requested_access,
            target,
            {"toolName": tool_name, "arguments": arguments, "timeoutSeconds": timeout},
            dry_run=dry_run,
        )
        plan = registry.resolve(
            capability.capability_id,
            application=application,
            release=str(target["release"]),
            intent=requested_access,
            host_capabilities=(),
            exact_instance="instanceId" in target,
            exact_document="document" in target,
            compatibility_v1=True,
        )
        decision = self.policy.evaluate(request, capability, plan, compatibility_v1=True)
        if decision["status"] != "allowed":
            raise RuntimeRequestError("Runtime policy rejected the provider request")
        self.audit.record(request["correlationId"], "route.planned", {"route": plan.effect, "policy": decision})
        plan.mark_execution_started()
        try:
            result = self.providers.invoke(
                provider_id,
                tool_name,
                arguments,
                requested_access,
                dry_run,
                timeout,
            )
        except Exception as exc:
            self.audit.record(request["correlationId"], "execution.failed", {"error": str(exc)})
            raise
        self.audit.record(request["correlationId"], "execution.completed", {"status": result.get("status")})
        return result
