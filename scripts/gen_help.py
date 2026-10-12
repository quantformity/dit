#!/usr/bin/env python3
"""Regenerate internal/cli/help_text.go from the Swift source of truth.

The Swift binary is the oracle for the help screens; its source is
HelpText.swift. This script extracts every multi-line string body — `case`
bodies and the `default:` body — verbatim (Swift strips the 8-space closing-
delimiter indent and `\\` is a single backslash), and emits Go raw strings.

Do NOT hand-edit help_text.go: if HelpText.swift changes, run this and diff.
"""
import os
import re
import sys
from pathlib import Path

# The Swift reference checkout is intentionally external to this Go project.
# Set DIT_SWIFT_HELP_SOURCE when regenerating after an upstream help change.
SRC = Path(os.environ.get(
    "DIT_SWIFT_HELP_SOURCE",
    "/Users/chup/workspaces/dit/Sources/dit/HelpText.swift",
))
OUT = Path(__file__).resolve().parent.parent / "internal" / "cli" / "help_text.go"

BLOCK_RE = re.compile(
    r'(?:case \((.*?)\)|default):\s*\n\s*return """\n(.*?)\n\s*"""', re.S
)

# (group, sub) → 1-based helpBody index, in the Swift switch's order. A sub of
# None means "any subcommand" (the `_` patterns); the fallback is the last body.
TABLE = [
    ("summary", "", 2),
    ("accounts", "", 3),
    ("account", None, 3),
    ("account", "list", 3),
    ("account", "show", 4),
    ("account", "add", 5),
    ("account", "edit", 6),
    ("account", "close", 7),
    ("account", "delete", 8),
    ("tx", "ANY", 9),
    ("transaction", "ANY", 9),
    ("ticker", "ANY", 10),
    ("store", "ANY", 11),
    ("export", "ANY", 12),
    ("import", "ANY", 12),
    ("market", "ANY", 13),
    ("quote", "ANY", 14),
    ("pnl", "ANY", 15),
]


def main() -> int:
    if not SRC.is_file():
        print(f"Swift help source not found: {SRC}; set DIT_SWIFT_HELP_SOURCE", file=sys.stderr)
        return 1
    src = SRC.read_text()
    blocks = []
    for m in BLOCK_RE.finditer(src):
        body = "\n".join(ln[8:] for ln in m.group(2).split("\n"))
        body = body.replace("\\\\", "\\")
        blocks.append(body)

    assert len(blocks) == 16, f"expected 16 help blocks in {SRC}, saw {len(blocks)} — HelpText.swift changed"
    assert not any("`" in b for b in blocks), "a backtick entered a help body; switch to interpreted Go strings"

    names = [f"helpBody{i}" for i in range(1, len(blocks) + 1)]
    out = [
        "package cli",
        "",
        "// Help screens, transcribed byte-for-byte from",
        "// /Users/chup/workspaces/dit/Sources/dit/HelpText.swift (all `case`",
        "// bodies plus the `default:` body — the main-screen text appears there",
        '// twice with different line-wrapping, and both variants are preserved).',
        "// Regenerate with scripts/gen_help.py; do not edit these strings by hand.",
        "",
    ]
    for body, name in zip(blocks, names):
        out.append(f"const {name} = `{body}`")
        out.append("")
    out += [
        "// helpTextFor answers (group, sub) exactly like the Swift helpText(for:)",
        "// switch: same keys, same order, and anything unknown falls through to",
        f"// the Swift default body ({names[-1]}), never to an error.",
        "func helpTextFor(group, sub string) string {",
    ]
    for group, sub, index in TABLE:
        name = names[index - 1]
        if sub == "ANY":
            out.append(f'\tif group == "{group}" {{ return {name} }}')
        elif sub is None:
            out.append(f'\tif group == "{group}" && sub == "" {{ return {name} }}')
        else:
            out.append(f'\tif group == "{group}" && sub == "{sub}" {{ return {name} }}')
    out.append(f"\treturn {names[-1]}")
    out.append("}")
    OUT.write_text("\n".join(out) + "\n")
    print(f"wrote {OUT} ({len(blocks)} bodies)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
