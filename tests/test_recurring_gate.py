#!/usr/bin/env python3
"""Execute the mandatory recurring-class contract and mutation gate."""

from __future__ import annotations

import importlib.util
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs/recurring_issues.md"
RUNTIME = ROOT / "tests/runtime_smoke.py"
RESTIC = ROOT / "scripts/container/restic.sh"
CLOUDFLARE = ROOT / "scripts/ci/cloudflare_ranges.py"

RECURRING_GOAL_GATE_CLAUSES = (
    "Every new, resumed, review, optimization, scoring, release, and post-merge round",
    "ten-row evidence matrix",
    "positive, boundary, negative, and mutation-control tests",
    "Run the named mutation control",
    "repair the invariant in the same round",
    "Do not optimize, score, merge, deploy, or claim completion",
    "without creating per-round files",
)

CLASS_EVIDENCE = {
    "Bounded Diagnostics": (
        "scripts/container/restic.sh:trim_logs",
        "tests/runtime_smoke.py:check_post_backup_trim_failure",
    ),
    "Outbound Network Bounds": (
        "scripts/ci/deps.sh:gh_api",
        "tests/test_repository_contracts.py:test_missing_timeout_fails_closed_and_mutation_control_catches_fallback",
    ),
    "One Address Policy": (
        "scripts/container/entrypoint/config.sh:valid_dns_name",
        "tests/test_address_audit.py:test_negative_control_detects_a_disabled_numeric_host_guard",
    ),
    "Restore Isolation": (
        "scripts/container/restic.sh:restore_test",
        "tests/runtime_smoke.py:check_snapshot_argument_boundaries",
    ),
    "State And Process Supervision": (
        "scripts/container/restic.sh:write_status",
        "tests/test_recurring_gate.py:test_state_write_mutation_allows_previous_marker_loss",
    ),
    "Runtime Harness Lifecycle": (
        "tests/runtime_smoke.py:expect_shell",
        "tests/test_recurring_gate.py:test_runtime_lifecycle_mutation_accepts_missing_pass_marker",
    ),
    "Cloudflare Ranges": (
        "scripts/ci/cloudflare_ranges.py:sync_ranges",
        "tests/test_recurring_gate.py:test_cloudflare_truncation_mutation_allows_unsafe_update",
    ),
    "Privacy And Public History": (
        "tests/test_recurring_gate.py:scan_for_sensitive_data",
        "tests/test_recurring_gate.py:test_privacy_mutation_detects_planted_identifier",
    ),
    "Script Boundary": (
        "tests/test_repository_contracts.py:script_boundary_errors",
        "tests/test_repository_contracts.py:test_script_boundary_mutation_detects_ci_copy",
    ),
    "Simplification Rule": (
        "tests/test_recurring_gate.py:assert_recurrence_contract",
        "tests/test_recurring_gate.py:test_contract_mutation_removes_authoritative_field",
    ),
}

SENSITIVE_PATTERNS = (
    ("legacy application prefix", re.compile("xv" + "x-")),
    (
        "provider token",
        re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"),
    ),
    ("bot token", re.compile(r"(?<![0-9])[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}")),
    ("storage identifier", re.compile(r"s3://[a-f0-9]{20,}\.r2\.cloudflarestorage\.com")),
)


def sections(text: str) -> dict[str, str]:
    parts = re.split(r"^## (.+)$", text, flags=re.MULTILINE)
    return dict(zip(parts[1::2], parts[2::2]))


def assert_recurrence_contract(case: unittest.TestCase, text: str) -> None:
    found = sections(text)
    for required in ("Target-Mode Prompt", "Every-Round Goal Gate"):
        case.assertIn(required, found)
    prompt_and_gate = found["Target-Mode Prompt"] + found["Every-Round Goal Gate"]
    for clause in RECURRING_GOAL_GATE_CLAUSES:
        case.assertIn(clause, prompt_and_gate)

    classes = set(found) - {"Target-Mode Prompt", "Every-Round Goal Gate"}
    case.assertEqual(classes, set(CLASS_EVIDENCE))
    for title, (authority, mutation) in CLASS_EVIDENCE.items():
        body = found[title]
        for field in ("History:", "Final decision:", "Authority:", "Mutation control:", "Regression gate:"):
            case.assertIn(field, body, f"{title} is missing {field}")
        case.assertIn(authority, body, f"{title} names the wrong authority")
        case.assertIn(mutation, body, f"{title} names the wrong mutation control")


def extract_shell_function(source: str, name: str) -> str:
    start = source.index(f"{name}() {{")
    end = source.index("\n}\n", start) + 3
    return source[start:end]


def load_mutated_module(path: Path, replacements: tuple[tuple[str, str], ...], root: Path):
    source = path.read_text(encoding="utf-8")
    for old, new in replacements:
        if old not in source:
            raise AssertionError(f"mutation target not found in {path.name}")
        source = source.replace(old, new, 1)
    target = root / path.name
    target.write_text(source, encoding="utf-8")
    spec = importlib.util.spec_from_file_location(f"{path.stem}_mutated_{os.getpid()}", target)
    if spec is None or spec.loader is None:
        raise AssertionError("unable to load mutated module")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def scan_for_sensitive_data(text: str) -> list[str]:
    return [label for label, pattern in SENSITIVE_PATTERNS if pattern.search(text)]


