#!/usr/bin/env python3
"""Tests for the automatic Cloudflare edge-range update."""

from __future__ import annotations

import io
import ipaddress
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock
from urllib.error import HTTPError


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "ci"))

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
        self.v4_a = ipv4(0x01000000)
        self.v4_b = ipv4(0x02000000)
        self.ipv4_ranges = [
            ipv4(0x01000000 + index * 0x100)
            for index in range(cloudflare_ranges.MIN_IPV4_RANGES + 5)
        ]
        self.ipv6_ranges = [
            ipv6((0x2400CB00 + index) << 96)
            for index in range(cloudflare_ranges.MIN_IPV6_RANGES + 2)
        ]
        self.extra_ipv6_ranges = [
            ipv6((0x2400CB00 + len(self.ipv6_ranges) + index) << 96)
            for index in range(4)
        ]
        self.v6_a = self.ipv6_ranges[0]
        self.v6_b = self.extra_ipv6_ranges[0]

    def test_unchanged_ranges_leave_the_file_untouched(self) -> None:
        write_ranges(self.path, self.ipv4_ranges, self.ipv6_ranges)
        before = self.path.stat()

        result = cloudflare_ranges.sync_ranges(
            self.path,
            "\n".join(self.ipv4_ranges) + "\n",
            "\n".join(self.ipv6_ranges) + "\n",
        )

        after = self.path.stat()
        self.assertFalse(result.changed)
        self.assertEqual(
            result.range_count, len(self.ipv4_ranges) + len(self.ipv6_ranges)
        )
        self.assertEqual(result.added_count, 0)
        self.assertEqual(result.removed_count, 0)
        self.assertEqual(before.st_ino, after.st_ino)

    def test_changed_ranges_replace_the_file_atomically(self) -> None:
        write_ranges(self.path, self.ipv4_ranges, self.ipv6_ranges)
        self.path.chmod(0o640)

        result = cloudflare_ranges.sync_ranges(
            self.path,
            "\n".join([*self.ipv4_ranges, self.v4_b]) + "\n",
            "\n".join([*self.ipv6_ranges, self.v6_b]) + "\n",
        )

        rendered = self.path.read_text(encoding="utf-8")
        self.assertTrue(result.changed)
        self.assertEqual(
            (result.ipv4_count, result.ipv6_count),
            (len(self.ipv4_ranges) + 1, len(self.ipv6_ranges) + 1),
        )
        self.assertEqual((result.added_count, result.removed_count), (2, 0))
        self.assertEqual(
            stat.S_IMODE(self.path.stat().st_mode), stat.S_IMODE(0o640)
        )
        self.assertTrue(rendered.startswith("# test ranges\n"))
        for value in (self.v4_a, self.v4_b, self.v6_a, self.v6_b):
            self.assertIn(f"client_ip {value}\n", rendered)
        self.assertEqual(list(self.root.glob(".*.tmp")), [])

    def test_atomic_replace_syncs_the_file_and_parent_directory(self) -> None:
        self.path.write_text("original\n", encoding="utf-8")

        with mock.patch.object(cloudflare_ranges.os, "fsync", wraps=cloudflare_ranges.os.fsync) as sync:
            cloudflare_ranges._atomic_write(self.path, "replacement\n")

        self.assertEqual(sync.call_count, 2)
        self.assertEqual(self.path.read_text(encoding="utf-8"), "replacement\n")

    def test_directory_sync_failure_is_not_silenced(self) -> None:
        self.path.write_text("original\n", encoding="utf-8")

        with mock.patch.object(
            cloudflare_ranges.os, "fsync", side_effect=[None, OSError("directory sync failed")]
        ):
            with self.assertRaisesRegex(OSError, "directory sync failed"):
                cloudflare_ranges._atomic_write(self.path, "replacement\n")

        self.assertEqual(self.path.read_text(encoding="utf-8"), "replacement\n")

    def test_removed_ranges_are_reported(self) -> None:
        write_ranges(self.path, [*self.ipv4_ranges, self.v4_b], self.ipv6_ranges)

        result = cloudflare_ranges.sync_ranges(
            self.path,
            "\n".join(self.ipv4_ranges) + "\n",
            "\n".join(self.ipv6_ranges) + "\n",
        )

        self.assertTrue(result.changed)
        self.assertEqual(result.added_count, 0)
        self.assertEqual(result.removed_count, 1)
        self.assertNotIn(self.v4_b, self.path.read_text(encoding="utf-8"))

    def test_invalid_upstream_lists_fail_closed(self) -> None:
        write_ranges(self.path, self.ipv4_ranges, self.ipv6_ranges)
        valid_ipv4 = "\n".join(self.ipv4_ranges) + "\n"
        valid_ipv6 = "\n".join(self.ipv6_ranges) + "\n"
        cases = (
            ("malformed", "not-a-network", valid_ipv6, "invalid CIDR"),
            ("wrong version", self.v6_a, valid_ipv6, "expected IPv4"),
            (
                "duplicate",
                f"{valid_ipv4}{self.v4_a}\n",
                valid_ipv6,
                "duplicate range",
            ),
            (
                "overly broad",
                f"8.0.0.0/8\n{valid_ipv4}",
                valid_ipv6,
                "prefix is wider than /12",
            ),
            (
                "not globally routable",
                f"0.0.0.0/24\n{valid_ipv4}",
                valid_ipv6,
                "not globally routable",
            ),
            (
                "overlapping",
                f"1.0.0.0/16\n{valid_ipv4}",
                valid_ipv6,
                "overlaps another range",
            ),
            ("empty", "", valid_ipv6, "no ranges returned"),
        )
        for label, ipv4_text, ipv6_text, message in cases:
            with self.subTest(label=label), self.assertRaisesRegex(ValueError, message):
                cloudflare_ranges.sync_ranges(self.path, ipv4_text, ipv6_text)

    def test_truncated_but_valid_lists_fail_closed(self) -> None:
        write_ranges(self.path, self.ipv4_ranges, self.ipv6_ranges)
        before = self.path.read_bytes()
        cases = (
            (
                "IPv4 below family minimum",
                self.ipv4_ranges[: cloudflare_ranges.MIN_IPV4_RANGES - 1],
                self.ipv6_ranges,
                "IPv4: 9 ranges is below minimum 10",
            ),
            (
                "IPv6 below family minimum",
                self.ipv4_ranges,
                self.ipv6_ranges[: cloudflare_ranges.MIN_IPV6_RANGES - 1],
                "IPv6: 4 ranges is below minimum 5",
            ),
            (
                "combined below total minimum",
                self.ipv4_ranges[: cloudflare_ranges.MIN_IPV4_RANGES],
                self.ipv6_ranges[: cloudflare_ranges.MIN_IPV6_RANGES]
                + self.extra_ipv6_ranges,
                "19 ranges is below minimum 20",
            ),
        )
        for label, ipv4_ranges, ipv6_ranges, message in cases:
            with self.subTest(label=label), self.assertRaisesRegex(ValueError, message):
                cloudflare_ranges.sync_ranges(
                    self.path,
                    "\n".join(ipv4_ranges) + "\n",
                    "\n".join(ipv6_ranges) + "\n",
                    write=False,
                )
        self.assertEqual(self.path.read_bytes(), before)

    def test_unexpected_trailing_content_is_not_deleted(self) -> None:
        self.path.write_text(
            "# test ranges\n"
            + "\n".join(
                f"client_ip {value}"
                for value in [*self.ipv4_ranges, *self.ipv6_ranges]
            )
            + "\ninvalid\n",
            encoding="utf-8",
        )
        before = self.path.read_bytes()

        with self.assertRaisesRegex(ValueError, "unexpected content"):
            cloudflare_ranges.sync_ranges(
                self.path,
                "\n".join(self.ipv4_ranges) + "\n",
                "\n".join(self.ipv6_ranges) + "\n",
            )

        self.assertEqual(self.path.read_bytes(), before)

    def test_cli_writes_action_outputs(self) -> None:
        write_ranges(self.path, self.ipv4_ranges, self.ipv6_ranges)
        output = self.root / "github-output"
        responses = {
            "https://v4.invalid": "\n".join([*self.ipv4_ranges, self.v4_b]) + "\n",
            "https://v6.invalid": "\n".join(self.ipv6_ranges) + "\n",
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
        self.assertIn(
            f"range_count={len(self.ipv4_ranges) + len(self.ipv6_ranges) + 1}\n",
            output.read_text(encoding="utf-8"),
        )

    def test_failed_fetch_leaves_the_file_untouched(self) -> None:
        write_ranges(self.path, self.ipv4_ranges, self.ipv6_ranges)
        before = self.path.read_bytes()

        with mock.patch.object(
            cloudflare_ranges, "_fetch_text", side_effect=OSError("offline")
        ):
            status = cloudflare_ranges.main(["sync", "--file", str(self.path)])

        self.assertEqual(status, 1)
        self.assertEqual(self.path.read_bytes(), before)

    def test_transient_fetch_failures_are_retried(self) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = self.v4_a.encode()
        unavailable = HTTPError(
            "https://v4.invalid", 503, "unavailable", {}, io.BytesIO(b"")
        )

        with (
            mock.patch.object(
                cloudflare_ranges, "urlopen", side_effect=[unavailable, response]
            ) as mocked_urlopen,
            mock.patch.object(cloudflare_ranges.time, "sleep") as mocked_sleep,
        ):
            result = cloudflare_ranges._fetch_text("https://v4.invalid")

        self.assertEqual(result, self.v4_a)
        self.assertEqual(mocked_urlopen.call_count, 2)
        mocked_sleep.assert_called_once_with(2)

    def test_permanent_fetch_failures_are_not_retried(self) -> None:
        missing = HTTPError(
            "https://v4.invalid", 404, "missing", {}, io.BytesIO(b"")
        )

        with (
            mock.patch.object(
                cloudflare_ranges, "urlopen", side_effect=missing
            ) as mocked_urlopen,
            mock.patch.object(cloudflare_ranges.time, "sleep") as mocked_sleep,
            self.assertRaises(HTTPError),
        ):
            cloudflare_ranges._fetch_text("https://v4.invalid")

        self.assertEqual(mocked_urlopen.call_count, 1)
        mocked_sleep.assert_not_called()

    def test_fetch_retries_are_bounded(self) -> None:
        with (
            mock.patch.object(
                cloudflare_ranges, "urlopen", side_effect=OSError("offline")
            ) as mocked_urlopen,
            mock.patch.object(cloudflare_ranges.time, "sleep") as mocked_sleep,
            self.assertRaises(OSError),
        ):
            cloudflare_ranges._fetch_text("https://v4.invalid")

        self.assertEqual(mocked_urlopen.call_count, cloudflare_ranges.FETCH_ATTEMPTS)
        self.assertEqual(
            [call.args[0] for call in mocked_sleep.call_args_list],
            [2, 4],
        )

    def test_oversized_fetch_response_is_rejected(self) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = (
            b"x" * (cloudflare_ranges.MAX_RESPONSE_BYTES + 1)
        )

        with (
            mock.patch.object(cloudflare_ranges, "urlopen", return_value=response),
            self.assertRaisesRegex(ValueError, "response exceeds"),
        ):
            cloudflare_ranges._fetch_text("https://v4.invalid")

    def test_excessive_range_count_is_rejected(self) -> None:
        write_ranges(self.path, self.ipv4_ranges, self.ipv6_ranges)
        excessive_ipv4 = [
            ipv4(0x01000000 + index * 0x100)
            for index in range(cloudflare_ranges.MAX_RANGES_PER_FAMILY + 1)
        ]

        with self.assertRaisesRegex(ValueError, "more than 128 ranges"):
            cloudflare_ranges.sync_ranges(
                self.path,
                "\n".join(excessive_ipv4) + "\n",
                "\n".join(self.ipv6_ranges) + "\n",
                write=False,
            )

    def test_default_target_is_repo_relative_not_process_relative(self) -> None:
        args = cloudflare_ranges._parser().parse_args(["sync"])

        self.assertTrue(args.file.is_absolute())
        self.assertEqual(args.file, REPO_ROOT / "config" / "cloudflare_ips.caddy")


if __name__ == "__main__":
    unittest.main()
