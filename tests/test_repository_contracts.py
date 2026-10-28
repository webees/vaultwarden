#!/usr/bin/env python3
"""Exercise repository-level contracts without network or production access."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import unittest

from tests.performance import Result, apply_baseline, build_database, parse_docker_memory, require_temporary_path


ROOT = Path(__file__).resolve().parents[1]
DIGEST = "sha256:" + "a" * 64


def run(*args: str, cwd: Path = ROOT, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, check=False)


def write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)


def tracked_files() -> list[Path]:
    result = run("git", "ls-files", "-z")
    if result.returncode:
        raise AssertionError(result.stderr)
    return [ROOT / value for value in result.stdout.split("\0") if value and (ROOT / value).exists()]


class DependencyResolverTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        (self.repo / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/deps.sh", self.repo / "scripts/deps.sh")
        (self.repo / "Dockerfile").write_text(
            "ARG VAULTWARDEN_VERSION=1.0.0\n"
            f"ARG VAULTWARDEN_DIGEST={DIGEST}\n"
            "ARG SUPERCRONIC_VERSION=v1.0.0\n"
            f"ARG SUPERCRONIC_SHA256_amd64={'b' * 64}\n"
            f"ARG SUPERCRONIC_SHA256_arm64={'c' * 64}\n",
            encoding="utf-8",
        )
        self.bin = self.repo / "bin"
        self.bin.mkdir()
        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin}:{self.env['PATH']}"
        self.output = self.repo / "output"
        self.env["GITHUB_OUTPUT"] = str(self.output)
        self.output.write_text("", encoding="utf-8")
        self._git("init", "-q")
        self._git("add", ".")
        self._git("-c", "user.name=test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _git(self, *args: str) -> None:
        result = run("git", *args, cwd=self.repo)
        self.assertEqual(result.returncode, 0, result.stderr)

    def _deps(self, *args: str, check: bool = False) -> subprocess.CompletedProcess[str]:
        result = run("scripts/deps.sh", *args, cwd=self.repo, env=self.env)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_compare_apply_and_rejection_are_atomic(self) -> None:
        result = self._deps("compare", "VAULTWARDEN_VERSION=1.0.0", "SUPERCRONIC_VERSION=v2.0.0", check=True)
        self.assertIn("ok   VAULTWARDEN_VERSION", result.stdout)
        self.assertIn("diff SUPERCRONIC_VERSION: v1.0.0 -> v2.0.0", result.stdout)
        self.assertIn("changed=true", self.output.read_text(encoding="utf-8"))

        before = (self.repo / "Dockerfile").read_bytes()
        for pair, message in (
            ("UNKNOWN=value", "not declared"),
            ("VAULTWARDEN_VERSION=", "empty value"),
            ("VAULTWARDEN_VERSION=1.2.3&touch", "invalid value"),
            ("bad-name=value", "valid pin name"),
        ):
            with self.subTest(pair=pair):
                result = self._deps("apply", "SUPERCRONIC_VERSION=v9.9.9", pair)
                self.assertEqual(result.returncode, 2)
                self.assertIn(message, result.stderr)
                self.assertEqual((self.repo / "Dockerfile").read_bytes(), before)

        self._deps("apply", "SUPERCRONIC_VERSION=v2.0.0", check=True)
        self.assertIn("ARG SUPERCRONIC_VERSION=v2.0.0", (self.repo / "Dockerfile").read_text())
        self.output.write_text("", encoding="utf-8")
        self._git("add", "Dockerfile")
        self._git("add", "output")
        self._git("-c", "user.name=test", "-c", "user.email=test@example.invalid", "commit", "-qm", "pin")
        self._deps("apply", "SUPERCRONIC_VERSION=v2.0.0", check=True)
        self.assertEqual(run("git", "diff", "--quiet", cwd=self.repo).returncode, 0)

    def test_base_selects_highest_semver_and_uses_its_digest(self) -> None:
        page = json.dumps({"results": [
            {"name": "1.9.0-alpine"}, {"name": "latest"}, {"name": "1.10.0-alpine"}
        ], "next": None})
        curl = f"""#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
