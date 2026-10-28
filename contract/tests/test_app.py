"""Tests of contract/app.py: python3 -m unittest discover -s contract/tests"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app import describe, string_list  # noqa: E402
from test_check import ECS_APP, repo  # noqa: E402


class StringList(unittest.TestCase):
    def test_lists_across_lines_with_comments(self):
        text = 'regions = [\n  "us-east-1", # primary\n  "sa-east-1",\n]\nhosts = []\n'
        self.assertEqual(string_list(text, "regions"), ["us-east-1", "sa-east-1"])
        self.assertEqual(string_list(text, "hosts"), [])
        self.assertIsNone(string_list(text, "zones"))


class Describe(unittest.TestCase):
    def test_an_ecs_app_with_data_and_smoke_tests(self):
        app = repo({
            "deploy/app.hcl": ECS_APP,
            "deploy/env/production.tfvars": 'regions = ["us-east-1", "sa-east-1"] # comment\nhosts = ["vendas.example.com"]\n',
            "deploy/data.hcl": 'tables = { vendas = { hash_key = "id" } }\n',
            "tests/smoke/vendas.hurl": "GET {{host}}/health\n",
        })
        self.assertEqual(describe(app, "production"), {
            "runtime": "ecs",
            "name": "svc-vendas",
            "regions": ["us-east-1", "sa-east-1"],
            "hosts": ["vendas.example.com"],
            "source_dir": "site",
            "data": True,
            "smoke": ["tests/smoke/vendas.hurl"],
        })

    def test_runner_defaults_when_the_app_lists_nothing(self):
        app = repo({
            "deploy/app.hcl": 'runtime = "cloudfront"\nname = "web-loja"\nsource_dir = "dist"\n',
            "deploy/env/production.tfvars": "\n",
        })
        d = describe(app, "production")
        self.assertEqual((d["regions"], d["hosts"], d["source_dir"], d["data"], d["smoke"]),
                         (["us-east-1"], [], "dist", False, []))

    def test_an_account_without_tfvars_is_refused(self):
        app = repo({"deploy/app.hcl": ECS_APP, "deploy/env/production.tfvars": "\n"})
        with self.assertRaisesRegex(SystemExit, "does not run in staging"):
            describe(app, "staging")


if __name__ == "__main__":
    unittest.main()
