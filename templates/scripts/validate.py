#!/usr/bin/env python3
"""Validate every component in this repository.

Usage: validate.py [--root DIR] [--anchors PATH_OR_URL]

For each components/<name>/component.toml, checks it against
schema/component.schema.json, then checks what a schema cannot:

* the name is the component's directory name;
* input names, secret names and step IDs are unique;
* CLAUDE.md and scaffold/README.md exist, and the README has the generated
  section's markers, one time each and in order;
* each {{placeholder}} in the scaffold, the steps and the human texts names a
  declared input, `templates` or `templates.tag`;
* each regular expression compiles, and each `regex` infer rule has a group;
* each shared path exists;
* each docs anchor is listed in the superlinear guide's docs/anchors.md;
* README.md links to each component and each shared path.

Prints each problem and exits 1 when there are any.
"""

import argparse
import json
import re
import sys
import tomllib
import urllib.request
from pathlib import Path

import jsonschema

DEFAULT_ANCHORS = "https://raw.githubusercontent.com/armcknight/superlinear/main/docs/anchors.md"

BEGIN_MARKER = "<!-- superlinear:begin how-this-is-built -->"
END_MARKER = "<!-- superlinear:end -->"

# {{name}}, but not GitHub Actions' ${{ expression }}.
PLACEHOLDER = re.compile(r"(?<!\$)\{\{\s*([^{}]*?)\s*\}\}")
BUILTIN_PLACEHOLDERS = {"templates", "templates.tag"}


# How docs/anchors.md lists each anchor: `<page>.md#<id>`, in code.
LISTED_ANCHOR = re.compile(r"`([a-z][a-z0-9-]*\.md#[a-z0-9][a-z0-9-]*)`")


def read_anchors(source):
    if re.match(r"^https?://", source):
        with urllib.request.urlopen(source, timeout=30) as response:
            text = response.read().decode("utf-8")
    else:
        text = Path(source).read_text(encoding="utf-8")
    return set(LISTED_ANCHOR.findall(text))


def placeholders(text):
    return {m.group(1) for m in PLACEHOLDER.finditer(text)}


def human_texts(manifest):
    for secret in manifest.get("secrets", []):
        if "human" in secret:
            yield f"secret {secret['name']}", secret["human"]["text"]
    for step in manifest.get("steps", []):
        fix = step["fix"]
        if isinstance(fix, dict):
            yield f"step {step['id']} fix", fix["human"]["text"]


def duplicates(values):
    seen, repeated = set(), []
    for value in values:
        if value in seen and value not in repeated:
            repeated.append(value)
        seen.add(value)
    return repeated


def check_regex(problems, where, pattern, needs_group=False):
    try:
        compiled = re.compile(pattern)
    except re.error as error:
        problems.append(f"{where}: invalid regular expression {pattern!r}: {error}")
        return
    if needs_group and compiled.groups < 1:
        problems.append(f"{where}: {pattern!r} has no capture group")


