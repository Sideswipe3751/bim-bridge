from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "runtime"))
from aec_runtime import coordination as c
from aec_runtime import AuditTrail, BimBridgeRuntime


class CoordinationProjectionTests(unittest.TestCase):
    def setUp(self):
        self.instance = {"instanceId": "revit-2024-100", "processId": 100,
                         "application": "revit", "applicationVersion": "2024",
                         "document": {"title": "test", "id": "doc-1"},
                         "capabilities": ["task.coordination"]}
        self.runtime = Mock()
        self.runtime._plan_connector.return_value = ({"correlationId": "correlation"}, Mock())
        self.credentials = {"instanceId": self.instance["instanceId"], "taskId": "task-1", "token": "secret"}

    def call(self, name, arguments, *, dry_run=False, access="write", info=None, result=None):
        with patch.object(c, "select_instance", return_value=self.instance), patch.object(c, "connector_request") as transport:
            transport.side_effect = [info if info is not None else self.instance, result or {"status": "succeeded", "result": {}}]
            answer = c.invoke(self.runtime, name, arguments, access, dry_run, 30)
            return answer, transport.call_args_list

    def test_all_code_modes_require_write_projection(self):
        self.assertEqual(c.schema("task_step")["access"], "write")
        self.assertTrue(c.schema("task_step")["tool"]["annotations"]["destructiveHint"])
        for mode in ("read", "write"):
            values = {**self.credentials, "documentTitle": "test", "description": "do work", "code": "return 1;", "mode": mode}
            with self.assertRaises(ValueError):
                c.invoke(self.runtime, "task_step", values, "read")

    def test_validation_rejects_unknown_missing_bool_and_out_of_range(self):
        base = {"instanceId": "i", "name": "n", "owner": "o"}
        for extra in ({"unexpected": 1}, {"leaseSeconds": True}, {"leaseSeconds": 9}, {"leaseSeconds": 301}, {"leaseSeconds": 10.0}, {"name": " "}):
            with self.assertRaises(ValueError):
                c.validate("task_submit", {**base, **extra})
        with self.assertRaises(ValueError):
            c.validate("task_poll", {"instanceId": "i"})

    def test_schema_returns_copy(self):
        item = c.schema("task_status")
        item["tool"]["inputSchema"]["properties"].clear()
        self.assertIn("instanceId", c.schema("task_status")["tool"]["inputSchema"]["properties"])

    def test_dry_run_does_not_dispatch(self):
        answer, calls = self.call("task_submit", {"instanceId": self.instance["instanceId"], "name": "cabinet", "owner": "a"}, dry_run=True)
        self.assertFalse(answer["executed"])
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0].args[1:3], ("GET", "/v1/info"))
        self.runtime._plan_connector.assert_called_once()

    def test_fresh_identity_and_capability_fail_closed(self):
        for change in ({"instanceId": "other"}, {"processId": 200}, {"applicationVersion": "2025"}, {"capabilities": []}):
            with self.assertRaises(RuntimeError):
                self.call("task_poll", self.credentials, info={**self.instance, **change})
        self.runtime.execute_code.assert_not_called()

    def test_control_payload_is_exact_and_uses_live_document(self):
        live = {**self.instance, "document": {"title": "new", "id": "doc-2"}}
        _, calls = self.call("task_renew", {**self.credentials, "leaseSeconds": 60}, info=live)
        payload = calls[1].args[3]
        self.assertEqual(payload["operation"], "task.control")
        self.assertEqual(payload["taskControl"], {"action": "renew", "taskId": "task-1", "token": "secret", "leaseSeconds": 60})
        self.assertEqual(payload["target"]["document"]["id"], "doc-2")
        self.assertEqual(payload["target"]["processId"], 100)
        self.assertNotIn("secret", str(self.runtime.audit.record.call_args_list))

    def test_status_is_read_control(self):
        _, calls = self.call("task_status", {"instanceId": self.instance["instanceId"]}, access="read")
        self.assertEqual(calls[1].args[3]["mode"], "read")
        self.assertEqual(calls[1].args[3]["taskControl"], {"action": "status"})

    def test_steps_delegate_through_existing_policy_execution(self):
        values = {**self.credentials, "documentTitle": "test", "documentId": "doc-1", "description": "build", "code": "return 1;", "mode": "write"}
        _, calls = self.call("task_step", values)
        self.assertEqual(len(calls), 1)
        clean, mode = self.runtime.execute_code.call_args.args
        self.assertEqual(mode, "write")
        self.assertEqual(clean["taskToken"], "secret")
        self.assertNotIn("token", clean)
        self.assertEqual(clean["documentTitle"], "test")

    def test_stale_step_document_rejected_without_execution(self):
        values = {**self.credentials, "documentTitle": "old", "description": "build", "code": "return 1;", "mode": "write"}
        with self.assertRaises(RuntimeError):
            self.call("task_step", values)
        self.runtime.execute_code.assert_not_called()

    def test_submit_returns_synchronous_task_and_secret_once(self):
        expected = {"task": {"taskId": "task-1", "status": "active"}, "token": "secret"}
        result, calls = self.call("task_submit", {"instanceId": self.instance["instanceId"], "name": "lamp", "owner": "agent"}, result=expected)
        self.assertEqual(result, expected)
        self.assertEqual(len(calls), 2)

    def test_poll_and_status_return_direct_host_shapes_without_request_polling(self):
        for status in ("queued", "active", "released"):
            expected = {"taskId": "task-1", "status": status}
            result, calls = self.call("task_poll", self.credentials, result=expected)
            self.assertEqual(result, expected)
            self.assertEqual(len(calls), 2)
        expected = {"tasks": [{"taskId": "task-1", "status": "queued"}]}
        result, calls = self.call("task_status", {"instanceId": self.instance["instanceId"]}, access="read", result=expected)
        self.assertEqual(result, expected)
        self.assertEqual(len(calls), 2)

    def test_search_is_bounded_and_unknown_tools_rejected(self):
        self.assertLessEqual(len(c.search("queue", 2)["tools"]), 2)
        with self.assertRaises(ValueError):
            c.schema("arbitrary")


