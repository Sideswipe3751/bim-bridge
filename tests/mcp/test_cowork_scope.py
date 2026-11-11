import hashlib
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "adapters" / "cowork"))
from streamable_http import DocumentUnavailable, McpHandler, TOOL, read_document


class CoworkScopeTests(unittest.TestCase):
    def setUp(self):
        self.runtime = Mock()
        self.instance_id = "revit-fixture"
        self.document = {"id": "unsaved:test"}
        self.digest = hashlib.sha256(self.document["id"].encode()).hexdigest()
        self.units = {
            "length": "autodesk.unit.unit:millimeters-1.0.1",
            "area": "autodesk.unit.unit:squareMeters-1.0.1",
            "volume": "autodesk.unit.unit:cubicMeters-1.0.1",
            "angle": "autodesk.unit.unit:degrees-1.0.1",
        }
        self.snapshot = {
            "document": self.document,
            "documentUnits": self.units,
            "instanceId": self.instance_id,
            "application": "revit",
            "applicationVersion": "2024",
        }
        self.runtime.document_info.return_value = self.snapshot

    def test_descriptor_mismatch_skips_connector_read(self):
        with patch("streamable_http.select_instance", return_value={"document": {"id": "other"}}):
            with self.assertRaises(DocumentUnavailable):
                read_document(self.runtime, self.instance_id, self.digest)
        self.runtime.document_info.assert_not_called()

    def test_snapshot_mismatch_and_old_connector_fail_closed(self):
        with patch("streamable_http.select_instance", return_value=self.snapshot):
            for override in ({"document": {"id": "other"}}, {"documentUnits": None}):
                self.runtime.document_info.return_value = {**self.snapshot, **override}
                with self.assertRaises(DocumentUnavailable):
                    read_document(self.runtime, self.instance_id, self.digest)

    def test_projected_result_contains_only_version_and_units(self):
        with patch("streamable_http.select_instance", return_value=self.snapshot):
            result = read_document(self.runtime, self.instance_id, self.digest)
        self.assertEqual(result, {"applicationVersion": "2024", "documentUnits": self.units})
        self.runtime.document_info.assert_called_once_with({
            "application": "revit", "instanceId": self.instance_id,
        })

    def test_unknown_tool_and_caller_supplied_document_are_rejected(self):
        handler = object.__new__(McpHandler)
        handler.server = Mock()
        for params in ({"name": "aec_execute_read"},
                       {"name": TOOL["name"], "arguments": {"documentId": "other"}}):
            self.assertEqual(handler.dispatch("tools/call", params)["error"]["code"], -32602)
        handler.server.read_document.assert_not_called()
