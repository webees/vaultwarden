#!/usr/bin/env python3
"""Tests for the automatic Cloudflare edge-range update."""

from __future__ import annotations

import ipaddress
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import cloudflare_ranges  # noqa: E402


def ipv4(value: int, prefix: int = 24) -> str:
    return str(ipaddress.ip_network((value, prefix), strict=True))


def ipv6(value: int, prefix: int = 32) -> str:
    return str(ipaddress.ip_network((value, prefix), strict=True))


def write_ranges(path: Path, ipv4_ranges: list[str], ipv6_ranges: list[str]) -> None:
    body = "# test ranges\n" + "\n".join(
        f"client_ip {value}" for value in ipv4_ranges + ipv6_ranges
    )
    path.write_text(body + "\n", encoding="utf-8")


class CloudflareRangeSyncTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / "cloudflare_ips.caddy"
        self.v4_a = ipv4(0x0A000000)
        self.v4_b = ipv4(0xC0000200)
        self.v6_a = ipv6(0x20010DB8 << 96)
        self.v6_b = ipv6(0x20010DB9 << 96)

    def test_unchanged_ranges_leave_the_file_untouched(self) -> None:
        write_ranges(self.path, [self.v4_a], [self.v6_a])
        before = self.path.stat()

        result = cloudflare_ranges.sync_ranges(
            self.path, self.v4_a + "\n", self.v6_a + "\n"
        )

        after = self.path.stat()
        self.assertFalse(result.changed)
        self.assertEqual(result.range_count, 2)
        self.assertEqual(result.added_count, 0)
        self.assertEqual(result.removed_count, 0)
        self.assertEqual(before.st_ino, after.st_ino)

    def test_changed_ranges_replace_the_file_atomically(self) -> None:
        write_ranges(self.path, [self.v4_a], [self.v6_a])
        self.path.chmod(0o640)

        result = cloudflare_ranges.sync_ranges(
            self.path,
            f"{self.v4_a}\n{self.v4_b}\n",
            f"{self.v6_a}\n{self.v6_b}\n",
        )

        rendered = self.path.read_text(encoding="utf-8")
        self.assertTrue(result.changed)
        self.assertEqual((result.ipv4_count, result.ipv6_count), (2, 2))
        self.assertEqual((result.added_count, result.removed_count), (2, 0))
        self.assertEqual(
            stat.S_IMODE(self.path.stat().st_mode), stat.S_IMODE(0o640)
        )
        self.assertTrue(rendered.startswith("# test ranges\n"))
        for value in (self.v4_a, self.v4_b, self.v6_a, self.v6_b):
            self.assertIn(f"client_ip {value}\n", rendered)
        self.assertEqual(list(self.root.glob(".*.tmp")), [])

    def test_removed_ranges_are_reported(self) -> None:
        write_ranges(self.path, [self.v4_a, self.v4_b], [self.v6_a])

        result = cloudflare_ranges.sync_ranges(
            self.path, self.v4_a + "\n", self.v6_a + "\n"
        )

        self.assertTrue(result.changed)
        self.assertEqual(result.added_count, 0)
        self.assertEqual(result.removed_count, 1)
        self.assertNotIn(self.v4_b, self.path.read_text(encoding="utf-8"))

    def test_invalid_upstream_lists_fail_closed(self) -> None:
        write_ranges(self.path, [self.v4_a], [self.v6_a])
        cases = (
            ("malformed", "not-a-network", self.v6_a, "invalid CIDR"),
            ("wrong version", self.v6_a, self.v6_a, "expected IPv4"),
            (
                "duplicate",
                f"{self.v4_a}\n{self.v4_a}\n",
                self.v6_a,
                "duplicate range",
            ),
            ("empty", "", self.v6_a, "no ranges returned"),
        )
        for label, ipv4_text, ipv6_text, message in cases:
            with self.subTest(label=label), self.assertRaisesRegex(ValueError, message):
                cloudflare_ranges.sync_ranges(self.path, ipv4_text, ipv6_text)

    def test_unexpected_trailing_content_is_not_deleted(self) -> None:
        self.path.write_text(
            f"# test ranges\nclient_ip {self.v4_a}\nclient_ip {self.v6_a}\ninvalid\n",
            encoding="utf-8",
        )
        before = self.path.read_bytes()

        with self.assertRaisesRegex(ValueError, "unexpected content"):
            cloudflare_ranges.sync_ranges(self.path, self.v4_a, self.v6_a)

        self.assertEqual(self.path.read_bytes(), before)

    def test_cli_writes_action_outputs(self) -> None:
        write_ranges(self.path, [self.v4_a], [self.v6_a])
        output = self.root / "github-output"
        responses = {
            "https://v4.invalid": f"{self.v4_a}\n{self.v4_b}\n",
            "https://v6.invalid": self.v6_a + "\n",
        }

        with mock.patch.object(
            cloudflare_ranges, "_fetch_text", side_effect=responses.__getitem__
        ):
            status = cloudflare_ranges.main(
                [
                    "sync",
                    "--file",
                    str(self.path),
                    "--ipv4-url",
                    "https://v4.invalid",
                    "--ipv6-url",
                    "https://v6.invalid",
                    "--github-output",
                    str(output),
                ]
            )

        self.assertEqual(status, 0)
        self.assertIn("changed=true\n", output.read_text(encoding="utf-8"))
        self.assertIn("range_count=3\n", output.read_text(encoding="utf-8"))

    def test_failed_fetch_leaves_the_file_untouched(self) -> None:
        write_ranges(self.path, [self.v4_a], [self.v6_a])
        before = self.path.read_bytes()

        with mock.patch.object(
            cloudflare_ranges, "_fetch_text", side_effect=OSError("offline")
        ):
            status = cloudflare_ranges.main(["sync", "--file", str(self.path)])

        self.assertEqual(status, 1)
        self.assertEqual(self.path.read_bytes(), before)


