#!/usr/bin/env python3
"""Static checks for the C3DTools AutoLISP sources.

Runs anywhere Python 3 runs (no AutoCAD needed). It cannot prove the code
works in Civil 3D; it catches the mistakes that are easy to make by hand:

  1. Unbalanced parentheses or unterminated strings, per file.
  2. Any top-level defun or global setq that is not prefixed (c3dt:,
     c3dguard:, c3daudit:, c3dimpact: or a C: command with a C3D prefix).
  3. Leftover development notes or third-party references.

Exit code 0 when clean, 1 otherwise.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = sorted((ROOT / "src").glob("*.lsp")) + sorted((ROOT / "C3DTools.bundle" / "Contents").glob("*.lsp"))

PREFIXES = ("c3dt:", "c3dguard:", "c3daudit:", "c3dimpact:")
COMMAND_PREFIXES = ("c:c3dtools-", "c:c3dguard-", "c:c3daudit", "c:c3d-impact-")
GLOBAL_PREFIXES = tuple("*" + p for p in PREFIXES)

BANNED = [
    r"confirmed live", r"onedrive", r"\bhdr\b", r"power ?bi", r"dashboard",
    r"civil3dtools", r"c:\\\\civil3dtools", r"tell me", r"chat messages",
    r"dropgeom",
]


def strip(src: str, path: pathlib.Path, errors: list) -> str:
    """Return src with comments and string bodies blanked, checking balance."""
    out, depth, i, line = [], 0, 0, 1
    while i < len(src):
        ch = src[i]
        if ch == "\n":
            line += 1
        if ch == ";":
            while i < len(src) and src[i] != "\n":
                i += 1
            continue
        if ch == '"':
            start = line
            i += 1
            while i < len(src) and src[i] != '"':
                if src[i] == "\\":
                    i += 1
                if i < len(src) and src[i] == "\n":
                    line += 1
                i += 1
            if i >= len(src):
                errors.append(f"{path.name}:{start}: unterminated string")
            out.append('""')
            i += 1
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth < 0:
                errors.append(f"{path.name}:{line}: unexpected ')'")
                depth = 0
        out.append(ch)
        i += 1
    if depth:
        errors.append(f"{path.name}: {depth} unclosed '('")
    return "".join(out)


def top_level_forms(code: str):
    depth, start = 0, None
    for i, ch in enumerate(code):
        if ch == "(":
            if depth == 0:
                start = i
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0 and start is not None:
                yield code[start : i + 1]


def check_names(code: str, path: pathlib.Path, errors: list):
    for m in re.finditer(r"\(defun\s+([^\s()]+)", code):
        name = m.group(1).lower()
        if not (name.startswith(PREFIXES) or name.startswith(COMMAND_PREFIXES)):
            errors.append(f"{path.name}: unprefixed function '{m.group(1)}'")
    for form in top_level_forms(code):
        for m in re.finditer(r"\(setq\s+([^\s()]+)", form[:200]):
            name = m.group(1).lower()
            if form.lstrip("(").startswith("defun"):
                break
            if not name.startswith(GLOBAL_PREFIXES):
                errors.append(f"{path.name}: unprefixed global '{m.group(1)}'")


def main() -> int:
    errors: list = []
    for path in FILES:
        src = path.read_text(encoding="utf-8")
        code = strip(src, path, errors)
        check_names(code, path, errors)
        for pat in BANNED:
            for m in re.finditer(pat, src, re.IGNORECASE):
                ln = src.count("\n", 0, m.start()) + 1
                errors.append(f"{path.name}:{ln}: banned text '{m.group(0)}'")
    for e in errors:
        print(e)
    print(f"checked {len(FILES)} files, {len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
