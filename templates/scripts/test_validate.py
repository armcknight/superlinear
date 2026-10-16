"""Tests for validate.py. Run with `python3 -m unittest discover -s scripts`."""

import shutil
import tempfile
import textwrap
import unittest
from pathlib import Path

import validate

ROOT = Path(__file__).resolve().parent.parent

MANIFEST = """\
name = "demo"
description = "A demonstration component."

[detect]
all = [{ glob = "fly.toml" }]
any = [{ glob = "Package.swift", contains = "vapor" }]

[[inputs]]
name = "app"
description = "The Fly app."
example = "demo-api"
infer = [{ from = "toml", file = "fly.toml", key = "app" }]

[[inputs]]
name = "region"
description = "The primary region."
example = "sjc"
infer = [{ from = "regex", glob = "fly.toml", pattern = "primary_region = \\"([a-z]+)\\"" }]

[[secrets]]
name = "FLY_API_TOKEN"
description = "A deploy token."
source = "keychain:demo.fly-token"
scope = "app"
human = { text = "Make a deploy token for {{inputs.app}}.", twoFactor = true }
rotateEvery = "90d"

[[steps]]
id = "app-exists"
description = "The Fly app exists."
check = "fly status --app {{inputs.app}}"
fix = "fly apps create {{inputs.app}}"

[[steps]]
id = "domain"
description = "The domain points at the app."
check = "{{templates}}/components/demo/bin/check-domain"
fix = { human = { text = "Point the domain at {{inputs.app}}." } }

[[shared]]
kind = "workflow"
path = ".github/workflows/demo.yml"
version = "v1"
description = "Deploys the app."

[[docs]]
title = "Builds"
anchor = "builds"
"""

README = """\
# templates

* [demo](components/demo/)
* [the workflow](.github/workflows/demo.yml)
"""

SCAFFOLD_README = """\
# {{inputs.app}}

<!-- superlinear:begin how-this-is-built -->
<!-- superlinear:end -->
"""

WORKFLOW = """\
jobs:
  deploy:
    uses: armcknight/templates/.github/workflows/demo.yml@{{templates.tag}}
    with:
      force: ${{ github.event_name == 'workflow_dispatch' }}
"""


class ValidateTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "schema").mkdir()
        shutil.copy(ROOT / "schema" / "component.schema.json", self.root / "schema")
        self.write(".github/workflows/demo.yml", "on: workflow_call\n")
        self.write("README.md", README)
        self.write("components/demo/component.toml", MANIFEST)
        self.write("components/demo/CLAUDE.md", "# demo\n")
        self.write("components/demo/scaffold/README.md", SCAFFOLD_README)
        self.write("components/demo/scaffold/.github/workflows/deploy.yml", WORKFLOW)
        self.anchors = {"builds", "bootstrap"}

    def write(self, path, text):
        path = self.root / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def edit_manifest(self, old, new):
        path = self.root / "components/demo/component.toml"
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new), encoding="utf-8")

    def problems(self):
        return validate.validate(self.root, self.anchors)

    def assertProblem(self, fragment):
        problems = self.problems()
        self.assertTrue(any(fragment in p for p in problems), f"no problem with {fragment!r} in {problems}")

    def test_valid_component(self):
        self.assertEqual(self.problems(), [])

    def test_this_repository_is_valid(self):
        self.assertEqual(validate.validate(ROOT, None), [])

    def test_schema_error_names_the_field(self):
        self.edit_manifest('source = "keychain:demo.fly-token"', 'source = "vault:demo"')
        self.assertProblem("secrets/0/source")

    def test_unknown_field(self):
        self.edit_manifest('description = "A demonstration component."', 'description = "A demonstration component."\ncolor = "red"')
        self.assertProblem("'color' was unexpected")

    def test_infer_rule_fields_depend_on_from(self):
        self.edit_manifest('{ from = "toml", file = "fly.toml", key = "app" }', '{ from = "build-setting", file = "fly.toml", key = "app" }')
        self.assertProblem("inputs/0/infer/0")

    def test_name_must_match_directory(self):
        self.edit_manifest('name = "demo"', 'name = "other"')
        self.assertProblem("is not the directory's name")

    def test_duplicate_step(self):
        self.edit_manifest('id = "domain"', 'id = "app-exists"')
        self.assertProblem("step 'app-exists' is declared more than one time")

    def test_regex_infer_needs_a_group(self):
        self.edit_manifest('pattern = "primary_region = \\"([a-z]+)\\""', 'pattern = "primary_region"')
        self.assertProblem("has no capture group")

    def test_invalid_detect_regex(self):
        self.edit_manifest('contains = "vapor"', 'contains = "vapor("')
        self.assertProblem("invalid regular expression")

    def test_unknown_placeholder_in_scaffold(self):
        self.write("components/demo/scaffold/README.md", SCAFFOLD_README.replace("inputs.app", "inputs.name"))
        self.assertProblem("scaffold/README.md: unknown placeholder {{inputs.name}}")

    def test_unknown_placeholder_in_human_text(self):
        self.edit_manifest("Point the domain at {{inputs.app}}.", "Point {{inputs.domain}} at the app.")
        self.assertProblem("step domain fix: unknown placeholder {{inputs.domain}}")

    def test_github_expressions_are_not_placeholders(self):
        self.assertEqual(validate.placeholders("${{ github.sha }} {{templates.tag}}"), {"templates.tag"})

    def test_scaffold_readme_needs_markers(self):
        self.write("components/demo/scaffold/README.md", "# {{inputs.app}}\n<!-- superlinear:end -->\n")
        self.assertProblem("one time each")

    def test_markers_in_order(self):
        self.write(
            "components/demo/scaffold/README.md",
            "<!-- superlinear:end -->\n<!-- superlinear:begin how-this-is-built -->\n",
        )
        self.assertProblem("one time each")

    def test_missing_claude_md(self):
        (self.root / "components/demo/CLAUDE.md").unlink()
        self.assertProblem("CLAUDE.md is missing")

    def test_missing_shared_path(self):
        (self.root / ".github/workflows/demo.yml").unlink()
        self.assertProblem("shared path '.github/workflows/demo.yml' does not exist")

    def test_unknown_anchor(self):
        self.anchors = {"bootstrap"}
        self.assertProblem("docs anchor 'builds'")

    def test_anchor_check_can_be_skipped(self):
        self.anchors = None
        self.assertEqual(self.problems(), [])

    def test_readme_links_each_component_and_shared_piece(self):
        self.write("README.md", "# templates\n")
        self.assertProblem("does not link to components/demo")
        self.assertProblem("does not link to the shared workflow .github/workflows/demo.yml")

    def test_anchors_are_github_heading_slugs(self):
        path = self.root / "anchors.md"
        path.write_text(textwrap.dedent("""\
            # Anchors
            ## apple-app
            ## Builds and Releases ##
            """), encoding="utf-8")
        self.assertEqual(validate.read_anchors(str(path)), {"anchors", "apple-app", "builds-and-releases"})


if __name__ == "__main__":
    unittest.main()
