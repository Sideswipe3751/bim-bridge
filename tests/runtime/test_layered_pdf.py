from __future__ import annotations
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "runtime"))
from aec_runtime import BimBridgeRuntime, AuditTrail, PolicyEngine
from aec_runtime import layered_pdf
from aec_runtime.hosts import execute_connector_operation


class LayeredPdfTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.runtime = BimBridgeRuntime(policy=PolicyEngine(),
                                        audit=AuditTrail())
        self.instance = {"application": "revit", "applicationVersion": "2024", "instanceId": "revit-2024-7",
                         "processId": 7, "document": {"id": "path:c:/test.rvt", "title": "test"},
                         "capabilities": ["layered_pdf.catalog", "layered_pdf.export"]}
        self.args = {"instanceId": "revit-2024-7", "documentTitle": "test", "baseSheetId": 1, "sheetIds": [2, 3]}

    def test_discovery_and_modes(self):
        found = self.runtime.search_provider_tools("layered pdf", layered_pdf.PROVIDER_ID, 10)
        self.assertEqual(len(found["tools"]), 2)
        self.assertEqual(self.runtime.provider_schema(layered_pdf.PROVIDER_ID, "export_layered_pdf")["access"], "write")
        with patch.object(layered_pdf, "load_instances", return_value=([self.instance], [])):
            self.assertEqual(layered_pdf.descriptor(True)["status"], "ready")
        with self.assertRaises(ValueError):
            self.runtime.invoke_provider(layered_pdf.PROVIDER_ID, "export_layered_pdf", self.args, "read", False, 300)

    def test_preview_never_dispatches_or_writes(self):
        with patch.object(layered_pdf, "select_instance", return_value=self.instance), \
             patch.object(layered_pdf, "execute_connector_operation") as execute:
            result = self.runtime.invoke_provider(layered_pdf.PROVIDER_ID, "export_layered_pdf", self.args, "write", True, 300)
            self.assertEqual(result["status"], "previewed")
            self.assertFalse(result["result"]["result"]["nativeValidation"])
            execute.assert_not_called()

    def test_validation_rejects_invalid_or_ambient_inputs(self):
        for field in ({"sheetIds": []}, {"sheetIds": [1, 1]}, {"sheetIds": [True]}, {"sheetIds": [0]},
                      {"sheetIds": [2**63]}, {"sheetIds": list(range(1, 102))}, {"baseSheetId": True},
                      {"fileStem": "../test"}, {"fileStem": "NUL"}, {"fileStem": "x" * 81},
                      {"outputPath": "C:/secret.pdf"}, {"createBoxLayers": 1}, {"setupName": " "},
                      {"taskId": "orphan"}):
            with self.subTest(field=field), self.assertRaises(ValueError):
                layered_pdf.validate("layered_pdf.export", {"baseSheetId": 1, "sheetIds": [2], **field})

    def test_dispatch_binds_target_and_task_and_propagates_failure(self):
        args = {**self.args, "taskId": "task", "taskToken": "sensitive"}
        with patch.object(layered_pdf, "select_instance", return_value=self.instance), \
             patch.object(layered_pdf, "execute_connector_operation", return_value={"status": "failed", "rolledBack": True}) as execute:
            result = self.runtime.invoke_provider(layered_pdf.PROVIDER_ID, "export_layered_pdf", args, "write", False, 300)
            self.assertEqual(result["status"], "failed")
            execute.assert_called_once_with(self.instance, "layered_pdf.export", {"baseSheetId": 1, "sheetIds": [2, 3]},
                                            "write", 300, task_id="task", task_token="sensitive")

    def test_http_envelope_carries_options_and_exact_target(self):
        with patch("aec_runtime.hosts.connector_request", return_value={"status": "succeeded"}) as send:
            execute_connector_operation(self.instance, "layered_pdf.export", {"baseSheetId": 1, "sheetIds": [2]}, "write", 300)
            payload = send.call_args.args[3]
            self.assertEqual(payload["layeredPdf"], {"baseSheetId": 1, "sheetIds": [2]})
            self.assertEqual(payload["target"]["document"]["id"], "path:c:/test.rvt")

    def test_v2_binding_and_validation(self):
        request = {"kind": "execution_request", "contractVersion": 2, "correlationId": "layered-pdf-test",
                   "adapterSession": self.runtime.open_adapter_session("contract-test"),
                   "target": {"application": "revit", "release": "2024", "instanceId": "revit-2024-7",
                              "processId": 7, "document": self.instance["document"]},
                   "capabilityId": "revit.layered_pdf.export", "arguments": {"baseSheetId": 1, "sheetIds": [2]},
                   "intent": "write", "dryRun": True, "timeoutSeconds": 300}
        plan, _ = self.runtime.prepare(request, host_capabilities=self.instance["capabilities"])
        self.assertTrue(plan.capability.supports_dry_run)
        with patch.object(layered_pdf, "execute_connector_operation") as send:
            result = self.runtime._execute_host_capability(self.instance, request)
            self.assertFalse(result["result"]["executed"])
            send.assert_not_called()
        request["arguments"]["sheetIds"] = []
        with self.assertRaises(ValueError):
            self.runtime.prepare(request, host_capabilities=self.instance["capabilities"])


if __name__ == "__main__":
    unittest.main()