class CoordinationV2Tests(unittest.TestCase):
    def setUp(self):
        self.runtime = BimBridgeRuntime(audit=AuditTrail())
        self.instance = {"instanceId": "revit-2024-100", "processId": 100,
                         "application": "revit", "applicationVersion": "2024",
                         "document": {"title": "test", "id": "doc-1"},
                         "capabilities": ["task.coordination"]}
        self.target = {"instanceId": "revit-2024-100", "processId": 100,
                       "application": "revit", "release": "2024", "apiVariant": "2024",
                       "document": {"title": "test", "id": "doc-1"}}

    def request(self, action="status", intent="read", dry_run=False):
        args = {"action": action}
        if action == "submit":
            args.update(name="lamp", owner="agent")
        if action in {"poll", "renew", "release", "cancel"}:
            args.update(taskId="task-1", token="private-task-token")
        return {"kind": "execution_request", "contractVersion": 2,
                "correlationId": "coordination-test-123456",
                "adapterSession": self.runtime.open_adapter_session("contract-test"),
                "target": self.target, "capabilityId": "revit.task.coordination",
                "arguments": args, "intent": intent, "timeoutSeconds": 30, "dryRun": dry_run}

    def test_v2_dispatches_under_original_policy_and_target(self):
        req = self.request("submit", "write")
        native = {"task": {"taskId": "new-task", "status": "active"}, "token": "private-task-token"}
        with patch("aec_runtime.service.select_exact_target", return_value=self.instance), patch.object(c, "connector_request", side_effect=[self.instance, native]) as transport, patch.object(self.runtime, "_plan_connector") as legacy_policy:
            result = self.runtime.execute(req)
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["output"], native)
        self.assertEqual(result["transaction"], {"status": "not_applicable", "rolledBack": False, "documentLock": "not_applicable"})
        self.assertEqual(transport.call_args.args[3]["target"], self.target)
        self.assertEqual(transport.call_args.args[3]["taskControl"], req["arguments"])
        legacy_policy.assert_not_called()
        self.assertNotIn("private-task-token", str(self.runtime.audit.records()))

    def test_v2_dry_run_never_posts(self):
        req = self.request("submit", "write", True)
        with patch("aec_runtime.service.select_exact_target", return_value=self.instance), patch.object(c, "connector_request") as transport:
            result = self.runtime.execute(req)
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["output"], {"dryRun": True, "executed": False, "action": "submit"})
        self.assertEqual(result["transaction"]["status"], "not_applicable")
        transport.assert_not_called()

    def test_rejected_target_and_policy_never_dispatch(self):
        req = self.request()
        with patch("aec_runtime.service.select_exact_target", side_effect=RuntimeError("target changed")), patch.object(c, "connector_request") as transport:
            self.assertEqual(self.runtime.execute(req)["status"], "rejected")
            transport.assert_not_called()
        req["adapterSession"]["sessionToken"] = "forged"
        with patch("aec_runtime.service.select_exact_target", return_value=self.instance), patch.object(c, "connector_request") as transport:
            self.assertEqual(self.runtime.execute(req)["status"], "rejected")
            transport.assert_not_called()

    def test_action_intent_and_unknown_fields_rejected_before_dispatch(self):
        for action, intent, extra in (("status", "write", {}), ("submit", "read", {}), ("status", "read", {"token": "secret"}), ("submit", "write", {"owner": "x" * 201})):
            req = self.request(action, intent)
            req["arguments"].update(extra)
            with patch("aec_runtime.service.select_exact_target", return_value=self.instance), patch.object(c, "connector_request") as transport:
                self.assertEqual(self.runtime.execute(req)["status"], "rejected")
                transport.assert_not_called()

    def test_capability_schemas_reuse_unified_contract_definitions(self):
        cap = self.runtime.capabilities.get("revit.task.coordination")
        self.assertTrue(cap.input_schema["$ref"].endswith("#/$defs/taskControl"))
        self.assertTrue(any(row.get("$ref", "").endswith("#/$defs/taskSubmission") for row in cap.output_schema["oneOf"]))

    def test_ordinary_write_normalization_still_reports_commit(self):
        from aec_runtime import normalize_execution_result
        req = self.request("submit", "write")
        req["capabilityId"] = "revit.code.write"
        result = normalize_execution_result(req, provider_id="revit.connector.v1", host_evidence=self.target,
                                            provider_result={"status": "succeeded", "result": {}}, audit_id="audit-test-1234567890")
        self.assertEqual(result["transaction"]["status"], "committed")


