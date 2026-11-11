"""Dependency-free focused validation of task definitions in the unified schema.

The repository's protocol tests use stdlib validators. This focused interpreter
consumes the actual schema's local refs, alternatives, object rules and scalar
constraints; it intentionally is not a production JSON Schema implementation.
"""
from __future__ import annotations

import json
import math
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = json.loads((ROOT / "protocol/v2/aec-contract.schema.json").read_text(encoding="utf-8"))


def validate(value, rule):
    if "not" in rule:
        try:
            validate(value, rule["not"])
        except ValueError:
            pass
        else:
            raise ValueError("negated schema matched")
    for child in rule.get("allOf", []):
        validate(value, child)
    if "if" in rule:
        try:
            validate(value, rule["if"])
        except ValueError:
            branch = rule.get("else", {})
        else:
            branch = rule.get("then", {})
        validate(value, branch)
    if "$ref" in rule:
        name = rule["$ref"].removeprefix("#/$defs/")
        if not rule["$ref"].startswith("#/$defs/"):
            raise AssertionError("Only local contract refs are expected")
        validate(value, SCHEMA["$defs"][name])
    if "oneOf" in rule:
        matches = 0
        for branch in rule["oneOf"]:
            try:
                validate(value, branch)
                matches += 1
            except ValueError:
                pass
        if matches != 1:
            raise ValueError("Expected exactly one schema alternative")
    if "const" in rule and value != rule["const"]:
        raise ValueError("const mismatch")
    if "enum" in rule and value not in rule["enum"]:
        raise ValueError("enum mismatch")
    types = rule.get("type", [])
    types = [types] if isinstance(types, str) else types
    predicates = {"object": lambda v: isinstance(v, dict), "string": lambda v: isinstance(v, str),
                  "integer": lambda v: type(v) is int,
                  "number": lambda v: type(v) in (int, float) and math.isfinite(v), "null": lambda v: v is None,
                  "array": lambda v: isinstance(v, list)}
    if types and not any(predicates[t](value) for t in types):
        raise ValueError("type mismatch")
    if isinstance(value, dict):
        if set(rule.get("required", [])) - set(value):
            raise ValueError("required field missing")
        properties = rule.get("properties", {})
        if rule.get("additionalProperties") is False and set(value) - set(properties):
            raise ValueError("unexpected property")
        for key, child in value.items():
            if key in properties:
                validate(child, properties[key])
    if isinstance(value, str):
        if not rule.get("minLength", 0) <= len(value) <= rule.get("maxLength", math.inf):
            raise ValueError("string length")
        if "pattern" in rule and re.search(rule["pattern"], value) is None:
            raise ValueError("string pattern")
    if type(value) in (int, float):
        if "exclusiveMinimum" in rule and value <= rule["exclusiveMinimum"]:
            raise ValueError("exclusive numeric minimum")
        if not rule.get("minimum", -math.inf) <= value <= rule.get("maximum", math.inf):
            raise ValueError("numeric range")
    if isinstance(value, list):
        if len(value) > rule.get("maxItems", math.inf):
            raise ValueError("array length")
        for item in value:
            validate(item, rule.get("items", {}))


class TaskCoordinationContractTests(unittest.TestCase):
    def snapshot(self, state="active"):
        return {"taskId": "a" * 32, "name": "LAUTERS", "owner": "lamp-agent", "status": state,
                "queuePosition": 0, "leaseRemainingSeconds": 119.9, "inFlightRequestId": None}

    def check(self, name, value):
        validate(value, {"$ref": "#/$defs/" + name})

    def test_all_actions_and_default_leases(self):
        self.check("taskControl", {"action": "status"})
        self.check("taskControl", {"action": "submit", "name": "lamp", "owner": "agent"})
        for action in ("poll", "release", "cancel", "renew"):
            self.check("taskControl", {"action": action, "taskId": "a" * 32, "token": "secret"})
        self.check("taskControl", {"action": "renew", "taskId": "a", "token": "secret", "leaseSeconds": 300})

    def test_control_rejects_unknown_fields_wrong_credentials_and_types(self):
        examples = [{"action": "unknown"}, {"action": "status", "token": "secret"},
                    {"action": "poll", "taskId": "a"}, {"action": "poll", "taskId": "a", "token": None},
                    {"action": "submit", "name": " ", "owner": "a"},
                    {"action": "submit", "name": "x" * 201, "owner": "a"}]
        for lease in (9, 301, True, 10.5, "120"):
            examples.append({"action": "submit", "name": "n", "owner": "o", "leaseSeconds": lease})
        for example in examples:
            with self.subTest(example=example), self.assertRaises(ValueError):
                self.check("taskControl", example)

    def test_every_host_state_and_in_flight_evidence(self):
        for state in ("queued", "active", "draining", "completed", "expired", "cancelled"):
            snapshot = self.snapshot(state)
            if state == "draining":
                snapshot["inFlightRequestId"] = "request-1"
                snapshot["leaseRemainingSeconds"] = 0
            self.check("taskSnapshot", snapshot)

    def test_public_snapshots_cannot_leak_tokens_or_accept_unknown_states(self):
        for change in ({"token": "secret"}, {"taskToken": "secret"}, {"status": "succeeded"},
                       {"queuePosition": -1}, {"queuePosition": True}, {"leaseRemainingSeconds": -0.1}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.check("taskSnapshot", {**self.snapshot(), **change})

    def test_submission_requires_sensitive_token_and_reuses_snapshot(self):
        self.check("taskSubmission", {"task": self.snapshot(), "token": "secret"})
        with self.assertRaises(ValueError):
            self.check("taskSubmission", {"task": self.snapshot()})
        props = SCHEMA["$defs"]["taskSubmission"]["properties"]
        self.assertEqual(props["task"]["$ref"], "#/$defs/taskSnapshot")
        self.assertTrue(props["token"]["x-sensitive"])

    def test_public_status_reuses_token_free_snapshots(self):
        self.check("taskStatus", {"tasks": [self.snapshot("queued")]})
        self.check("taskStatus", {"tasks": []})
        holder = {**self.snapshot("draining"), "documentTitle": "Model A"}
        waiting = {**self.snapshot("queued"), "taskId": "waiting", "documentTitle": "Model B", "queuePosition": 1}
        self.check("taskStatus", {"currentTaskId": holder["taskId"], "tasks": [holder, waiting]})
        self.check("taskStatus", {"currentTaskId": None, "tasks": []})
        with self.assertRaises(ValueError):
            self.check("taskStatus", {"tasks": [{**self.snapshot(), "token": "secret"}]})

    def test_task_defs_are_embedded_domain_values_not_new_transport_envelopes(self):
        request = json.loads((ROOT / "protocol/v2/examples/read-request.json").read_text(encoding="utf-8"))
        request["capabilityId"] = "revit.task.coordination"
        request["arguments"] = {"action": "status"}
        self.check("taskControl", request["arguments"])
        self.assertEqual(SCHEMA["$defs"]["executionRequest"]["properties"]["arguments"], {"type": "object"})
        self.assertNotIn({"$ref": "#/$defs/taskControl"}, SCHEMA["oneOf"])

    def test_new_definitions_are_additive_to_existing_contract(self):
        self.assertEqual(SCHEMA["$defs"]["executionRequest"]["properties"]["contractVersion"], {"const": 2})
        self.assertEqual(len(SCHEMA["oneOf"]), 5)
        for name in ("taskControl", "taskSnapshot", "taskSubmission"):
            self.assertIn(name, SCHEMA["$defs"])


if __name__ == "__main__":
    unittest.main()