def load_workflow() -> dict[str, object]:
    ruby = """
      require "json"
      require "yaml"
      print JSON.generate(YAML.load_file(ARGV.fetch(0)))
    """
    result = subprocess.run(
        ["ruby", "-e", ruby, ".github/workflows/dependency_updates.yml"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr.strip() or "could not parse workflow")
    return json.loads(result.stdout)


class DependencyWorkflowTest(unittest.TestCase):
    def test_cloudflare_changes_use_the_guarded_dependency_pr_path(self) -> None:
        workflow = load_workflow()
        jobs = workflow.get("jobs")
        self.assertIsInstance(jobs, dict)
        steps = jobs["check"]["steps"]
        self.assertIsInstance(steps, list)

        cloudflare = next(
            (step for step in steps if step.get("id") == "cloudflare"), None
        )
        self.assertIsNotNone(cloudflare)
        self.assertIn(
            "python3 scripts/cloudflare_ranges.py sync",
            str(cloudflare.get("run", "")),
        )

        changed = next(step for step in steps if step.get("id") == "changed")
        changed_run = str(changed.get("run", ""))
        self.assertIn("steps.compare.outputs.changed", changed_run)
        self.assertIn("steps.cloudflare.outputs.changed", changed_run)

        pull_request = next(step for step in steps if step.get("id") == "pr")
        self.assertIn(
            "steps.changed.outputs.changed == 'true'",
            str(pull_request.get("if", "")),
        )
        pull_request_run = str(pull_request.get("run", ""))
        self.assertIn("git add Dockerfile config/cloudflare_ips.caddy", pull_request_run)

        published_apk = next(
            step for step in steps if step.get("id") == "published-apk"
        )
        self.assertIn(
            "steps.changed.outputs.changed != 'true'",
            str(published_apk.get("if", "")),
        )

        deploy = next(
            step
            for step in steps
            if "Build and deploy after the merge" in str(step.get("name", ""))
        )
        self.assertIn(
            "steps.changed.outputs.changed == 'true'", str(deploy.get("if", ""))
        )


if __name__ == "__main__":
    unittest.main()
