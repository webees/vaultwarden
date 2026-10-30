#!/usr/bin/env python3
"""Audit fail-closed address normalization without network or production access."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CADDY_CONFIG = ROOT / "scripts/container/entrypoint/config.sh"
RESTIC_SCRIPT = ROOT / "scripts/container/restic.sh"


def validate_caddy_script(
    script: Path, domains: str | None, domain: str | None
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.pop("CADDY_DOMAINS", None)
    environment.pop("DOMAIN", None)
    if domains is not None:
        environment["CADDY_DOMAINS"] = domains
    if domain is not None:
        environment["DOMAIN"] = domain
    command = (
        '. "$1"; validate_caddy_addresses; rc=$?; '
        'if [ "$rc" -eq 0 ]; then printf "CADDY_DOMAINS=%s\\n" "$CADDY_DOMAINS"; fi; '
        'exit "$rc"'
    )
    return subprocess.run(
        ["/bin/bash", "-c", command, "address-audit", str(script)],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


def validate_caddy(domains: str | None, domain: str | None) -> subprocess.CompletedProcess[str]:
    return validate_caddy_script(CADDY_CONFIG, domains, domain)


def audit_addresses(
    domains: str = "example.com",
    domain: str = "https://vault.example.com",
    repository: str = "s3://s3.example.invalid/bucket",
    healthcheck: str = "https://health.invalid/ping",
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "ADDRESS_AUDIT_JSON": "1",
            "CADDY_DOMAINS": domains,
            "DOMAIN": domain,
            "RESTIC_REPOSITORY": repository,
            "HEALTHCHECK_URL": healthcheck,
        }
    )
    return subprocess.run(
        ["/bin/bash", "-c", '. "$1"; audit_addresses', "address-audit", str(CADDY_CONFIG)],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


class CaddyAddressAuditTest(unittest.TestCase):
    def test_valid_hosts_are_unique_and_case_normalized(self) -> None:
        result = validate_caddy(
            "EXAMPLE.com   version.127.example   xn--bcher-kva.example",
            "https://vault.example.com:8443",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "CADDY_DOMAINS=example.com version.127.example xn--bcher-kva.example\n",
        )

    def test_unset_or_empty_domain_is_allowed_but_hosts_are_required(self) -> None:
        self.assertEqual(validate_caddy(None, None).returncode, 0)
        self.assertEqual(validate_caddy("", "https://vault.example.com").returncode, 0)
        rejected = validate_caddy("   ", None)
        self.assertEqual(rejected.returncode, 2)
        self.assertIn("at least one host", rejected.stderr)

    def test_invalid_or_ambiguous_hosts_fail_closed(self) -> None:
        cases = {
            "duplicate": "example.com EXAMPLE.com",
            "trailing dot": "example.com.",
            "newline": "example.com\nexample.org",
            "tab": "example.com\texample.org",
            "leading hyphen": "-example.com",
            "trailing hyphen": "example-.com",
            "underscore": "example_com",
            "wildcard": "*.example.com",
            "raw unicode": "bücher.example",
            "oversized label": f"{'a' * 64}.example.com",
            "oversized name": ".".join(["a" * 63] * 4),
            "ipv4": "127.0.0.1",
            "invalid dotted numeric": "999.999.999.999",
            "decimal ipv4": "2130706433",
            "hexadecimal ipv4": "0x7f000001",
        }
        for label, value in cases.items():
            with self.subTest(label=label):
                result = validate_caddy(value, None)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(result.stdout.startswith("CADDY_DOMAINS="))

    def test_domain_rejects_ambiguous_or_unsafe_urls(self) -> None:
        cases = {
            "http": "http://example.com",
            "missing host": "https://",
            "userinfo": "https://user@example.com",
            "path": "https://example.com/login",
            "trailing slash": "https://example.com/",
            "query": "https://example.com?x=1",
            "fragment": "https://example.com#x",
            "space": "https://example .com",
            "control": "https://example.com\n",
            "trailing dot": "https://example.com.",
            "zero port": "https://example.com:0",
            "large port": "https://example.com:65536",
            "text port": "https://example.com:https",
            "empty port": "https://example.com:",
            "encoded traversal": "https://example.com/%2e%2e/admin",
            "raw unicode host": "https://bücher.example",
            "bracketed IPv6": "https://[2001:db8::1]",
            "unbracketed IPv6": "https://2001:db8::1",
            "ipv4": "https://127.0.0.1",
            "invalid dotted numeric": "https://999.999.999.999",
            "decimal ipv4": "https://2130706433",
            "hexadecimal ipv4": "https://0x7f000001",
            "oversized origin": f"https://{'a' * 254}",
        }
        for label, value in cases.items():
            with self.subTest(label=label):
                result = validate_caddy("example.com", value)
                self.assertEqual(result.returncode, 2)

    def test_negative_control_detects_a_disabled_host_guard(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="vaultwarden-audit-", dir=os.environ.get("TMPDIR", "/tmp")
        ) as temporary:
            mutated = Path(temporary) / "config.sh"
            source = CADDY_CONFIG.read_text(encoding="utf-8")
            marker = 'valid_dns_name "$item" || {'
            self.assertIn(marker, source)
            mutated.write_text(source.replace(marker, 'true || {', 1), encoding="utf-8")
            result = validate_caddy_script(mutated, "bad_host", None)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_negative_control_detects_a_disabled_numeric_host_guard(self) -> None:
        source = CADDY_CONFIG.read_text(encoding="utf-8")
        marker = '        && ! is_numeric_host "$name" \\\n'
        self.assertIn(marker, source)
        with tempfile.TemporaryDirectory(
            prefix="vaultwarden-audit-", dir=os.environ.get("TMPDIR", "/tmp")
        ) as temporary:
            mutated = Path(temporary) / "config.sh"
            mutated.write_text(source.replace(marker, "", 1), encoding="utf-8")
            result = subprocess.run(
                ["/bin/bash", "-c", '. "$1"; valid_dns_name 127.0.0.1', "address-audit", str(mutated)],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_negative_control_detects_a_disabled_cidr_family_guard(self) -> None:
        source = (ROOT / "scripts/ci/cloudflare_ranges.py").read_text(encoding="utf-8")
        marker = "if network.version != version:"
        self.assertIn(marker, source)
        with tempfile.TemporaryDirectory(
            prefix="vaultwarden-audit-", dir=os.environ.get("TMPDIR", "/tmp")
        ) as temporary:
            module = Path(temporary) / "cloudflare_ranges.py"
            module.write_text(source.replace(marker, "if False:", 1), encoding="utf-8")
            program = (
                "import importlib.util, pathlib, sys; "
                "path=pathlib.Path(sys.argv[1]); "
                "spec=importlib.util.spec_from_file_location('mutated', path); "
                "module=importlib.util.module_from_spec(spec); "
                "sys.modules['mutated']=module; spec.loader.exec_module(module); "
                "module._parse_range_list('2606:4700::/32\\n', 4, 'audit')"
            )
            result = subprocess.run(
                [sys.executable, "-c", program, str(module)],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)


class BackupAddressAuditTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="vaultwarden-audit-", dir=os.environ.get("TMPDIR", "/tmp")
        )
        self.addCleanup(self.temporary.cleanup)

    def run_restic(self, repository: str, healthcheck: str = "") -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "RESTIC_REPOSITORY": repository,
                "HEALTHCHECK_URL": healthcheck,
                "RESTIC_LOG_DIR": self.temporary.name,
            }
        )
        return subprocess.run(
            ["/bin/bash", str(RESTIC_SCRIPT), "invalid-command"],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_repository_accepts_only_absolute_paths_or_unambiguous_s3_uris(self) -> None:
        accepted = (
            f"{self.temporary.name}/repository",
            "s3://s3.example.invalid/bucket/path",
            "s3://s3.example.invalid:9000/bucket",
        )
        for value in accepted:
            with self.subTest(value=value):
                result = self.run_restic(value)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("RESTIC_REPOSITORY", result.stderr)

        rejected = (
            "relative/path",
            "/tmp/../escape",
            f"{self.temporary.name}/repository/../escape",
            f"{self.temporary.name}/repository/..",
            "/tmp//double",
            "s3://user@example.invalid/bucket",
            "s3://example.invalid",
            "s3://example.invalid/../bucket",
            "s3://example.invalid/bucket?query",
            "s3://example.invalid/bucket#fragment",
            "s3://example.invalid/bucket%2fescape",
            "s3://example.invalid//bucket",
            "s3://127.0.0.1/bucket",
            "s3://999.999.999.999/bucket",
            "s3://2130706433/bucket",
            "s3://0x7f000001/bucket",
            "s3://[2001:db8::1]/bucket",
        )
        for value in rejected:
            with self.subTest(value=value):
                result = self.run_restic(value)
                self.assertEqual(result.returncode, 2)
                self.assertIn("RESTIC_REPOSITORY", result.stderr)

    def test_healthcheck_requires_https_and_rejects_ambiguous_components(self) -> None:
        accepted = (
            "https://health.invalid",
            "https://health.invalid/ping",
            "https://health.invalid/ping_2/deep-path",
            "https://health.invalid:65535/ping",
        )
        for value in accepted:
            with self.subTest(value=value):
                result = self.run_restic("s3://s3.example.invalid/bucket", value)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("HEALTHCHECK_URL", result.stderr)

        rejected = (
            "http://health.invalid/ping",
            "https://user@health.invalid/ping",
            "https://health.invalid./ping",
            "https://health.invalid/ping?token=value",
            "https://health.invalid/ping#fragment",
            "https://health.invalid/../ping",
            "https://health.invalid/%2e%2e/ping",
            "https://health.invalid/ping%2ffail",
            "https://health.invalid/ping//fail",
            "https://health.invalid:0/ping",
            "https://health.invalid:65536/ping",
            "https://health.invalid/<script>",
            "https://health.invalid/ping:token",
            "https://health.invalid/ping@token",
            "https://[2001:db8::1]/ping",
            "https://127.0.0.1/ping",
            "https://999.999.999.999/ping",
            "https://2130706433/ping",
            "https://0x7f000001/ping",
            f"https://health.invalid/{'a' * 1025}",
        )
        for value in rejected:
            with self.subTest(value=value):
                result = self.run_restic("s3://s3.example.invalid/bucket", value)
                self.assertEqual(result.returncode, 2)
                self.assertIn("HEALTHCHECK_URL", result.stderr)

    def test_negative_control_detects_disabled_healthcheck_path_guard(self) -> None:
        source = CADDY_CONFIG.read_text(encoding="utf-8")
        marker = "*[!A-Za-z0-9._~/-]*"
        self.assertIn(marker, source)
        with tempfile.TemporaryDirectory(
            prefix="vaultwarden-audit-", dir=os.environ.get("TMPDIR", "/tmp")
        ) as temporary:
            mutated = Path(temporary) / "config.sh"
            mutated.write_text(source.replace(marker, "*[!A-Za-z0-9._~/%-]*", 1), encoding="utf-8")
            result = subprocess.run(
                [
                    "/bin/bash", "-c",
                    '. "$1"; HEALTHCHECK_URL=https://health.invalid/%2e%2e/ping; validate_healthcheck_url',
                    "address-audit", str(mutated),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_negative_control_detects_the_shared_hostname_guard(self) -> None:
        source = CADDY_CONFIG.read_text(encoding="utf-8")
        marker = 'valid_dns_name "$host"'
        self.assertIn(marker, source)
        with tempfile.TemporaryDirectory(
            prefix="vaultwarden-audit-", dir=os.environ.get("TMPDIR", "/tmp")
        ) as temporary:
            mutated = Path(temporary) / "config.sh"
            mutated.write_text(source.replace(marker, "true", 1), encoding="utf-8")
            result = subprocess.run(
                [
                    "/bin/bash", "-c",
                    '. "$1"; validate_https_url https://bad_host/ping true',
                    "address-audit", str(mutated),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_negative_control_detects_disabled_repository_traversal_guard(self) -> None:
        source = CADDY_CONFIG.read_text(encoding="utf-8")
        marker = 'case "$path" in'
        self.assertIn(marker, source)
        with tempfile.TemporaryDirectory(
            prefix="vaultwarden-audit-", dir=os.environ.get("TMPDIR", "/tmp")
        ) as temporary:
            mutated = Path(temporary) / "config.sh"
            mutated.write_text(source.replace(marker, "case safe in", 1), encoding="utf-8")
            result = subprocess.run(
                [
                    "/bin/bash", "-c",
                    '. "$1"; RESTIC_REPOSITORY=s3://s3.example.invalid/../bucket; validate_restic_repository',
                    "address-audit", str(mutated),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_negative_control_detects_an_empty_repository_path_segment(self) -> None:
        source = CADDY_CONFIG.read_text(encoding="utf-8")
        marker = "        /*|*//*|*'/../'*|../*|*/.."
        self.assertIn(marker, source)
        with tempfile.TemporaryDirectory(
            prefix="vaultwarden-audit-", dir=os.environ.get("TMPDIR", "/tmp")
        ) as temporary:
            mutated = Path(temporary) / "config.sh"
            mutated.write_text(
                source.replace(marker, "        *//*|*'/../'*|../*|*/..", 1),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "/bin/bash", "-c",
                    '. "$1"; RESTIC_REPOSITORY=s3://example.invalid//bucket; validate_restic_repository',
                    "address-audit", str(mutated),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejected_addresses_create_no_runtime_state(self) -> None:
        log_dir = Path(self.temporary.name)
        before = list(log_dir.iterdir())

        result = self.run_restic("relative/path")

        self.assertEqual(result.returncode, 2)
        self.assertEqual(list(log_dir.iterdir()), before)

    def test_machine_readable_summary_is_stable_and_redacted(self) -> None:
        result = audit_addresses()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            '{"status":"ok","caddy_hosts":1,"domain_configured":true,'
            '"repository_kind":"s3","healthcheck_configured":true}\n',
        )
        for raw in ("example.com", "example.invalid", "/bucket", "/ping"):
            self.assertNotIn(raw, result.stdout)

    def test_machine_readable_summary_is_not_emitted_for_rejected_input(self) -> None:
        result = audit_addresses(healthcheck="https://health.invalid/%2e%2e/ping")

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
