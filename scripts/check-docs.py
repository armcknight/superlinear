#!/usr/bin/env python3
"""Check the relative links and anchors in the README, CLAUDE.md and docs/.

Each relative link must point to a file that exists, and each fragment to an
anchor in its target: an explicit `<a id="…"></a>`, or a heading's GitHub
slug. Each explicit anchor in docs/ must also be listed in docs/anchors.md,
because other repositories link to them.

Exits 1 and prints each problem when there is one.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
ANCHORS = DOCS / "anchors.md"

FENCE = re.compile(r"^(```|~~~).*?^\1", re.MULTILINE | re.DOTALL)
INLINE_CODE = re.compile(r"`[^`\n]*`")
LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
REFERENCE = re.compile(r"^\s*\[[^\]]+\]:\s*<?(\S+?)>?(?:\s|$)", re.MULTILINE)
HREF = re.compile(r"<a\s[^>]*href=\"([^\"]+)\"")
EXPLICIT_ANCHOR = re.compile(r"<a\s[^>]*(?:id|name)=\"([^\"]+)\"")
HEADING = re.compile(r"^#{1,6}\s+(.+?)\s*#*\s*$", re.MULTILINE)


def strip_code(text):
    """Remove fenced blocks and inline code, which may hold link-like text."""
    return INLINE_CODE.sub("", FENCE.sub("", text))


def slug(heading):
    """GitHub's anchor for a heading."""
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"[^\w\- ]", "", text.lower())
    return text.replace(" ", "-")


def anchors_in(path, cache={}):
    """Every anchor a link can name in a Markdown file."""
    if path not in cache:
        text = FENCE.sub("", path.read_text(encoding="utf-8"))
        found = set(EXPLICIT_ANCHOR.findall(text))
        counts = {}
        for heading in HEADING.findall(text):
            base = slug(heading)
            n = counts.get(base, 0)
            counts[base] = n + 1
            found.add(base if n == 0 else f"{base}-{n}")
        cache[path] = found
    return cache[path]


def links_in(text):
    text = strip_code(text)
    return LINK.findall(text) + REFERENCE.findall(text) + HREF.findall(text)


def check_links(path):
    problems = []
    for target in links_in(path.read_text(encoding="utf-8")):
        if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.IGNORECASE):
            continue  # http:, https:, mailto: and the like
        file_part, _, fragment = target.partition("#")
        resolved = (path.parent / file_part).resolve() if file_part else path
        where = f"{path.relative_to(ROOT)}: {target}"
        if not resolved.exists():
            problems.append(f"{where}: no such file")
        elif fragment:
            if resolved.suffix != ".md":
                problems.append(f"{where}: an anchor in a file that is not Markdown")
            elif fragment not in anchors_in(resolved):
                problems.append(f"{where}: no such anchor")
    return problems


def check_anchor_list():
    """Every explicit anchor in docs/ is listed in docs/anchors.md, once per file."""
    problems = []
    listed = set()
    for target in links_in(ANCHORS.read_text(encoding="utf-8")):
        file_part, _, fragment = target.partition("#")
        if file_part and fragment:
            listed.add(((DOCS / file_part).resolve(), fragment))
    for path in sorted(DOCS.glob("**/*.md")):
        if path == ANCHORS:
            continue
        ids = EXPLICIT_ANCHOR.findall(FENCE.sub("", path.read_text(encoding="utf-8")))
        for anchor in sorted({a for a in ids if ids.count(a) > 1}):
            problems.append(f"{path.relative_to(ROOT)}: anchor {anchor} is defined more than once")
        for anchor in ids:
            if (path.resolve(), anchor) not in listed:
                problems.append(f"{path.relative_to(ROOT)}: anchor {anchor} is not listed in docs/anchors.md")
    return problems


def main():
    files = [ROOT / "README.md", ROOT / "CLAUDE.md", *sorted(DOCS.glob("**/*.md"))]
    problems = []
    for path in files:
        if path.exists():
            problems += check_links(path)
    problems += check_anchor_list()
    for problem in problems:
        print(problem)
    if problems:
        print(f"{len(problems)} broken link(s) or anchor(s)")
        return 1
    print(f"Checked {len(files)} files: every relative link and anchor resolves.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
