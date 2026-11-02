"""Execution evidence normalization and verification status for BIM Bridge."""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from typing import Any

from .policy import canonical_hash


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def normalize_changes(value: Any) -> dict[str, list[str]]:
    source = value if isinstance(value, dict) else {}
    return {
        name: [str(item) for item in source.get(name, [])] if isinstance(source.get(name, []), list) else []
        for name in ("created", "modified", "deleted")
    }


def verification_result(
    specification: dict[str, Any] | None,
    checks: list[dict[str, Any]] | None = None,
    *,
    strength: str = "none",
) -> dict[str, Any]:
    performed = checks or []
    if not specification:
        status = "not_requested"
    elif not performed:
        status = "inconclusive"
    else:
        status = "passed" if all(item.get("passed") is True for item in performed) else "failed"
    return {
        "strength": strength,
        "status": status,
        "checks": performed,
        "issues": [item for item in performed if item.get("passed") is not True],
        "evidence": {},
    }


class VerificationOrchestrator:
    """Executes declared read-back checks without performing agent reasoning."""

    def verify(self, specification: dict[str, Any] | None, execute_check: Any) -> dict[str, Any]:
        if not specification:
            return verification_result(None)
        declared = specification.get("checks", [])
        if not isinstance(declared, list) or not declared:
            return verification_result(specification)
        performed: list[dict[str, Any]] = []
        evidence: dict[str, Any] = {}
        for item in declared:
            if not isinstance(item, dict):
                performed.append({"id": "invalid", "passed": False, "message": "check must be an object"})
                continue
            check_id = str(item.get("id", "invalid"))
            try:
                actual = execute_check(str(item.get("capabilityId", "")), item.get("arguments", {}))
                expected_present = "expected" in item
                passed = not expected_present or actual == item.get("expected")
                performed.append({"id": check_id, "passed": passed})
                evidence[check_id] = actual
            except Exception as exc:
                performed.append({"id": check_id, "passed": False, "message": str(exc)[:1000]})
        result = verification_result(specification, performed, strength="readback")
        result["evidence"] = evidence
        return result


def normalize_execution_result(
    request: dict[str, Any],
    *,
    provider_id: str,
    host_evidence: dict[str, Any],
    provider_result: dict[str, Any],
    audit_id: str,
    started_at: float | None = None,
    verification: dict[str, Any] | None = None,
) -> dict[str, Any]:
    ended = time.monotonic()
    started = ended if started_at is None else started_at
    native_status = str(provider_result.get("status", "failed"))
    rolled_back = bool(provider_result.get("rolledBack", False))
    if native_status == "succeeded":
        normalized_status = "succeeded"
    elif native_status in {"rejected", "expired", "cancelled"}:
        normalized_status = native_status
    else:
        normalized_status = "failed"
    transaction = {
        "status": "rolled_back" if rolled_back else (
            "committed" if request.get("intent") == "write" and normalized_status == "succeeded" else "not_applicable"
        ),
        "rolledBack": rolled_back,
        "documentLock": "unknown" if request.get("intent") == "write" else "not_applicable",
    }
    if str(request.get("capabilityId", "")).endswith((".task.coordination", ".family.session")):
        # A queue/lease transition (including its dry-run) is not an Autodesk
        # transaction and cannot claim a native commit or document lock.
        transaction = {"status": "not_applicable", "rolledBack": False, "documentLock": "not_applicable"}
    verification_value = verification or verification_result(request.get("verification"))
    if (
        normalized_status == "succeeded"
        and isinstance(request.get("verification"), dict)
        and request["verification"].get("required") is True
        and verification_value.get("status") != "passed"
    ):
        normalized_status = "succeeded_unverified"

    raw_errors = provider_result.get("errors", [])
    errors: list[dict[str, Any]] = []
    if isinstance(raw_errors, list):
        for item in raw_errors:
            if isinstance(item, dict) and all(key in item for key in ("code", "stage", "message", "retryable")):
                errors.append(item)
            else:
                errors.append(
                    {
                        "code": "provider.error",
                        "stage": "execution",
                        "message": str(item)[:4096],
                        "retryable": False,
                    }
                )
    if not errors and normalized_status in {"failed", "rejected", "expired", "cancelled"}:
        message = provider_result.get("message") or provider_result.get("errorType")
        if message:
            errors.append(
                {
                    "code": "provider." + str(provider_result.get("errorType", native_status)).lower(),
                    "stage": "execution",
                    "message": str(message)[:4096],
                    "retryable": False,
                }
            )

    elapsed_seconds = max(0.0, ended - started)
    ended_utc = datetime.now(timezone.utc)
    started_utc = ended_utc - timedelta(seconds=elapsed_seconds)
    return {
        "kind": "execution_result",
        "contractVersion": 2,
        "correlationId": request["correlationId"],
        "status": normalized_status,
        "selected": {"capabilityId": request["capabilityId"], "providerId": provider_id},
        "hostEvidence": host_evidence,
        "transaction": transaction,
        "changes": normalize_changes(provider_result.get("changes")),
        "output": provider_result.get("result", provider_result.get("output")),
        "verification": verification_value,
        "warnings": list(provider_result.get("warnings", [])),
        "errors": errors,
        "timings": {
            "startedAtUtc": started_utc.isoformat().replace("+00:00", "Z"),
            "endedAtUtc": ended_utc.isoformat().replace("+00:00", "Z"),
            "elapsedMilliseconds": int(elapsed_seconds * 1000),
        },
        "audit": {"auditId": audit_id, "requestHash": canonical_hash(request)},
    }