url = args[-1]
if 'auth.docker.io/token' in url:
    print(json.dumps({{'token': 'token.value'}}))
elif '-I' in args:
    print('Docker-Content-Digest: {DIGEST}')
elif 'hub.docker.com' in url:
    print({page!r})
else:
    raise SystemExit(f'unexpected URL: {{url}}')
"""
        write_executable(self.bin / "curl", curl)
        result = self._deps("base", check=True)
        output = self.output.read_text(encoding="utf-8")
        self.assertIn("version=1.10.0", output)
        self.assertIn(f"digest={DIGEST}", output)

    def test_tools_choose_latest_stable_release_and_hashes_both_architectures(self) -> None:
        releases = [
            {"tag_name": "v2.0.0", "prerelease": False, "draft": False, "assets": [
                {"name": "supercronic-linux-amd64", "browser_download_url": "https://github.com/aptible/supercronic/releases/download/v2.0.0/supercronic-linux-amd64"},
                {"name": "supercronic-linux-arm64", "browser_download_url": "https://github.com/aptible/supercronic/releases/download/v2.0.0/supercronic-linux-arm64"},
            ]},
            {"tag_name": "v1.9.0", "prerelease": False, "draft": False, "assets": []},
            {"tag_name": "v3.0.0", "prerelease": True, "draft": False, "assets": []},
        ]
        write_executable(self.bin / "gh", "#!/bin/sh\nprintf '%s\\n' \"$FAKE_RELEASES\"\n")
        write_executable(self.bin / "curl", "#!/bin/sh\nprintf 'payload'\n")
        self.env["FAKE_RELEASES"] = json.dumps(releases)
        result = self._deps("tools", check=True)
        output = self.output.read_text(encoding="utf-8")
        self.assertIn("supercronic_version=v2.0.0", output)
        self.assertIn("supercronic_sha_amd64=", output)
        self.assertIn("supercronic_sha_arm64=", output)

    def test_apk_and_rebuild_decisions_fail_closed(self) -> None:
        write_executable(self.bin / "docker", "#!/bin/sh\nprintf 'zlib 1.2.13-r0 1.2.13-r1\\n'\n")
        result = self._deps("apk", "image", check=True)
        self.assertIn("upgradable packages: 1", result.stdout)
        self.assertIn("count=1", self.output.read_text(encoding="utf-8"))
        self.assertEqual(self._deps("rebuild-needed", "0", "0").returncode, 1)
        self.assertEqual(self._deps("rebuild-needed", "1", "0").returncode, 1)
        self.assertEqual(self._deps("rebuild-needed", "1", "2").returncode, 0)
        self.assertEqual(self._deps("rebuild-needed", "bad", "2").returncode, 2)
        self.assertEqual(self._deps("unknown").returncode, 2)


class RepositoryHygieneTest(unittest.TestCase):
    def test_runtime_files_have_one_process_model_and_static_ranges(self) -> None:
        service = (ROOT / "scripts/services.sh").read_text(encoding="utf-8")
        for command in ("/vaultwarden", "caddy run --config /Caddyfile", "supercronic /crontab"):
            self.assertIn(command, service)
        entrypoint = (ROOT / "scripts/entrypoint.sh").read_text(encoding="utf-8")
        for module in ("filesystem", "config", "restore", "smtp"):
            self.assertIn(f"/entrypoint/{module}.sh", entrypoint)
        runtime = "\n".join(
            (ROOT / path).read_text(encoding="utf-8")
            for path in ("Dockerfile", "scripts/services.sh", "scripts/entrypoint.sh")
        )
        for forbidden in ("overmind", "tmux", "Procfile", "supervise.sh"):
            self.assertNotIn(forbidden, runtime)

    def test_scripts_wrap_network_calls_and_avoid_nonportable_find(self) -> None:
        scripts = list((ROOT / "scripts").rglob("*.sh"))
        contents = {path: path.read_text(encoding="utf-8") for path in scripts}
        self.assertFalse(any("-printf" in body for body in contents.values()))
        calls = 0
        bounded = 0
        for body in contents.values():
            lines = body.splitlines()
            for index, line in enumerate(lines):
                if not line.lstrip().startswith("curl "):
                    continue
                calls += 1
                block = "\n".join(lines[index:index + 5])
                bounded += any(flag in block for flag in ("--max-time", " -m "))
        self.assertGreater(calls, 0)
        self.assertEqual(calls, bounded)
        self.assertIn("timeout \"$GH_TIMEOUT\" gh api", (ROOT / "scripts/deps.sh").read_text())

    def test_recurring_log_regression_stays_fixed(self) -> None:
        restic = (ROOT / "scripts/restic.sh").read_text(encoding="utf-8")
        start = restic.index("log() {")
        block = restic[start:restic.index("\n}\n", start) + 3]

        self.assertIn('tail -c "$MAX_LOG_BYTES"', block)
        self.assertIn("write_log_entry", block)
        self.assertNotIn('body="$("$@" 2>&1)"', block)
        self.assertNotIn("eval ", restic)
        decisions = (ROOT / "docs/recurring_issues.md").read_text(encoding="utf-8")
        self.assertIn("Bounded Diagnostics", decisions)
        self.assertIn("Simplification Rule", decisions)
        self.assertIn("docs/recurring_issues.md", (ROOT / "README.md").read_text(encoding="utf-8"))

    def test_security_randomness_uses_operating_system_entropy(self) -> None:
        production = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (*sorted((ROOT / "scripts").rglob("*.sh")), ROOT / "scripts/cloudflare_ranges.py")
        )
        forbidden = re.compile(
            r"\$RANDOM|random\.(?:random|randint|randrange|choice|choices)|uuid\.uuid1|openssl\s+rand"
        )
        self.assertIsNone(forbidden.search(production))
        performance = (ROOT / "tests/performance.py").read_text(encoding="utf-8")
        self.assertIn("secrets.token_hex", performance)
        self.assertNotRegex(performance, r"uuid\.uuid1|random\.(?:random|randint|randrange)")

    def test_env_docs_and_secret_placeholders_stay_aligned(self) -> None:
        example = (ROOT / ".env.example").read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        tuning = {
            "BACKUP_MAX_AGE", "BACKUP_MAX_USAGE_PERCENT", "RESTIC_LOG_DIR",
            "RESTIC_LOG_MAX_BYTES", "RESTIC_LOG_DIR_MAX_BYTES", "RESTIC_QUICK_TIMEOUT",
            "RESTIC_LONG_TIMEOUT", "VERIFY_SUBSET", "VERIFY_RETRY_LOCK",
            "SUPERVISE_RESTART_DELAY",
        }
        for name in tuning:
            self.assertIn(f"{name}=", example)
            self.assertIn(name, readme)
        for required in ("RESTORE_CONFIRM=yes", "restore-pending", "config.json", "runtime_smoke.py"):
            self.assertIn(required, readme)
        forbidden = re.compile("xv" + r"x-|s3://[a-f0-9]{20,}|[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}")
        for path in tracked_files():
            if not path.is_file() or path.suffix in {".png", ".jpg", ".gif"}:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            match = forbidden.search(text)
            self.assertIsNone(match, f"sensitive value in {path.relative_to(ROOT)}")

    def test_quality_budgets_do_not_regress(self) -> None:
        budgets = {
            "README.md": 146,
            ".env.example": 48,
            "scripts/restic.sh": 520,
            "scripts/cloudflare_ranges.py": 200,
        }
        for path, limit in budgets.items():
            with self.subTest(path=path):
                lines = len((ROOT / path).read_text(encoding="utf-8").splitlines())
                self.assertLessEqual(lines, limit, f"{path} grew to {lines} lines")
        test_files = [path for path in (ROOT / "tests").iterdir() if path.is_file()]
        test_lines = sum(len(path.read_text(encoding="utf-8").splitlines()) for path in test_files)
        self.assertLessEqual(test_lines, 4200, f"tests grew to {test_lines} lines")
        for removed in ("selftest.sh", "image_selftest.sh", "lib.sh"):
            self.assertFalse((ROOT / "tests" / removed).exists())

    def test_access_logs_remove_referrer_and_query_values(self) -> None:
        caddy = (ROOT / "config/Caddyfile").read_text(encoding="utf-8")
        self.assertIn("request>headers>Referer delete", caddy)
        self.assertIn('request>uri regexp "\\?.*$" "?redacted"', caddy)

    def test_files_are_executable_only_when_they_are_commands(self) -> None:
        for path in tracked_files():
            mode = path.stat().st_mode
            if path.suffix == ".sh" and path.parent in {ROOT / "scripts", ROOT / "tests"} and path.name != "lib.sh":
                self.assertTrue(mode & stat.S_IXUSR, path)
            if path.suffix in {".md", ".yml", ".yaml", ".toml"}:
                self.assertFalse(mode & stat.S_IXUSR, path)


class PerformanceHarnessTest(unittest.TestCase):
    def result(self, median: float) -> Result:
        return Result(
            name="scenario",
            baseline_median_ms=None,
            median_ms=median,
            p95_ms=median,
            peak_bytes=1,
            peak_budget_bytes=2,
            budget_ms=200,
            baseline_delta_percent=None,
        )

    def test_baseline_drift_gate_has_a_real_boundary(self) -> None:
        self.assertTrue(apply_baseline(self.result(110), {"scenario": 100}).passed)
        self.assertFalse(apply_baseline(self.result(110.01), {"scenario": 100}).passed)
        self.assertTrue(apply_baseline(self.result(9.99), {"scenario": 8}).passed)
        self.assertFalse(apply_baseline(self.result(10.01), {"scenario": 8}).passed)
        with self.assertRaisesRegex(ValueError, "missing scenario"):
            apply_baseline(self.result(1), {})

    def test_missing_or_zero_memory_measurements_fail_closed(self) -> None:
        self.assertEqual(parse_docker_memory("12.5MiB / 256MiB"), 13_107_200)
        for output in ("", "0B / 1GiB", "not-a-measurement"):
            with self.subTest(output=output):
                with self.assertRaisesRegex(ValueError, "memory value"):
                    parse_docker_memory(output)
        result = self.result(1)
        self.assertFalse(
            Result(
                name=result.name,
                baseline_median_ms=None,
                median_ms=result.median_ms,
                p95_ms=result.p95_ms,
                peak_bytes=0,
                peak_budget_bytes=result.peak_budget_bytes,
                budget_ms=result.budget_ms,
                baseline_delta_percent=None,
            ).passed
        )

    def test_sqlite_restore_fixture_is_self_contained(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vaultwarden-audit-", dir=os.environ.get("TMPDIR", "/tmp")) as temporary:
            source = Path(temporary) / "source.sqlite3"
            restored = Path(temporary) / "restored.sqlite3"
            build_database(source)
            shutil.copyfile(source, restored)
            self.assertFalse(Path(f"{source}-wal").exists())
            with sqlite3.connect(f"file:{restored}?mode=ro", uri=True) as connection:
                self.assertEqual(connection.execute("PRAGMA integrity_check").fetchone(), ("ok",))
                self.assertEqual(connection.execute("SELECT count(*) FROM audit").fetchone(), (4096,))

    def test_baseline_files_are_confined_to_temporary_storage(self) -> None:
        with tempfile.NamedTemporaryFile(prefix="vaultwarden-audit-", suffix=".json") as temporary:
            self.assertEqual(require_temporary_path(Path(temporary.name)).name, Path(temporary.name).name)
        with self.assertRaisesRegex(ValueError, "temporary directory"):
            require_temporary_path(ROOT / "baseline.json")


if __name__ == "__main__":
    unittest.main()