class CoordinationCaptureTests(unittest.TestCase):
    def test_v2_capture_and_selection_forward_owner_outside_operation_arguments(self):
        instance = {"application": "revit"}
        for capability in ("revit.view.capture", "revit.selection.read"):
            request = {"capabilityId": capability, "arguments": {"viewId": 52, "taskId": "task", "taskToken": "secret"}, "intent": "read"}
            with patch("aec_runtime.service.execute_connector_operation", return_value={"status": "succeeded", "result": []}) as execute:
                result = BimBridgeRuntime._execute_host_capability(instance, request)
            self.assertEqual(result["status"], "succeeded")
            self.assertEqual(execute.call_args.kwargs, {"task_id": "task", "task_token": "secret"})
            self.assertNotIn("taskToken", execute.call_args.args[2])

    def test_task_selection_verification_uses_structured_owned_readback(self):
        with patch("aec_runtime.service.execute_connector_operation", return_value={"status": "succeeded", "result": [42]}) as execute:
            result = BimBridgeRuntime._execute_verification_check({"application": "revit"}, "revit.selection.read", {"taskId": "task", "taskToken": "secret"})
        self.assertEqual(result, [42])
        self.assertEqual(execute.call_args.args[1], "selection.read")
        self.assertEqual(execute.call_args.kwargs, {"task_id": "task", "task_token": "secret"})

    def test_capture_keeps_credentials_outside_view_options_and_redacts_journal(self):
        runtime = BimBridgeRuntime(audit=AuditTrail())
        instance = {"instanceId": "test", "application": "revit", "applicationVersion": "2024",
                    "processId": 1, "document": {"id": "doc", "title": "test"},
                    "capabilities": ["view.capture", "task.coordination"]}
        with patch("aec_runtime.service.select_instance", return_value=instance), patch("aec_runtime.service.execute_connector_operation", return_value={"status": "succeeded", "result": {"path": "capture.png"}}) as execute:
            result = runtime.invoke_provider("revit.connector.v1", "capture_view",
                       {"instanceId": "test", "viewId": 52, "taskId": "owner-task", "taskToken": "private-token"}, "read", False, 30)
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(execute.call_args.kwargs, {"task_id": "owner-task", "task_token": "private-token"})
        self.assertNotIn("taskToken", execute.call_args.args[2])
        self.assertNotIn("private-token", str(runtime.audit.records()))

    def test_incomplete_capture_credentials_fail_before_dispatch(self):
        runtime = BimBridgeRuntime(audit=AuditTrail())
        with patch("aec_runtime.service.execute_connector_operation") as execute:
            for values in ({"taskId": "id"}, {"taskToken": "secret"}, {"taskId": "id", "taskToken": " "}):
                with self.assertRaises(RuntimeError):
                    runtime.invoke_provider("revit.connector.v1", "capture_view", values, "read", False, 30)
            execute.assert_not_called()

    def test_application_global_provider_refused_before_execution_on_coordinated_host(self):
        runtime = BimBridgeRuntime(audit=AuditTrail())
        runtime.providers = Mock()
        runtime.providers.schema.return_value = {"access": "write"}
        with patch.object(runtime, "_provider_target", return_value=("revit", {"application": "revit", "release": "2024"})), patch("aec_runtime.service.load_instances", return_value=([{"application": "revit", "capabilities": ["task.coordination"]}], [])):
            with self.assertRaisesRegex(RuntimeError, "cannot participate"):
                runtime.invoke_provider("external", "write", {}, "write", False, 30)
        runtime.providers.invoke.assert_not_called()


if __name__ == "__main__":
    unittest.main()
