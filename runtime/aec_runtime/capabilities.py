"""Capability metadata and deterministic provider routing for BIM Bridge."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable

from .conduit_tools import OPERATIONS as CONDUIT_OPERATIONS, input_schema as conduit_input_schema


class CapabilityError(RuntimeError):
    """A capability or route cannot be resolved safely."""


TARGETING_ORDER = {"application": 0, "instance": 1, "document": 2}
TRUST_ORDER = {"unknown": 0, "third_party": 1, "approved": 2, "local": 3}


@dataclass(frozen=True)
class ProviderCandidate:
    provider_id: str
    kind: str
    targeting: str
    trust: str
    priority: int = 100
    healthy: bool = True
    supported_releases: tuple[str, ...] = ("*",)
    required_host_capabilities: tuple[str, ...] = ()

    def supports(self, release: str, host_capabilities: Iterable[str]) -> bool:
        available = set(host_capabilities)
        return (
            self.healthy
            and ("*" in self.supported_releases or release in self.supported_releases)
            and set(self.required_host_capabilities).issubset(available)
        )


@dataclass(frozen=True)
class CapabilityDefinition:
    capability_id: str
    application: str
    intents: tuple[str, ...]
    risk: str
    input_schema: dict[str, Any] = field(default_factory=dict)
    output_schema: dict[str, Any] = field(default_factory=dict)
    required_host_capabilities: tuple[str, ...] = ()
    supports_dry_run: bool = False
    supports_cancellation: bool = False
    idempotency: str = "none"
    transaction_guarantee: str = "none"
    rollback_guarantee: str = "none"
    verification_guarantee: str = "none"
    candidates: tuple[ProviderCandidate, ...] = ()

    def public(self) -> dict[str, Any]:
        return {
            "kind": "capability",
            "contractVersion": 2,
            "id": self.capability_id,
            "application": self.application,
            "intents": list(self.intents),
            "risk": self.risk,
            "inputSchema": self.input_schema,
            "outputSchema": self.output_schema,
            "requiredHostCapabilities": list(self.required_host_capabilities),
            "supportsDryRun": self.supports_dry_run,
            "supportsCancellation": self.supports_cancellation,
            "idempotency": self.idempotency,
            "transactionGuarantee": self.transaction_guarantee,
            "rollbackGuarantee": self.rollback_guarantee,
            "verificationGuarantee": self.verification_guarantee,
        }


@dataclass
class RoutePlan:
    capability: CapabilityDefinition
    candidates: tuple[ProviderCandidate, ...]
    selected: ProviderCandidate
    effect: dict[str, Any]
    execution_started: bool = False

    def mark_execution_started(self) -> None:
        self.execution_started = True

    def fallback(self) -> ProviderCandidate:
        if self.execution_started:
            raise CapabilityError(
                "Provider fallback is forbidden after execution may have started"
            )
        try:
            index = self.candidates.index(self.selected)
            return self.candidates[index + 1]
        except (ValueError, IndexError) as exc:
            raise CapabilityError("No eligible fallback provider") from exc


class CapabilityRegistry:
    def __init__(self, definitions: Iterable[CapabilityDefinition] = ()):
        self._definitions: dict[str, CapabilityDefinition] = {}
        for definition in definitions:
            self.register(definition)

    def register(self, definition: CapabilityDefinition) -> None:
        if definition.capability_id in self._definitions:
            raise CapabilityError(f"Duplicate capability: {definition.capability_id}")
        if definition.application not in {"revit", "autocad"}:
            raise CapabilityError(f"Unsupported application: {definition.application}")
        self._definitions[definition.capability_id] = definition

    def get(self, capability_id: str) -> CapabilityDefinition:
        try:
            return self._definitions[capability_id]
        except KeyError as exc:
            raise CapabilityError(f"Unknown capability: {capability_id}") from exc

    def list(self, application: str | None = None) -> list[dict[str, Any]]:
        return [
            definition.public()
            for definition in sorted(self._definitions.values(), key=lambda item: item.capability_id)
            if application in {None, definition.application}
        ]

    def resolve(
        self,
        capability_id: str,
        *,
        application: str,
        release: str,
        intent: str,
        host_capabilities: Iterable[str],
        exact_instance: bool,
        exact_document: bool,
        provider_preference: str | None = None,
        candidates: Iterable[ProviderCandidate] | None = None,
        compatibility_v1: bool = False,
    ) -> RoutePlan:
        definition = self.get(capability_id)
        if definition.application != application or intent not in definition.intents:
            raise CapabilityError("Capability does not match the requested application or intent")
        available = set(host_capabilities)
        if not set(definition.required_host_capabilities).issubset(available):
            raise CapabilityError("Host does not advertise the required capability")
        eligible = []
        for candidate in candidates if candidates is not None else definition.candidates:
            if not candidate.supports(release, available):
                continue
            strength = TARGETING_ORDER.get(candidate.targeting, -1)
            if (
                intent == "write"
                and not compatibility_v1
                and (not exact_instance or not exact_document or strength < 2)
            ):
                continue
            eligible.append(candidate)
        if provider_preference:
            preferred = [item for item in eligible if item.provider_id == provider_preference]
            if not preferred:
                raise CapabilityError("Preferred provider is not eligible for this request")
            eligible = preferred
        eligible.sort(
            key=lambda item: (
                item.priority,
                -TARGETING_ORDER.get(item.targeting, -1),
                -TRUST_ORDER.get(item.trust, -1),
                item.provider_id,
            )
        )
        if not eligible:
            raise CapabilityError("No eligible provider can satisfy the exact target safely")
        return RoutePlan(
            capability=definition,
            candidates=tuple(eligible),
            selected=eligible[0],
            effect={
                "intent": intent,
                "risk": definition.risk,
                "application": application,
                "release": release,
                "targeting": eligible[0].targeting,
                "providerId": eligible[0].provider_id,
            },
        )


def default_registry() -> CapabilityRegistry:
    definitions: list[CapabilityDefinition] = []
    for application in ("revit", "autocad"):
        connector = ProviderCandidate(
            provider_id=f"{application}.connector.v1",
            kind="host",
            targeting="document",
            trust="local",
            priority=10,
        )
        definitions.extend(
            [
                CapabilityDefinition(
                    f"{application}.document.info",
                    application,
                    ("read",),
                    "low",
                    idempotency="guaranteed",
                    verification_guarantee="readback",
                    candidates=(connector,),
                ),
                CapabilityDefinition(
                    f"{application}.task.coordination",
                    application,
                    ("read", "write"),
                    "low",
                    input_schema={"$ref": "https://bim-bridge.local/protocol/v2/bim-bridge-contract.schema.json#/$defs/taskControl"},
                    output_schema={"oneOf": [
                        {"$ref": "https://bim-bridge.local/protocol/v2/bim-bridge-contract.schema.json#/$defs/taskSnapshot"},
                        {"$ref": "https://bim-bridge.local/protocol/v2/bim-bridge-contract.schema.json#/$defs/taskSubmission"},
                        {"$ref": "https://bim-bridge.local/protocol/v2/bim-bridge-contract.schema.json#/$defs/taskStatus"},
                        {"type": "object", "required": ["dryRun", "executed", "action"], "additionalProperties": False,
                         "properties": {"dryRun": {"const": True}, "executed": {"const": False}, "action": {"type": "string"}}},
                    ]},
                    supports_dry_run=True,
                    required_host_capabilities=("task.coordination",),
                    candidates=(connector,),
                ),
                CapabilityDefinition(
                    f"{application}.selection.read",
                    application,
                    ("read",),
                    "low",
                    idempotency="guaranteed",
                    verification_guarantee="readback",
                    input_schema={"type": "object", "properties": {
                        "taskId": {"type": "string", "minLength": 1},
                        "taskToken": {"type": "string", "minLength": 1}},
                        "additionalProperties": False,
                        "dependentRequired": {"taskId": ["taskToken"], "taskToken": ["taskId"]}},
                    candidates=(connector,),
                ),
                *(
                    [
                        CapabilityDefinition(
                            f"revit.{operation}", "revit", (access,),
                            "low" if access == "read" else "high",
                            input_schema=conduit_input_schema(operation),
                            required_host_capabilities=(operation,),
                            supports_dry_run=access == "write",
                            supports_cancellation=True,
                            idempotency="guaranteed" if access == "read" else "none",
                            transaction_guarantee="host_native" if access == "write" else "none",
                            rollback_guarantee="host_native" if access == "write" else "none",
                            verification_guarantee="readback",
                            candidates=(connector,),
                        )
                        for operation, access in CONDUIT_OPERATIONS.items()
                    ]
                    if application == "revit"
                    else []
                ),
                *(
                    [
                        CapabilityDefinition(
                            "revit.family.session", "revit", ("write",), "high",
                            input_schema={"$ref": "https://bim-bridge.local/protocol/v2/bim-bridge-contract.schema.json#/$defs/familySession"},
                            supports_dry_run=True, required_host_capabilities=("family.session", "task.coordination"),
                            transaction_guarantee="none", rollback_guarantee="none", candidates=(connector,),
                        ),
                        CapabilityDefinition(
                            "revit.view.capture",
                            "revit",
                            ("read",),
                            "low",
                            input_schema={
                                "type": "object",
                                "properties": {
                                    "viewId": {"type": "integer", "minimum": 1},
                                    "taskId": {"type": "string", "minLength": 1},
                                    "taskToken": {"type": "string", "minLength": 1},
                                    "viewUniqueId": {"type": "string"},
                                    "viewName": {"type": "string"},
                                    "fileStem": {"type": "string", "maxLength": 80},
                                    "pixelSize": {
                                        "type": "integer",
                                        "minimum": 256,
                                        "maximum": 4096,
                                        "default": 1600,
                                    },
                                    "dpi": {
                                        "type": "integer",
                                        "enum": [72, 150, 300, 600],
                                        "default": 150,
                                    },
                                    "fitDirection": {
                                        "type": "string",
                                        "enum": ["horizontal", "vertical"],
                                        "default": "horizontal",
                                    },
                                },
                                "additionalProperties": False,
                            },
                            output_schema={
                                "type": "object",
                                "required": ["path", "format", "viewId", "viewName"],
                                "properties": {
                                    "path": {"type": "string"},
                                    "format": {"const": "png"},
                                    "fileSizeBytes": {"type": "integer", "minimum": 1},
                                    "viewId": {"type": "integer"},
                                    "viewUniqueId": {"type": "string"},
                                    "viewName": {"type": "string"},
                                    "pixelSize": {"type": "integer"},
                                    "dpi": {"type": "integer"},
                                    "fitDirection": {"type": "string"},
                                    "capturedAtUtc": {"type": "string"},
                                },
                            },
                            required_host_capabilities=("view.capture",),
                            candidates=(connector,),
                        )
                    ]
                    if application == "revit"
                    else []
                ),
                CapabilityDefinition(
                    f"{application}.code.read",
                    application,
                    ("read",),
                    "critical",
                    candidates=(connector,),
                ),
                CapabilityDefinition(
                    f"{application}.code.write",
                    application,
                    ("write",),
                    "critical",
                    transaction_guarantee="host_native",
                    rollback_guarantee="host_native",
                    candidates=(connector,),
                ),
            ]
        )
    return CapabilityRegistry(definitions)
