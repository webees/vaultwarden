#!/usr/bin/env python3
"""Validate a Dependabot PR contains only remote action pin updates."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys
from typing import Any, Sequence

ALLOWED_PATHS = (
    re.compile(r"^\.github/workflows/[^/]+\.ya?ml$"),
    re.compile(r"^\.github/actions/[^/]+/action\.ya?ml$"),
)
REMOTE_ACTION = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$")
USES_LINE = re.compile(
    r"^(?P<marker>[+-])(?P<indent>\s*(?:-\s+)?)uses:\s*"
    r"(?P<action>[^@\s#]+)@(?P<sha>[0-9a-f]{40})"
    r"\s+#\s+(?P<comment>\S.*?)\s*$"
)
MAX_PATCH_BYTES = 128 * 1024
MAX_REPORTED_ERRORS = 20


def _load_files(stream: Any) -> list[dict[str, Any]]:
    payload = json.load(stream)
    if not isinstance(payload, list):
        raise ValueError("GitHub API output must be a JSON array")
    if payload and all(isinstance(page, list) for page in payload):
        files = [item for page in payload for item in page]
    else:
        files = payload
    if not files or not all(isinstance(item, dict) for item in files):
        raise ValueError("pull request must contain at least one file entry")
    return files


def _uses_change(line: str) -> tuple[str, str, str, str, str] | None:
    match = USES_LINE.fullmatch(line)
    if not match:
        return None
    action = match.group("action")
    if not REMOTE_ACTION.fullmatch(action):
        return None
    return match.group("marker"), match.group("indent"), action, match.group("sha"), match.group("comment")


def validate(files: Sequence[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    if not files:
        return ["pull request has no changed files"]

    for item in files:
        name = item.get("filename")
        if not isinstance(name, str) or not any(pattern.fullmatch(name) for pattern in ALLOWED_PATHS):
            errors.append(f"unexpected path: {name!r}")
            continue
        if item.get("status") != "modified":
            errors.append(f"{name}: only modified files are allowed")
            continue
        patch = item.get("patch")
        if not isinstance(patch, str) or not patch:
            errors.append(f"{name}: GitHub did not return a reviewable patch")
            continue
        if len(patch.encode("utf-8")) > MAX_PATCH_BYTES:
            errors.append(f"{name}: patch exceeds {MAX_PATCH_BYTES} bytes")
            continue

        hunks: list[tuple[list[tuple[str, str, str, str, str]], list[tuple[str, str, str, str, str]]]] = []
        current: tuple[list[tuple[str, str, str, str, str]], list[tuple[str, str, str, str, str]]] | None = None
        for line in patch.splitlines():
            if line.startswith("@@"):
                current = ([], [])
                hunks.append(current)
                continue
            if line.startswith("\\"):
                continue
            if line.startswith(" "):
                continue
            if not line.startswith(("+", "-")):
                errors.append(f"{name}: patch contains unexpected content")
                continue
            if current is None:
                errors.append(f"{name}: changed line is outside a diff hunk")
                continue
            change = _uses_change(line)
            if change is None:
                errors.append(f"{name}: only complete remote Action pin lines may change")
                continue
            (current[0] if change[0] == "-" else current[1]).append(change[1:])

        if not hunks:
            errors.append(f"{name}: patch has no diff hunks")
            continue
        for removed, added in hunks:
            if not removed or len(removed) != len(added):
                errors.append(f"{name}: Action pin removals and additions must be paired within each hunk")
                continue
            for old, new in zip(removed, added):
                old_indent, old_action, old_sha, _ = old
                new_indent, new_action, new_sha, _ = new
                if old_indent != new_indent or old_action != new_action:
                    errors.append(f"{name}: an update may not change indentation or Action identity")
                if old_sha == new_sha:
                    errors.append(f"{name}: Action pin did not change")

    return errors


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args:
        print(f"usage: {Path(sys.argv[0]).name} < pages.json", file=sys.stderr)
        return 2
    try:
        files = _load_files(sys.stdin)
        errors = validate(files)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        print(f"action pin update: {exc}", file=sys.stderr)
        return 1
    if errors:
        for error in errors[:MAX_REPORTED_ERRORS]:
            print(f"action pin update: {error}", file=sys.stderr)
        remaining = len(errors) - MAX_REPORTED_ERRORS
        if remaining > 0:
            print(f"action pin update: {remaining} additional error(s) omitted", file=sys.stderr)
        return 1
    print(f"validated {len(files)} Action pin update file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
