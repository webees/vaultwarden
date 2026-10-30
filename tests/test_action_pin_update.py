#!/usr/bin/env python3
"""Tests for the write-capable Dependabot auto-merge gate."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/validate_action_pin_update.py"


def load_module():
    spec = importlib.util.spec_from_file_location("validate_action_pin_update", SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load action pin validator")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


VALIDATOR = load_module()
OLD = "a" * 40
NEW = "b" * 40


def file_entry(
    name: str = ".github/workflows/validate.yml",
    patch: str | None = None,
    status: str = "modified",
):
    return {
        "filename": name,
        "status": status,
        "patch": patch
        if patch is not None
        else f"@@ -10,1 +10,1 @@\n-      - uses: actions/checkout@{OLD} # v4\n+      - uses: actions/checkout@{NEW} # v5",
    }


class ActionPinUpdateTest(unittest.TestCase):
    def test_accepts_same_action_sha_and_comment_update(self) -> None:
        self.assertEqual(VALIDATOR.validate([file_entry()]), [])
        self.assertEqual(
            VALIDATOR.validate([file_entry(".github/actions/expire_tags/action.yml")]),
            [],
        )
        workflow = (ROOT / ".github/workflows/dependency_updates.yml").read_text(encoding="utf-8")
        self.assertIn("ref: ${{ github.event.pull_request.base.sha }}", workflow)
        self.assertIn("scripts/ci/validate_action_pin_update.py", workflow)

    def test_rejects_any_non_pin_change(self) -> None:
        patch = (
            f"@@ -10,2 +10,2 @@\n-      - uses: actions/checkout@{OLD} # v4\n"
            f"+      - uses: actions/checkout@{NEW} # v5\n"
            "-      run: echo unsafe\n+      run: echo changed"
        )
        errors = VALIDATOR.validate([file_entry(patch=patch)])
        self.assertTrue(any("only complete remote Action pin lines" in error for error in errors))

    def test_rejects_action_identity_or_indentation_change(self) -> None:
        patch = (
            f"@@ -10,1 +10,1 @@\n-      - uses: actions/checkout@{OLD} # v4\n"
            f"+        uses: evil/checkout@{NEW} # v5"
        )
        errors = VALIDATOR.validate([file_entry(patch=patch)])
        self.assertTrue(any("identity" in error for error in errors))

    def test_rejects_short_sha_missing_comment_and_local_action(self) -> None:
        for replacement in (
            "uses: actions/checkout@abcdef # v5",
            f"uses: actions/checkout@{NEW}",
            f"uses: ./.github/actions/local@{NEW} # v5",
        ):
            with self.subTest(replacement=replacement):
                patch = (
                    f"@@ -10,1 +10,1 @@\n-      - uses: actions/checkout@{OLD} # v4\n"
                    f"+      - {replacement}"
                )
                self.assertTrue(VALIDATOR.validate([file_entry(patch=patch)]))

    def test_rejects_incomplete_pairs_and_same_sha(self) -> None:
        same = f"@@ -10,1 +10,1 @@\n-      - uses: actions/checkout@{OLD} # v4\n+      - uses: actions/checkout@{OLD} # v4"
        added_only = f"@@ -10,1 +10,1 @@\n+      - uses: actions/checkout@{NEW} # v5"
        moved = (
            f"@@ -10,1 +10,0 @@\n-      - uses: actions/checkout@{OLD} # v4\n"
            f"@@ -20,0 +20,1 @@\n+      - uses: actions/checkout@{NEW} # v5"
        )
        self.assertTrue(VALIDATOR.validate([file_entry(patch=same)]))
        self.assertTrue(VALIDATOR.validate([file_entry(patch=added_only)]))
        self.assertTrue(VALIDATOR.validate([file_entry(patch=moved)]))

    def test_rejects_unapproved_paths_deleted_files_and_missing_patch(self) -> None:
        for entry in (
            file_entry(".github/dependabot.yml"),
            file_entry("scripts/run.sh"),
            file_entry(status="added"),
            {"filename": ".github/workflows/validate.yml", "status": "modified"},
        ):
            with self.subTest(entry=entry):
                self.assertTrue(VALIDATOR.validate([entry]))

    def test_rejects_missing_or_oversized_payload(self) -> None:
        self.assertTrue(VALIDATOR.validate([]))
        self.assertTrue(
            VALIDATOR.validate(
                [
                    {
                        "filename": ".github/workflows/validate.yml",
                        "status": "modified",
                        "patch": "x" * (VALIDATOR.MAX_PATCH_BYTES + 1),
                    }
                ]
            )
        )

    def test_cli_accepts_paginated_api_output_and_rejects_invalid_json(self) -> None:
        env = {**dict(__import__("os").environ), "PYTHONDONTWRITEBYTECODE": "1"}
        valid = subprocess.run(
            [sys.executable, str(SCRIPT)],
            input=json.dumps([[file_entry()]]),
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        self.assertEqual(valid.returncode, 0, valid.stderr)
        invalid = subprocess.run(
            [sys.executable, str(SCRIPT)],
            input="not-json",
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        self.assertEqual(invalid.returncode, 1)


if __name__ == "__main__":
    unittest.main()
