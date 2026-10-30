#!/usr/bin/env python3
"""Exercise repository-level contracts without network or production access."""

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest
from unittest import mock

from tests import runtime_smoke
from tests.performance import Result, apply_baseline, build_database, parse_docker_memory, require_temporary_path
from tests.test_recurring_gate import assert_recurrence_contract, scan_for_sensitive_data


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


def merge_binding_errors(workflow: str) -> list[str]:
    errors = []
    if workflow.count('--match-head-commit "$HEAD_SHA"') != 2:
        errors.append("both auto-merge paths must bind the reviewed head SHA")
    if workflow.count('[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]') != 2:
        errors.append("both auto-merge paths must validate a full lowercase SHA")
    return errors


def unbounded_gh_commands(workflow: str) -> list[str]:
    return [
        f"line {number}: {line.strip()}"
        for number, line in enumerate(workflow.splitlines(), 1)
        if re.search(r"\bgh\s+(?:api|pr|workflow)\b", line)
        and not re.search(r"\btimeout\s+[0-9]+\s+gh\s+", line)
    ]


def python_cache_errors(workflow: str) -> list[str]:
    errors = []
    for expected in (
        'PYTHONDONTWRITEBYTECODE: "1"',
        "PYTHONPYCACHEPREFIX: /tmp/vaultwarden-pycache",
        "TMPDIR: /tmp",
        "git status --porcelain --untracked-files=all",
    ):
        if expected not in workflow:
            errors.append(f"missing cache confinement: {expected}")
    return errors


def script_boundary_errors(dockerfile: str, dockerignore: str) -> list[str]:
    sources = set(re.findall(r"scripts/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", dockerfile))
    errors = ["Dockerfile copies CI-only scripts into the image"] if any(path.startswith("scripts/ci/") for path in sources) else []
    return errors + ([] if "scripts/ci" in dockerignore.splitlines() else [".dockerignore does not exclude scripts/ci"])

