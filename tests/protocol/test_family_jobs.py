"""Resident job arguments remain values in the single versioned contract."""
import unittest
from test_task_coordination import SCHEMA, validate


class FamilyJobContractTests(unittest.TestCase):
    def session(self):
        return dict(action="begin", jobId="cab01", documentName="BB_IVAR",
                    templatePath="C:/Templates/Furniture.rft", taskId="task", taskToken="secret")

    def check(self, name, value):
        validate(value, {"$ref": "#/$defs/" + name})

    def test_actions_and_required_begin_template(self):
        for action in ("begin", "prepare_view", "save_close", "abort"):
            item = {**self.session(), "action": action}
            if action != "begin":
                item.pop("templatePath")
            self.check("familySession", item)
        item = self.session(); item.pop("templatePath")
        with self.assertRaises(ValueError):
            self.check("familySession", item)
        with self.assertRaises(ValueError):
            self.check("familySession", {**self.session(), "action": "abort"})

    def test_rejects_scope_and_credential_errors(self):
        for change in ({"action": "delete"}, {"jobId": "../user"}, {"documentName": "x.rfa"},
                       {"taskToken": ""}, {"outputPath": "C:/user.rfa"}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.check("familySession", {**self.session(), **change})
        for key in ("taskId", "taskToken", "jobId", "documentName"):
            item = self.session(); item.pop(key)
            with self.assertRaises(ValueError): self.check("familySession", item)

    def test_job_package_dimensions_and_code(self):
        job = dict(jobId="cab01", documentName="BB_IVAR", templatePath="C:/Furniture.rft",
                   buildCode="return 1;", verifyCode="return true;", source={"url": "official"},
                   expectedDimensions=dict(widthMm=800, depthMm=300, heightMm=830))
        self.check("familyJobPackage", job)
        for change in ({"buildCode": ""}, {"unexpected": True},
                       {"expectedDimensions": dict(widthMm=0, depthMm=300, heightMm=830)},
                       {"expectedDimensions": dict(widthMm=800, depthMm=True, heightMm=830)}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.check("familyJobPackage", {**job, **change})

    def test_contract_surface_and_token_redaction_metadata(self):
        self.assertEqual(len(SCHEMA["oneOf"]), 5)
        self.assertTrue(SCHEMA["$defs"]["familySession"]["properties"]["taskToken"]["x-sensitive"])
        self.assertEqual(SCHEMA["$defs"]["executionRequest"]["properties"]["arguments"], {"type": "object"})


if __name__ == "__main__": unittest.main()