def validate_component(root, directory, validator, anchors):
    """The component's problems, and its manifest when it matches the schema."""
    problems = []
    manifest_path = directory / "component.toml"
    where = manifest_path.relative_to(root)

    try:
        manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as error:
        return [f"{where}: {error}"], None

    schema_errors = sorted(validator.iter_errors(manifest), key=lambda e: list(e.absolute_path))
    for error in schema_errors:
        path = "/".join(str(p) for p in error.absolute_path) or "(root)"
        problems.append(f"{where}: {path}: {error.message}")
    if schema_errors:
        return problems, None

    if manifest["name"] != directory.name:
        problems.append(f"{where}: name {manifest['name']!r} is not the directory's name {directory.name!r}")

    for kind, values in (
        ("input", [i["name"] for i in manifest["inputs"]]),
        ("secret", [s["name"] for s in manifest["secrets"]]),
        ("step", [s["id"] for s in manifest["steps"]]),
    ):
        for value in duplicates(values):
            problems.append(f"{where}: {kind} {value!r} is declared more than one time")

    for group in ("all", "any"):
        for index, rule in enumerate(manifest["detect"].get(group, [])):
            if "contains" in rule:
                check_regex(problems, f"{where}: detect.{group}[{index}]", rule["contains"])
    for item in manifest["inputs"]:
        for index, rule in enumerate(item.get("infer", [])):
            if rule["from"] == "regex":
                check_regex(problems, f"{where}: input {item['name']} infer[{index}]", rule["pattern"], needs_group=True)

    if not (directory / "CLAUDE.md").is_file():
        problems.append(f"{where.parent}: CLAUDE.md is missing")

    scaffold = directory / "scaffold"
    readme = scaffold / "README.md"
    if not readme.is_file():
        problems.append(f"{where.parent}: scaffold/README.md is missing")
    else:
        text = readme.read_text(encoding="utf-8")
        begins, ends = text.count(BEGIN_MARKER), text.count(END_MARKER)
        if begins != 1 or ends != 1 or text.index(BEGIN_MARKER) > text.index(END_MARKER):
            problems.append(f"{readme.relative_to(root)}: needs {BEGIN_MARKER} and then {END_MARKER}, one time each")

    allowed = BUILTIN_PLACEHOLDERS | {f"inputs.{i['name']}" for i in manifest["inputs"]}
    sources = []
    if scaffold.is_dir():
        for path in sorted(p for p in scaffold.rglob("*") if p.is_file()):
            try:
                sources.append((str(path.relative_to(root)), path.read_text(encoding="utf-8")))
            except UnicodeDecodeError:
                continue
    for step in manifest["steps"]:
        sources.append((f"{where}: step {step['id']} check", step["check"]))
        if isinstance(step["fix"], str):
            sources.append((f"{where}: step {step['id']} fix", step["fix"]))
    sources.extend((f"{where}: {label}", text) for label, text in human_texts(manifest))
    for label, text in sources:
        for name in sorted(placeholders(text) - allowed):
            problems.append(f"{label}: unknown placeholder {{{{{name}}}}}")

    for item in manifest["shared"]:
        if not (root / item["path"]).exists():
            problems.append(f"{where}: shared path {item['path']!r} does not exist")

    if anchors is not None:
        for doc in manifest["docs"]:
            if doc["anchor"] not in anchors:
                problems.append(f"{where}: docs anchor {doc['anchor']!r} is not listed in docs/anchors.md")

    return problems, manifest


def validate(root, anchors):
    schema = json.loads((root / "schema" / "component.schema.json").read_text(encoding="utf-8"))
    jsonschema.Draft202012Validator.check_schema(schema)
    validator = jsonschema.Draft202012Validator(schema)

    problems = []
    manifests = {}
    directories = sorted(p for p in (root / "components").iterdir() if p.is_dir())
    if not directories:
        problems.append("components/: there are no components")
    for directory in directories:
        if not (directory / "component.toml").is_file():
            problems.append(f"{directory.relative_to(root)}: component.toml is missing")
            continue
        component_problems, manifest = validate_component(root, directory, validator, anchors)
        problems.extend(component_problems)
        if manifest is not None:
            manifests[directory.name] = manifest

    readme = root / "README.md"
    if not readme.is_file():
        problems.append("README.md is missing")
    else:
        links = set(re.findall(r"\]\(([^)\s]+)\)", readme.read_text(encoding="utf-8")))
        links = {link.removeprefix("./").rstrip("/") for link in links}
        for name, manifest in manifests.items():
            if f"components/{name}" not in links:
                problems.append(f"README.md: does not link to components/{name}")
            for item in manifest["shared"]:
                if item["path"] not in links:
                    problems.append(f"README.md: does not link to the shared {item['kind']} {item['path']}")

    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument(
        "--anchors",
        default=DEFAULT_ANCHORS,
        help="docs/anchors.md from the superlinear repository, as a path or a URL. 'none' skips the anchor check.",
    )
    arguments = parser.parse_args(argv)

    anchors = None if arguments.anchors == "none" else read_anchors(arguments.anchors)
    problems = validate(arguments.root.resolve(), anchors)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        print(f"{len(problems)} problem(s).", file=sys.stderr)
        return 1
    print("All components are valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