def workflow_step_script(workflow: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    block = workflow.split(marker, 1)[1]
    body = block.split("        run: |\n", 1)[1]
    return textwrap.dedent(re.split(r"\n\n(?=  [A-Za-z0-9_-]+:|      - name:)", body, maxsplit=1)[0])

class DependencyResolverTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        (self.repo / "scripts" / "ci").mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/ci/deps.sh", self.repo / "scripts/ci/deps.sh")
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
        result = run("scripts/ci/deps.sh", *args, cwd=self.repo, env=self.env)
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
        page = json.dumps({"results": [{"name": "1.9.0-alpine"}, {"name": "latest"}, {"name": "1.10.0-alpine"}], "next": None})
        release = json.dumps({"tag_name": "1.10.0", "draft": False, "prerelease": False})
        self.env["FAKE_RELEASE"] = release
        write_executable(self.bin / "gh", "#!/bin/sh\nprintf '%s\\n' \"${FAKE_RELEASE}\"\n")
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
        self.output.write_text("", encoding="utf-8")
        self.env["FAKE_RELEASE"] = json.dumps({"tag_name": "1.10.0", "draft": False, "prerelease": True})
        result = self._deps("base")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not an official stable release", result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "")

    def test_tools_choose_latest_stable_release_and_hashes_both_architectures(self) -> None:
        releases = [
            {"tag_name": "v2.0.0", "prerelease": False, "draft": False, "assets": [
                {"name": f"supercronic-linux-{arch}", "browser_download_url": f"https://github.com/aptible/supercronic/releases/download/v2.0.0/supercronic-linux-{arch}"}
                for arch in ("amd64", "arm64")]},
            {"tag_name": "v1.9.0", "prerelease": False, "draft": False, "assets": []},
            {"tag_name": "v3.0.0", "prerelease": True, "draft": False, "assets": []},
            {"tag_name": "v4.0.0", "assets": []},
        ]
        timeout_log = self.repo / "timeout-args"
        write_executable(self.bin / "timeout", f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{timeout_log}'\nshift 3\nexec \"$@\"\n")
        write_executable(self.bin / "gh", "#!/bin/sh\nprintf '%s\\n' \"$FAKE_RELEASES\"\n")
        write_executable(self.bin / "curl", "#!/bin/sh\nprintf 'payload'\n")
        self.env["FAKE_RELEASES"] = json.dumps(releases)
        result = self._deps("tools", check=True)
        output = self.output.read_text(encoding="utf-8")
        self.assertRegex(timeout_log.read_text(encoding="utf-8"), r"^-k 2 30 gh api https://api\.github\.com/")
        self.assertIn("supercronic_version=v2.0.0", output)
        self.assertIn("supercronic_sha_amd64=", output)
        self.assertIn("supercronic_sha_arm64=", output)

    def test_network_timeouts_reject_unbounded_values_before_network_calls(self) -> None:
        marker = self.repo / "network-called"
        write_executable(self.bin / "curl", f"#!/bin/sh\nprintf called > '{marker}'\n")
        write_executable(self.bin / "gh", f"#!/bin/sh\nprintf called > '{marker}'\n")
        write_executable(self.bin / "timeout", "#!/bin/sh\nshift\nexec \"$@\"\n")
        for name, value, command in (
            ("DEPS_HTTP_TIMEOUT", "0", "base"),
            ("DEPS_HTTP_TIMEOUT", "1.5", "base"),
            ("DEPS_GH_TIMEOUT", "0", "tools"),
            ("DEPS_GH_TIMEOUT", "00", "tools"),
            ("DEPS_GH_TIMEOUT", "-1", "tools"),
            ("DEPS_GH_TIMEOUT", "1s", "tools"),
        ):
            with self.subTest(name=name, value=value):
                marker.unlink(missing_ok=True)
                self.env[name] = value
                result = self._deps(command)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                self.assertFalse(marker.exists())
            self.env.pop(name, None)

    def test_missing_timeout_fails_closed_and_mutation_control_catches_fallback(self) -> None:
        marker = self.repo / "gh-called"
        write_executable(self.bin / "gh", f"#!/bin/sh\nprintf called > '{marker}'\n")
        write_executable(self.bin / "dirname", "#!/bin/sh\nprintf 'scripts/ci\\n'\n")

        self.env["PATH"] = str(self.bin)
        result = self._deps("tools")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires timeout or gtimeout", result.stderr)
        self.assertFalse(marker.exists())

        source = (ROOT / "scripts/ci/deps.sh").read_text(encoding="utf-8")
        expected_guard = '        fail "gh api requires timeout or gtimeout to enforce DEPS_GH_TIMEOUT"'
        self.assertEqual(source.count(expected_guard), 1)
        mutated = self.repo / "scripts" / "ci" / "deps-mutated.sh"
        mutated.write_text(source.replace(expected_guard, '        gh api "$@"', 1), encoding="utf-8")
        mutated.chmod(0o755)
        result = run(str(mutated), "tools", cwd=self.repo, env=self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(marker.exists())

    def test_real_timeout_stops_a_stalled_gh_request(self) -> None:
        write_executable(self.bin / "gh", "#!/bin/sh\nexec sleep 5\n")
        self.env["DEPS_GH_TIMEOUT"] = "1"
        started = time.monotonic()
        result = self._deps("tools")
        elapsed = time.monotonic() - started
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(elapsed, 2.5)

    def test_gtimeout_is_an_accepted_bounded_fallback(self) -> None:
        marker = self.repo / "gh-called"
        timeout_log = self.repo / "gtimeout-args"
        write_executable(self.bin / "gh", f"#!/bin/sh\nprintf called > '{marker}'\n")
        write_executable(self.bin / "dirname", "#!/bin/sh\nprintf 'scripts/ci\\n'\n")
        write_executable(
            self.bin / "gtimeout",
            f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{timeout_log}'\nshift 3\nexec \"$@\"\n",
        )
        self.env["PATH"] = str(self.bin)
        result = self._deps("tools")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertRegex(timeout_log.read_text(encoding="utf-8"), r"^-k 2 30 gh api https://api\.github\.com/")

    def test_apk_and_rebuild_decisions_fail_closed(self) -> None:
        write_executable(self.bin / "timeout", "#!/bin/sh\nshift 3\nexec \"$@\"\n")
        write_executable(self.bin / "docker", "#!/bin/sh\nprintf 'zlib 1.2.13-r0 1.2.13-r1\\n'\n")
        result = self._deps("apk", "image", check=True)
        self.assertIn("upgradable packages: 1", result.stdout)
        self.assertIn("count=1", self.output.read_text(encoding="utf-8"))
        self.assertNotEqual(self._deps("rebuild-needed", "0", "0").returncode, 0)
        self.assertNotEqual(self._deps("rebuild-needed", "1", "0").returncode, 0)
        self.assertEqual(self._deps("rebuild-needed", "0", "1").returncode, 0)
        self.assertEqual(self._deps("rebuild-needed", "1", "1").returncode, 0)
        self.assertEqual(self._deps("rebuild-needed", "bad", "2").returncode, 2)
        self.assertEqual(self._deps("unknown").returncode, 2)

    def test_published_package_probe_script_fails_closed(self) -> None:
        workflow = (ROOT / ".github/workflows/dependency_updates.yml").read_text(encoding="utf-8")
        script = workflow_step_script(workflow, "Validate the published package probe")
        self.env["GITHUB_REPOSITORY"] = "owner/repository"
        for outcome, code in (("failure", 1), ("", 1), ("success", 0)):
            with self.subTest(outcome=outcome):
                self.env["PUBLISHED_APK_OUTCOME"] = outcome
                result = run("/bin/bash", "-c", script, cwd=self.repo, env=self.env)
                self.assertEqual(result.returncode, code, result.stderr)
        self.env["PUBLISHED_APK_OUTCOME"] = "failure"
        mutated = script.replace('if [ "$PUBLISHED_APK_OUTCOME" != "success" ]; then', "if false; then", 1)
        self.assertEqual(run("/bin/bash", "-c", mutated, cwd=self.repo, env=self.env).returncode, 0)
        self.assertNotIn("steps.apk.outputs.count != '0'", workflow)

    def test_docker_commands_fail_closed_without_a_timeout_program(self) -> None:
        marker = self.repo / "docker-called"
        write_executable(self.bin / "docker", f"#!/bin/sh\nprintf called > '{marker}'\n")
        write_executable(self.bin / "dirname", "#!/bin/sh\nprintf 'scripts/ci\\n'\n")
        self.env["PATH"] = str(self.bin)
        result = self._deps("apk", "image")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires timeout or gtimeout", result.stderr)
        self.assertFalse(marker.exists())


class RepositoryHygieneTest(unittest.TestCase):
    def test_dependency_auto_merge_is_bound_to_the_reviewed_head(self) -> None:
        workflow = (ROOT / ".github/workflows/dependency_updates.yml").read_text(encoding="utf-8")
        self.assertEqual(merge_binding_errors(workflow), [])
        weakened = workflow.replace(' --match-head-commit "$HEAD_SHA"', "", 1)
        self.assertIn("reviewed head SHA", "\n".join(merge_binding_errors(weakened)))
        self.assertIn("AUDIT_RESULT: ${{ needs.production_audit.result }}", workflow)
        self.assertIn("<code>production_audit</code>", workflow)

    def test_workflow_gh_calls_are_bounded_and_mutation_is_detected(self) -> None:
        workflows = {path.name: path.read_text(encoding="utf-8") for path in (ROOT / ".github/workflows").glob("*.yml")}
        for name, workflow in workflows.items():
            with self.subTest(workflow=name):
                self.assertEqual(unbounded_gh_commands(workflow), [])
        mutated = next(text for text in workflows.values() if "timeout 30 gh api" in text)
        self.assertTrue(unbounded_gh_commands(mutated.replace("timeout 30 gh api", "gh api", 1)))

    def test_validation_keeps_python_cache_outside_the_repository(self) -> None:
        workflow = (ROOT / ".github/workflows/validate.yml").read_text(encoding="utf-8")
        self.assertEqual(python_cache_errors(workflow), [])
        weakened = workflow.replace("PYTHONPYCACHEPREFIX: /tmp/vaultwarden-pycache", "PYTHONPYCACHEPREFIX: .", 1)
        self.assertTrue(python_cache_errors(weakened))

    def test_documentation_changes_do_not_trigger_production_builds(self) -> None:
        workflow = (ROOT / ".github/workflows/build_and_deploy.yml").read_text(encoding="utf-8"); ignore = workflow.split("    paths-ignore:\n", 1)[1].split("  schedule:\n", 1)[0]
        entries = set(re.findall(r"^      - (\S+)$", ignore, re.MULTILINE)); required = {"README.md", "LICENSE", ".github/**", "docs/**", "tests/**", "scripts/ci/**"}
        self.assertEqual((required <= entries, bool({"Dockerfile", "fly.toml", "config/**", "scripts/**"} & entries)), (True, False))
        self.assertNotIn("docs/**", set(re.findall(r"^      - (\S+)$", ignore.replace("      - docs/**\n", "", 1), re.MULTILINE)))
        self.assertNotIn("scripts/ci/**", set(re.findall(r"^      - (\S+)$", ignore.replace("      - scripts/ci/**\n", "", 1), re.MULTILINE)))

    def test_production_and_notification_contracts_fail_closed(self) -> None:
        workflow = (ROOT / ".github/workflows/dependency_updates.yml").read_text(encoding="utf-8")
        script = workflow_step_script(workflow, "Verify production release and runtime health")
        digest, image = "sha256:" + "d" * 64, f"ghcr.io/owner/repository@sha256:{'d' * 64}"
        release = [{"Version": 1, "Status": "complete", "InProgress": False, "ImageRef": image}]
        machine = {"state": "started", "host_status": "ok", "checks": [{"status": "passing"}], "image_ref": {"registry": "ghcr.io", "repository": "owner/repository", "digest": digest}}
        with tempfile.TemporaryDirectory() as temporary:
            root, binary = Path(temporary), Path(temporary) / "bin"; binary.mkdir()
            write_executable(binary / "flyctl", '#!/bin/sh\ncase "$1" in releases) cat "$RELEASES_FIXTURE" ;; status) cat "$STATUS_FIXTURE" ;; *) exit 2 ;; esac\n')
            env = os.environ | {"FLY_APP": "test-app", "EXPECTED_IMAGE": image, "FLY_LOG_REDACT": "s/x/y/", "PATH": f"{binary}:{os.environ['PATH']}", "RELEASES_FIXTURE": str(root / "r.json"), "STATUS_FIXTURE": str(root / "s.json")}
            def audit(releases: object, status: object, command: str = script) -> subprocess.CompletedProcess[str]:
                Path(env["RELEASES_FIXTURE"]).write_text(json.dumps(releases), encoding="utf-8")
                Path(env["STATUS_FIXTURE"]).write_text(json.dumps(status), encoding="utf-8")
                return run("/bin/bash", "-c", command, cwd=ROOT, env=env)
            status = {"Status": "deployed", "Machines": [machine]}
            self.assertEqual(audit(release, status).returncode, 0)
            for item in ({**machine, "checks": []}, {**machine, "checks": [{"status": "critical"}]}, {**machine, "image_ref": {**machine["image_ref"], "digest": "sha256:" + "e" * 64}}):
                self.assertNotEqual(audit(release, {"Status": "deployed", "Machines": [item]}).returncode, 0)
            self.assertNotEqual(audit([{**release[0], "Status": "failed"}], status).returncode, 0)
            self.assertNotEqual(audit([{**release[0], "Version": 0, "InProgress": True}, *release], status).returncode, 0)
            env["EXPECTED_IMAGE"] = "ghcr.io/owner/repository@sha256:" + "f" * 64
            self.assertNotEqual(audit(release, status).returncode, 0)
            env["EXPECTED_IMAGE"] = image
            mutated = script.replace('(($latest.Status // "" | ascii_downcase) == "complete")', "true", 1)
            self.assertEqual(audit([{**release[0], "Status": "failed"}], status, mutated).returncode, 0)
            notify = workflow_step_script(workflow, "Send the failure through Telegram")
            token, chat = "123456789:token", "54321"
            write_executable(binary / "flyctl", '#!/bin/sh\ncase "$*" in *TELEGRAM_BOT_TOKEN*) printf "%s\\n" "$TELEGRAM_BOT_TOKEN" ;; *TELEGRAM_CHAT_ID*) printf "%s\\n" "$TELEGRAM_CHAT_ID" ;; *) exit 2 ;; esac\n')
            write_executable(binary / "curl", '#!/bin/sh\nprintf \'%s\\nHTTP_STATUS=200\' "$CURL_BODY"\n')
            notify_env = os.environ | {"FLY_API_TOKEN": "synthetic", "FLY_APP": "test-app", "PATH": f"{binary}:{os.environ['PATH']}", "TELEGRAM_BOT_TOKEN": token, "TELEGRAM_CHAT_ID": chat, "CURL_BODY": json.dumps({"ok": True, "result": {"chat": {"id": int(chat)}}}), "WORKFLOW": "Dependency Updates", "EVENT": "workflow_run", "SHA": "a" * 40, "RUN_URL": "https://github.com/owner/repository/actions/runs/1", "BUILD_RESULT": "failure", "CHECK_RESULT": "failure", "DEPENDABOT_RESULT": "skipped", "OPERATION_RESULT": "skipped", "AUDIT_RESULT": "skipped"}
            result = run("/bin/bash", "-c", notify, cwd=ROOT, env=notify_env)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = result.stderr + result.stdout; self.assertEqual((output.count(token), output.count(chat)), (1, 1))
            weakened = notify.replace('safe_body="${safe_body//"$chat_id"/<redacted>}"', 'body="${body//"$chat_id"/<redacted>}"', 1)
            self.assertNotEqual(run("/bin/bash", "-c", weakened, cwd=ROOT, env=notify_env).returncode, 0)

    def test_cleanup_automation_health_fails_closed(self) -> None:
        workflow = (ROOT / ".github/workflows/dependency_updates.yml").read_text(encoding="utf-8")
        script = workflow_step_script(workflow, "Check cleanup automation health")
        with tempfile.TemporaryDirectory() as temporary:
            root, binary = Path(temporary), Path(temporary) / "bin"
            binary.mkdir()
            runs = root / "runs.json"
            write_executable(binary / "timeout", "#!/bin/sh\nshift\nexec \"$@\"\n")
            write_executable(binary / "gh", "#!/bin/sh\ncat \"$CLEANUP_RUNS_FIXTURE\"\n")
            write_executable(binary / "date", "#!/bin/sh\ncase \"$*\" in '-u +%s') printf '2000\\n' ;; '-u -d 2026-10-29T00:00:00Z +%s') printf '1900\\n' ;; '-u -d 2026-10-29T01:00:00Z +%s') printf '2000\\n' ;; *) exit 2 ;; esac\n")
            env = os.environ | {"GITHUB_REPOSITORY": "owner/repository", "PATH": f"{binary}:{os.environ['PATH']}", "CLEANUP_RUNS_FIXTURE": str(runs)}
            failure = {"conclusion": "failure", "created_at": "2026-10-29T01:00:00Z"}
            success = {"conclusion": "success", "created_at": "2026-10-29T00:00:00Z"}
            def assert_runs(items: list[dict[str, str]], max_age: str, code: int) -> None:
                env["MAX_CLEANUP_AGE_SECONDS"] = max_age
                runs.write_text(json.dumps({"workflow_runs": items}), encoding="utf-8")
                self.assertEqual(run("/bin/bash", "-c", script, cwd=ROOT, env=env).returncode, code)
            assert_runs([failure, success], "150", 0)
            assert_runs([failure, success], "50", 1)
            mutated = script.replace('select(.conclusion == "success")', 'select(true)', 1)
            runs.write_text(json.dumps({"workflow_runs": [failure, success]}), encoding="utf-8")
            self.assertEqual(run("/bin/bash", "-c", mutated, cwd=ROOT, env=env).returncode, 0)
            runs.write_text(json.dumps({"workflow_runs": [failure]}), encoding="utf-8")
            self.assertNotEqual(run("/bin/bash", "-c", script, cwd=ROOT, env=env).returncode, 0)

    def test_merged_dependency_does_not_dispatch_a_duplicate_build(self) -> None:
        workflow = (ROOT / ".github/workflows/dependency_updates.yml").read_text(encoding="utf-8")
        query, dispatch = 'actions/runs?head_sha=${merge_sha}&event=push&per_page=20', "timeout 60 gh workflow run build_and_deploy.yml"
        self.assertIn(query, workflow)
        self.assertIn(dispatch, workflow)
        self.assertLess(workflow.index(query), workflow.index(dispatch))
        self.assertIn(".github/workflows/validate.yml", workflow)
        self.assertIn("reported a change but no tracked file changed", workflow)
        for expected in ("refusing unexpected dependency path", "production_audit:", "verify-production"): self.assertIn(expected, workflow)
        self.assertIn("verify_vaultwarden_release()", (ROOT / "scripts/ci/deps.sh").read_text(encoding="utf-8"))
        build = (ROOT / ".github/workflows/build_and_deploy.yml").read_text(encoding="utf-8")
        self.assertIn("for platform in linux/amd64 linux/arm64", build)
        self.assertIn(r"^sha256:[0-9a-f]{64}$", build)
        self.assertIn("DOCKER_BUILD_RECORD_UPLOAD: false", build)
        self.assertIn('[.workflow_runs[] | select(.conclusion == "success")][0].created_at // empty', build)
        failure_gate = "github.event_name == 'workflow_run' && github.event.workflow_run.conclusion != 'success'"
        self.assertIn(failure_gate, workflow)
        maintenance = (ROOT / ".github/workflows/ghcr_cleanup.yml").read_text(encoding="utf-8")
        self.assertIn("runs?event=schedule&per_page=20", maintenance)
        self.assertEqual(("runs?per_page=20" in maintenance, "runs?per_page=20" in maintenance.replace("event=schedule&", "", 1)), (False, True))
        for expected in (
            "dependency_watchdog:",
            "actions: write",
            'select(.status == "queued" or .status == "in_progress")',
            "MAX_AGE_SECONDS: 21600",
            "gh workflow run dependency_updates.yml",
            "Remove stale Actions artifacts and build caches",
            "actions/caches/",
        ):
            self.assertIn(expected, maintenance)

    def test_scheduled_automation_skips_idle_rebuilds_and_closes_stale_bots(self) -> None:
        build = (ROOT / ".github/workflows/build_and_deploy.yml").read_text(encoding="utf-8")
        preflight = workflow_step_script(build, "Decide whether a scheduled rebuild is needed")
        self.assertTrue("needs: rebuild_check" in build and "needs.rebuild_check.outputs.needed == 'true'" in build)
        with tempfile.TemporaryDirectory() as temporary:
            root, binary = Path(temporary), Path(temporary) / "bin"; binary.mkdir()
            output, packages = root / "output", root / "packages"
            write_executable(binary / "timeout", '#!/bin/sh\nshift 3\nexec "$@"\n')
            write_executable(binary / "docker", '#!/bin/sh\ncat "$PACKAGE_FIXTURE"\n')
            env = os.environ | {"PATH": f"{binary}:{os.environ['PATH']}", "GITHUB_EVENT_NAME": "schedule", "GITHUB_OUTPUT": str(output), "REGISTRY": "ghcr.io", "IMAGE_NAME": "owner/repository", "PACKAGE_FIXTURE": str(packages)}
            for fixture, needed in (("", "false"), ("zlib 1.0-r0 1.0-r1\n", "true")):
                with self.subTest(packages=needed):
                    output.write_text("", encoding="utf-8"); packages.write_text(fixture, encoding="utf-8")
                    result = run("/bin/bash", "-c", preflight, cwd=ROOT, env=env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f"needed={needed}", output.read_text(encoding="utf-8"))
            write_executable(binary / "docker", "#!/bin/sh\nexit 1\n")
            self.assertNotEqual(run("/bin/bash", "-c", preflight, cwd=ROOT, env=env).returncode, 0)
        dependencies = (ROOT / ".github/workflows/dependency_updates.yml").read_text(encoding="utf-8")
        cleanup = workflow_step_script(dependencies, "Close stale automated pull requests")
        with tempfile.TemporaryDirectory() as temporary:
            root, binary = Path(temporary), Path(temporary) / "bin"; binary.mkdir()
            fixture, actions = root / "pulls.json", root / "actions"
            rows = ((101, "dependabot[bot]", "dependabot/actions", "2020-01-01T00:00:00Z"), (102, "github-actions[bot]", "deps/upstream", "2020-01-01T00:00:00Z"), (103, "github-actions[bot]", "release/notes", "2020-01-01T00:00:00Z"), (104, "human", "dependabot/human", "2020-01-01T00:00:00Z"), (105, "dependabot[bot]", "dependabot/fresh", "2999-01-01T00:00:00Z"))
            fixture.write_text(json.dumps([[{"number": n, "user": {"login": user}, "head": {"ref": ref}, "updated_at": updated} for n, user, ref, updated in rows]]), encoding="utf-8")
            write_executable(binary / "timeout", '#!/bin/sh\nshift\nexec "$@"\n')
            write_executable(binary / "gh", '#!/bin/sh\ncase "$1 $2" in "api --paginate") cat "$PR_FIXTURE" ;; "pr comment"|"pr close") printf "%s\\n" "$*" >> "$PR_ACTIONS" ;; *) exit 2 ;; esac\n')
            env = os.environ | {"PATH": f"{binary}:{os.environ['PATH']}", "GITHUB_REPOSITORY": "owner/repository", "PR_FIXTURE": str(fixture), "PR_ACTIONS": str(actions), "MAX_AGE_SECONDS": "2592000"}
            result = run("/bin/bash", "-c", cleanup, cwd=ROOT, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            cleanup_log = actions.read_text(encoding="utf-8")
            self.assertIn("comment 101", cleanup_log); self.assertIn("close 102", cleanup_log)
            self.assertNotRegex(cleanup_log, r"\b(?:comment|close) 10[345]\b")
            actions.unlink(); weaken = cleanup.replace('| select((.head.ref | startswith("dependabot/")) or .head.ref == "deps/upstream")', "", 1)
            self.assertEqual(run("/bin/bash", "-c", weaken, cwd=ROOT, env=env).returncode, 0)
            self.assertIn("close 103", actions.read_text(encoding="utf-8"))

    def test_cleanup_executes_only_stale_build_assets(self) -> None:
        workflow = (ROOT / ".github/workflows/ghcr_cleanup.yml").read_text(encoding="utf-8")
        script = workflow_step_script(workflow, "Remove stale Actions artifacts and build caches")
        with tempfile.TemporaryDirectory() as temporary:
            root, binary = Path(temporary), Path(temporary) / "bin"; binary.mkdir()
            artifacts, caches, deletes = root / "artifacts.json", root / "caches.json", root / "deletes"
            rows = ((11, "2026-10-20T00:00:00Z", False, "old.dockerbuild"), (12, "2026-10-28T00:00:00Z", True, "expired.dockerbuild"), (13, "2026-10-28T00:00:00Z", False, "fresh.dockerbuild"), (14, "2026-10-20T00:00:00Z", False, "report.zip"))
            artifacts.write_text(json.dumps({"artifacts": [{"id": i, "created_at": at, "expired": expired, "name": name} for i, at, expired, name in rows]}), encoding="utf-8")
            rows = ((21, "2026-10-20T00:00:00Z", "buildkit-old"), (22, "2026-10-28T00:00:00Z", "buildkit-fresh"), (23, "2026-10-20T00:00:00Z", "index-buildkit-old"), (24, "2026-10-20T00:00:00Z", "python-old"))
            caches.write_text(json.dumps({"actions_caches": [{"id": i, "last_accessed_at": at, "key": key} for i, at, key in rows]}), encoding="utf-8")
            write_executable(binary / "date", "#!/bin/sh\nprintf '2026-10-24T00:00:00Z\\n'\n")
            write_executable(binary / "timeout", "#!/bin/sh\nshift\nexec \"$@\"\n")
            write_executable(binary / "gh", r"""#!/bin/sh
case "$*" in
  *actions/artifacts?per_page=100*) cat "$ARTIFACTS_FIXTURE" ;;
  *actions/caches?per_page=100*) cat "$CACHES_FIXTURE" ;;
  *--method\ DELETE*actions/artifacts/*) printf 'artifact=%s\\n' "${4##*/}" >> "$DELETE_LOG" ;;
  *--method\ DELETE*actions/caches/*) printf 'cache=%s\\n' "${4##*/}" >> "$DELETE_LOG" ;;
  *) exit 2 ;;
esac
""")
            env = os.environ | {"GITHUB_REPOSITORY": "owner/repository", "PATH": f"{binary}:{os.environ['PATH']}", "ARTIFACTS_FIXTURE": str(artifacts), "CACHES_FIXTURE": str(caches), "DELETE_LOG": str(deletes)}
            result = run("/bin/bash", "-c", script, cwd=ROOT, env=env); self.assertEqual(result.returncode, 0, result.stderr)
            removed = deletes.read_text(encoding="utf-8")
            for expected in ("artifact=11", "artifact=12", "artifact=13", "cache=21", "cache=23"): self.assertIn(expected, removed)
            for kept in ("artifact=14", "cache=22", "cache=24"): self.assertNotIn(kept, removed)
            artifacts.write_text(json.dumps({"artifacts": [{"id": "invalid", "created_at": "2026-10-20T00:00:00Z", "expired": False, "name": "bad.dockerbuild"}]}), encoding="utf-8")
            deletes.unlink(); self.assertNotEqual(run("/bin/bash", "-c", script, cwd=ROOT, env=env).returncode, 0)
            self.assertFalse(deletes.exists())

    def test_published_manifest_and_digest_are_strict(self) -> None:
        workflow = (ROOT / ".github/workflows/build_and_deploy.yml").read_text(encoding="utf-8")
        manifest = workflow_step_script(workflow, "Verify the multi-arch manifest")
        digest = workflow_step_script(workflow, "Record the published amd64 digest")
        dependency_workflow = (ROOT / ".github/workflows/dependency_updates.yml").read_text(encoding="utf-8")
        audit_image = workflow_step_script(dependency_workflow, "Resolve the latest published amd64 image")
        with tempfile.TemporaryDirectory() as temporary:
            root, binary = Path(temporary), Path(temporary) / "bin"; binary.mkdir(); output = root / "output"
            write_executable(binary / "timeout", "#!/bin/sh\nshift\nexec \"$@\"\n")
            write_executable(binary / "docker", "#!/bin/sh\nprintf '%s\\n' \"$DOCKER_OUTPUT\"\n")
            env = os.environ | {"REGISTRY": "ghcr.io", "IMAGE_NAME": "owner/repository", "TIMESTAMP_TAG": "202610300615", "GITHUB_OUTPUT": str(output), "PATH": f"{binary}:{os.environ['PATH']}"}
            expected = "sha256:" + "a" * 64
            commands = {"manifest": manifest, "digest": digest, "audit": audit_image}
            for name, value, passed, wanted in (("manifest", "linux/amd64\nlinux/arm64", True, ""), ("manifest", "linux/amd64", False, ""), ("digest", expected, True, f"digest={expected}"), ("digest", "sha256:short", False, ""), ("audit", expected, True, f"image=ghcr.io/owner/repository@{expected}"), ("audit", "sha256:short", False, "")):
                with self.subTest(command=name, value=value):
                    output.write_text("", encoding="utf-8"); env["DOCKER_OUTPUT"] = value
                    result = run("/bin/bash", "-c", commands[name], cwd=ROOT, env=env)
                    self.assertEqual(result.returncode == 0, passed, result.stderr)
                    self.assertEqual(output.read_text(encoding="utf-8"), f"{wanted}\n" if wanted else "")

    def test_latest_is_promoted_only_after_runtime_verification(self) -> None:
        workflow = (ROOT / ".github/workflows/build_and_deploy.yml").read_text(encoding="utf-8")
        metadata = workflow.split("- name: Extract Docker metadata", 1)[1].split("- name: Verify timestamp tag", 1)[0]
        self.assertNotIn("type=raw,value=latest", metadata)
        steps = ("Build and push multi-arch image", "Runtime smoke test the published image", "Promote the verified image to latest")
        self.assertEqual([workflow.index(f"- name: {name}") for name in steps], sorted(workflow.index(f"- name: {name}") for name in steps))
        promote = workflow_step_script(workflow, "Promote the verified image to latest")
        self.assertIn('--tag "${image}:latest" "${image}@${index_digest}"', promote)
        guard = 'if [ "$latest_index" != "$index_digest" ] || [ "$latest_amd64" != "$AMD64_DIGEST" ]; then'
        block = promote[promote.index(guard):promote.index("\nfi\n", promote.index(guard)) + 4]
        source = "sha256:" + "b" * 64
        env = os.environ | {"LATEST_INDEX": source, "LATEST_AMD64": DIGEST}
        script = f'index_digest={source}; AMD64_DIGEST={DIGEST}; latest_index=$LATEST_INDEX; latest_amd64=$LATEST_AMD64\n' + block
        self.assertEqual(run("/bin/bash", "-c", script, env=env).returncode, 0)
        for key, value in (("LATEST_INDEX", "sha256:" + "c" * 64), ("LATEST_AMD64", "sha256:" + "d" * 64)):
            self.assertNotEqual(run("/bin/bash", "-c", script, env=env | {key: value}).returncode, 0)
        mutated = script.replace(guard, "if false; then", 1)
        self.assertEqual(run("/bin/bash", "-c", mutated, env=env | {"LATEST_INDEX": "sha256:" + "c" * 64}).returncode, 0)

    def test_runtime_shell_retries_only_interrupted_attempts(self) -> None:
        started, ended, passed = "__runtime_smoke_started__", "__runtime_smoke_ended__=", "__runtime_smoke_passed__"
        failed_assertion = subprocess.CompletedProcess([], 1, f"{started}\n{ended}2\nassertion failed\n", "")
        started_case = subprocess.CompletedProcess([], 0, f"{started}\n{ended}0\n{passed}\n", "")
        interrupted_container, clean_exit_without_markers = subprocess.CompletedProcess([], 1, f"{started}\n", ""), subprocess.CompletedProcess([], 0, "", "")

        def run_case(*results: subprocess.CompletedProcess[str]) -> tuple[mock.Mock, mock.Mock]:
            suite = mock.Mock()
            with mock.patch.object(runtime_smoke, "docker", side_effect=results) as docker_mock, mock.patch.object(runtime_smoke, "suite", suite), mock.patch("sys.stderr", io.StringIO()):
                runtime_smoke.expect_shell("image", "true", "accepted", "rejected")
            return suite, docker_mock

        suite, docker_mock = run_case(interrupted_container, started_case)
        self.assertEqual(docker_mock.call_count, 2); suite.ok.assert_called_once_with("accepted")
        suite.bad.assert_not_called()
        suite, docker_mock = run_case(failed_assertion)
        self.assertEqual(docker_mock.call_count, 1); suite.ok.assert_not_called()
        suite.bad.assert_called_once_with("rejected")
        suite, docker_mock = run_case(*(interrupted_container,) * 3)
        self.assertEqual(docker_mock.call_count, 3); suite.ok.assert_not_called()
        suite.bad.assert_called_once_with("rejected: shell case was interrupted after 3 attempts")
        suite, docker_mock = run_case(clean_exit_without_markers)
        self.assertEqual(docker_mock.call_count, 1); suite.ok.assert_not_called()
        suite.bad.assert_called_once_with("rejected: shell case exited without lifecycle markers")

    def test_runtime_files_have_one_process_model_and_static_ranges(self) -> None:
        service = (ROOT / "scripts/container/services.sh").read_text(encoding="utf-8")
        for command in ("/vaultwarden", "caddy run --config /Caddyfile", "supercronic /crontab"): self.assertIn(command, service)
        entrypoint = (ROOT / "scripts/container/entrypoint.sh").read_text(encoding="utf-8")
        for module in ("filesystem", "config", "restore", "smtp"): self.assertIn(f"/entrypoint/{module}.sh", entrypoint)
        runtime = "\n".join(
            (ROOT / path).read_text(encoding="utf-8")
            for path in ("Dockerfile", "scripts/container/services.sh", "scripts/container/entrypoint.sh")
        )
        for forbidden in ("overmind", "tmux", "Procfile", "supervise.sh"): self.assertNotIn(forbidden, runtime)

    def test_script_boundary_mutation_detects_ci_copy(self) -> None:
        dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
        dockerignore = (ROOT / ".dockerignore").read_text(encoding="utf-8")
        self.assertEqual(script_boundary_errors(dockerfile, dockerignore), [])
        container = {"entrypoint", "entrypoint.sh", "restic.sh", "services.sh"}
        ci = {"cloudflare_ranges.py", "deps.sh", "validate_action_pin_update.py"}
        self.assertEqual({path.name for path in (ROOT / "scripts/container").iterdir()}, container)
        self.assertEqual({path.name for path in (ROOT / "scripts/ci").iterdir()}, ci)
        self.assertFalse(any(path.is_file() for path in (ROOT / "scripts").iterdir()))
        mutated = dockerfile.replace("scripts/container/restic.sh", "scripts/ci/deps.sh", 1)
        self.assertIn("CI-only scripts", "; ".join(script_boundary_errors(mutated, dockerignore)))
        self.assertIn("does not exclude", "; ".join(script_boundary_errors(dockerfile, dockerignore.replace("scripts/ci\n", "", 1))))

    def test_scripts_wrap_network_calls_and_avoid_nonportable_find(self) -> None:
        scripts = list((ROOT / "scripts").rglob("*.sh"))
        contents = {path: path.read_text(encoding="utf-8") for path in scripts}
        self.assertFalse(any("-printf" in body for body in contents.values()))
        calls = bounded = 0
        for body in contents.values():
            lines = body.splitlines()
            for index, line in enumerate(lines):
                if not line.lstrip().startswith("curl "):
                    continue
                calls += 1
                block = "\n".join(lines[index:index + 5])
                bounded += any(flag in block for flag in ("--max-time", " -m "))
        self.assertGreater(calls, 0); self.assertEqual(calls, bounded)
        deps = (ROOT / "scripts/ci/deps.sh").read_text(encoding="utf-8")
        for expected in ('timeout -k 2 "$GH_TIMEOUT" gh api', 'gtimeout -k 2 "$GH_TIMEOUT" gh api', 'timeout -k 5 "$DOCKER_TIMEOUT" docker "$@"', 'gtimeout -k 5 "$DOCKER_TIMEOUT" docker "$@"', 'rows="$(docker_bounded run --rm'): self.assertIn(expected, deps)
        self.assertNotIn('\n        gh api "$@"', deps)

    def test_recurring_regressions_stay_documented(self) -> None:
        restic = (ROOT / "scripts/container/restic.sh").read_text(encoding="utf-8")
        start = restic.index("log() {")
        block = restic[start:restic.index("\n}\n", start) + 3]
        post_trim_guard = (
            "    if ! trim_logs; then\n"
            '        CURRENT_STEP="Log directory limits cannot be enforced after backup"; echo "Error: cannot enforce log limits after backup" >&2\n'
            "        exit 2\n"
            "    fi"
        )

        self.assertIn('tail -c "$MAX_LOG_BYTES"', block)
        self.assertIn("write_log_entry", block)
        self.assertNotIn('body="$("$@" 2>&1)"', block)
        self.assertNotIn("eval ", restic)
        self.assertEqual(restic.count(post_trim_guard), 1)
        self.assertNotIn('trim_logs || warning=" (log trim failed)"', restic)
        with self.assertRaises(AssertionError):
            self.assertEqual(restic.replace(post_trim_guard, "    trim_logs || :", 1).count(post_trim_guard), 1)
        decisions = (ROOT / "docs/recurring_issues.md").read_text(encoding="utf-8")
        assert_recurrence_contract(self, decisions)
        for section in ("Bounded Diagnostics", "Outbound Network Bounds", "Status writes are atomic or fail without truncating", "Runtime Harness Lifecycle", "Absence of a supported timeout command fails closed", "Documentation-only commits stay outside production builds", "Simplification Rule"): self.assertIn(section, decisions)
        self.assertNotIn('printf \'%s\' "$body" > "$STATUS_FILE"', restic)
        self.assertIn("refusing to create a new log", restic)
        self.assertIn("docs/recurring_issues.md", (ROOT / "README.md").read_text(encoding="utf-8"))

    def test_security_randomness_uses_operating_system_entropy(self) -> None:
        production = "\n".join(path.read_text(encoding="utf-8") for path in (*sorted((ROOT / "scripts").rglob("*.sh")), ROOT / "scripts/ci/cloudflare_ranges.py"))
        forbidden = re.compile(r"\$RANDOM|random\.(?:random|randint|randrange|choice|choices)|uuid\.uuid1|openssl\s+rand")
        self.assertIsNone(forbidden.search(production))
        performance = (ROOT / "tests/performance.py").read_text(encoding="utf-8")
        self.assertIn("secrets.token_hex", performance)
        self.assertNotRegex(performance, r"uuid\.uuid1|random\.(?:random|randint|randrange)")

    def test_env_docs_and_secret_placeholders_stay_aligned(self) -> None:
        example = (ROOT / ".env.example").read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        tuning = {"BACKUP_MAX_AGE", "BACKUP_MAX_USAGE_PERCENT", "RESTIC_LOG_DIR", "RESTIC_LOG_MAX_BYTES", "RESTIC_LOG_DIR_MAX_BYTES", "RESTIC_QUICK_TIMEOUT", "RESTIC_LONG_TIMEOUT", "VERIFY_SUBSET", "VERIFY_RETRY_LOCK", "SUPERVISE_RESTART_DELAY"}
        for name in tuning: self.assertIn(f"{name}=", example); self.assertIn(name, readme)
        for required in ("RESTORE_CONFIRM=yes", "restore-pending", "config.json", "runtime_smoke.py"): self.assertIn(required, readme)
        for path in tracked_files():
            if not path.is_file() or path.suffix in {".png", ".jpg", ".gif"}:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            self.assertEqual(scan_for_sensitive_data(text), [], f"sensitive value in {path.relative_to(ROOT)}")

    def test_quality_budgets_do_not_regress(self) -> None:
        budgets = {"README.md": 150, ".env.example": 48, "scripts/container/restic.sh": 520, "scripts/ci/cloudflare_ranges.py": 200, "scripts/ci/validate_action_pin_update.py": 140}
        for path, limit in budgets.items():
            with self.subTest(path=path):
                lines = len((ROOT / path).read_text(encoding="utf-8").splitlines())
                self.assertLessEqual(lines, limit, f"{path} grew to {lines} lines")
        test_files = [path for path in (ROOT / "tests").iterdir() if path.is_file()]
        test_lines = sum(len(path.read_text(encoding="utf-8").splitlines()) for path in test_files)
        self.assertLessEqual(test_lines, 4830, f"tests grew to {test_lines} lines")
        for removed in ("selftest.sh", "image_selftest.sh", "lib.sh"): self.assertFalse((ROOT / "tests" / removed).exists())

    def test_access_logs_remove_referrer_and_query_values(self) -> None:
        caddy = (ROOT / "config/Caddyfile").read_text(encoding="utf-8")
        self.assertIn("request>headers>Referer delete", caddy)
        self.assertIn('request>uri regexp "\\?.*$" "?redacted"', caddy)

    def test_files_are_executable_only_when_they_are_commands(self) -> None:
        for path in tracked_files():
            mode = path.stat().st_mode
            script_roots = (ROOT / "scripts", ROOT / "tests")
            if path.suffix == ".sh" and any(path.is_relative_to(root) for root in script_roots) and path.name != "lib.sh":
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