class RecurringContractTest(unittest.TestCase):
    def test_registry_references_existing_evidence(self) -> None:
        for references in CLASS_EVIDENCE.values():
            for reference in references:
                path, symbol = reference.split(":", 1)
                source = (ROOT / path).read_text(encoding="utf-8")
                self.assertRegex(source, rf"\b{re.escape(symbol)}\s*\(", reference)

    def test_contract_mutation_removes_authoritative_field(self) -> None:
        text = DOC.read_text(encoding="utf-8")
        assert_recurrence_contract(self, text)
        with self.assertRaises(AssertionError):
            assert_recurrence_contract(self, text.replace("Mutation control:", "Check:", 1))
        with self.assertRaises(AssertionError):
            assert_recurrence_contract(self, text.replace("Cloudflare Ranges", "Ranges", 1))


class RecurringMutationTest(unittest.TestCase):
    def test_state_write_mutation_allows_previous_marker_loss(self) -> None:
        function = extract_shell_function(RESTIC.read_text(encoding="utf-8"), "write_status")
        guarded = '    if ! [ -d "$STATUS_FILE" ] && printf \'%s\' "$body" > "$tmp" && mv "$tmp" "$STATUS_FILE"; then'
        unguarded = '    if printf \'%s\' "$body" > "$STATUS_FILE"; then'
        self.assertIn(guarded, function)

        with tempfile.TemporaryDirectory(prefix="recurring-state-", dir="/tmp") as temporary:
            root = Path(temporary)
            binary = root / "bin"
            binary.mkdir()
            (binary / "mv").write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            (binary / "mv").chmod(0o755)
            status = root / "status"
            previous = "state=unknown\nupdated_at=0\nlast_success=0\nmessage=previous\n"
            env = os.environ.copy()
            env["PATH"] = f"{binary}:{env['PATH']}"

            for label, body, expected_status in (
                ("guarded", function, 1),
                ("mutated", function.replace(guarded, unguarded, 1), 0),
            ):
                status.write_text(previous, encoding="utf-8")
                result = subprocess.run(
                    [
                        "/bin/bash",
                        "-c",
                        f'{body}\nSTATUS_FILE="$1"\nLAST_SUCCESS=0\nwrite_status ok test',
                        "state-write",
                        str(status),
                    ],
                    env=env, capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, expected_status, f"{label}: {result.stderr}")
                if label == "guarded":
                    self.assertEqual(status.read_text(encoding="utf-8"), previous)
                else:
                    self.assertIn("state=ok", status.read_text(encoding="utf-8"))

    def test_runtime_lifecycle_mutation_accepts_missing_pass_marker(self) -> None:
        source = RUNTIME.read_text(encoding="utf-8")
        replacement = ("            and passed_match\n", "            and True\n")
        self.assertIn(replacement[0], source)
        namespace = {"__name__": "runtime_smoke_mutated", "__file__": str(RUNTIME)}
        exec(compile(source.replace(*replacement), str(RUNTIME), "exec"), namespace)
        suite = mock.Mock()
        namespace["suite"] = suite
        namespace["docker"] = mock.Mock(
            return_value=subprocess.CompletedProcess(
                [], 0, "__runtime_smoke_started__\n__runtime_smoke_ended__=0\n", ""
            )
        )
        with mock.patch("sys.stderr", io.StringIO()):
            namespace["expect_shell"]("image", "true", "accepted", "rejected")
        suite.ok.assert_called_once_with("accepted")
        suite.bad.assert_not_called()

    def test_cloudflare_truncation_mutation_allows_unsafe_update(self) -> None:
        with tempfile.TemporaryDirectory(prefix="recurring-ranges-", dir="/tmp") as temporary:
            root = Path(temporary)
            path = root / "ranges.caddy"
            ipv4_values = [f"1.0.{index}.0/24" for index in range(15)]
            ipv6_values = [f"2400:{0xcb00 + index:04x}::/32" for index in range(11)]
            path.write_text(
                "\n".join(f"client_ip {value}" for value in ipv4_values + ipv6_values) + "\n",
                encoding="utf-8",
            )
            before = path.read_bytes()
            sys.path.insert(0, str(ROOT / "scripts" / "ci"))
            import cloudflare_ranges  # noqa: PLC0415

            with self.assertRaisesRegex(ValueError, "below minimum 10"):
                cloudflare_ranges.sync_ranges(path, "\n".join(ipv4_values[:9]) + "\n", "\n".join(ipv6_values) + "\n")
            self.assertEqual(path.read_bytes(), before)

            mutated = load_mutated_module(
                CLOUDFLARE,
                (("    if len(ipv4) < MIN_IPV4_RANGES:\n", "    if False and len(ipv4) < MIN_IPV4_RANGES:\n"),),
                root,
            )
            result = mutated.sync_ranges(path, "\n".join(ipv4_values[:9]) + "\n", "\n".join(ipv6_values) + "\n")
            self.assertTrue(result.changed)
            self.assertEqual(result.ipv4_count, 9)
            self.assertNotEqual(path.read_bytes(), before)

    def test_privacy_mutation_detects_planted_identifier(self) -> None:
        self.assertEqual(scan_for_sensitive_data("safe documentation value"), [])
        self.assertEqual(scan_for_sensitive_data("xv" + "x-leak"), ["legacy application prefix"])
        history = "\n".join(
            subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=True).stdout
            for command in (
                ["git", "log", "--all", "--format=%B"],
                ["git", "log", "--all", "-p", "--", ".", ":(exclude).github"],
            )
        )
        self.assertEqual(scan_for_sensitive_data(history), [])


if __name__ == "__main__":
    unittest.main()
