"""Tests of contract/check.py: python3 -m unittest discover -s contract/tests"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check import check, top_level  # noqa: E402

ECS_APP = '''runtime = "ecs"
name    = "svc-vendas"
port    = 8080

# a comment with = signs
env = {
  LOG_LEVEL = "info" # nested: never a field
}

slo = {
  availability   = 99.5
  latency_p95_ms = 300
}
'''


def repo(files):
    root = Path(tempfile.mkdtemp())
    for rel, text in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return root


class TopLevel(unittest.TestCase):
    def test_only_top_level_keys_with_string_values(self):
        keys = top_level(ECS_APP)
        self.assertEqual(list(keys), ["runtime", "name", "port", "env", "slo"])
        self.assertEqual(keys["name"], "svc-vendas")
        self.assertIsNone(keys["port"])

    def test_strings_comments_and_heredocs_hide_nothing(self):
        text = 'a = "x = 1 # not a comment"\n/* b = 1 */\nc = <<EOT\nd = 2\nEOT\ne = ["f = 3"]\n'
        self.assertEqual(list(top_level(text)), ["a", "c", "e"])


class Contract(unittest.TestCase):
    def test_a_valid_app_passes(self):
        app = repo({
            "deploy/app.hcl": ECS_APP,
            "deploy/env/production.tfvars": 'regions = ["us-east-1"]\ncpu = 256\nmemory = 512\nmin_capacity = 2\nmax_capacity = 4\n',
            "deploy/data.hcl": 'tables = { vendas = { hash_key = "id" } }\nshares = { "table/vendas" = { "svc-x" = "read" } }\n',
        })
        self.assertEqual(check(app, "svc-vendas"), [])

    def test_platform_values_are_refused(self):
        app = repo({"deploy/app.hcl": ECS_APP + 'zone = "evil.com"\n', "deploy/data.hcl": "allow_destroy = true\n"})
        errors = check(app, "svc-vendas")
        self.assertTrue(any("zone is set by the platform" in e for e in errors))
        self.assertTrue(any("allow_destroy is set by the platform" in e for e in errors))

    def test_typos_and_renamed_fields_are_explained(self):
        app = repo({"deploy/app.hcl": ECS_APP, "deploy/env/staging.tfvars": "cpus = 4\nfora_do_horario = true\n"})
        errors = check(app, "svc-vendas")
        self.assertTrue(any("cpus is not part of the ecs contract" in e for e in errors))
        self.assertTrue(any("fora_do_horario was renamed to off_hours" in e for e in errors))

    def test_name_must_be_the_repo_name(self):
        errors = check(repo({"deploy/app.hcl": ECS_APP}), "svc-outra")
        self.assertTrue(any("must be the repo name" in e for e in errors))

    def test_a_site_has_no_data(self):
        site = repo({
            "deploy/app.hcl": 'runtime = "cloudfront"\nname = "web-loja"\nsource_dir = "dist"\nspa = true\n',
            "deploy/data.hcl": "tables = {}\n",
        })
        self.assertTrue(any("deploy/data.hcl: not part of the cloudfront contract" in e for e in check(site, "web-loja")))

    def test_unknown_runtime_and_missing_app_file(self):
        self.assertIn("has no runner", check(repo({"deploy/app.hcl": 'runtime = "lambda"\nname = "func-x"\n'}), "func-x")[0])
        self.assertIn("not found", check(repo({"README.md": "x"}), "svc-x")[0])


if __name__ == "__main__":
    unittest.main()
