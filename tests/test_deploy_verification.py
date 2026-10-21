#!/usr/bin/env python3
"""Execute the deployment verifier against a controlled Fly API response."""

from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
from typing import Any
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = Path(".github/workflows/build_and_deploy.yml")
EXPECTED_IMAGE = "ghcr.io/example/image@sha256:" + "a" * 64
SENSITIVE_FLY_OUTPUT = """\
Machine ID: 1234567890abcdef
machine config for fedcba0987654321
lease for abcdef1234567890 acquired
> Updating 234567890abcdef1 [app]
{"MachineID":"0123456789abcdef"}
private fdaa:0:1234::5678 address
Image ID: img_01JABCDEFGH1234567890
app_01JABCDEFGH1234567890
vol_01JABCDEFGH1234567890
"""
SAFE_FLY_DIAGNOSTIC = "deployment failed: upstream unavailable"


def extract_step(step_id: str) -> str:
    """Return a real workflow step body so tests exercise shipped behavior."""
    ruby = """
      require "yaml"
      doc = YAML.load_file(ARGV.fetch(0))
      steps = doc.dig("jobs", "deploy", "steps") || []
      step = steps.find { |item| item["id"] == ARGV.fetch(1) }
      abort "#{ARGV.fetch(1)} step is missing" if step.nil?
      body = step["run"].to_s
      abort "#{ARGV.fetch(1)} step has no run body" if body.empty?
      print body
    """
    result = subprocess.run(
        ["ruby", "-ryaml", "-e", ruby, str(WORKFLOW), step_id],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr.strip() or "could not extract workflow step")
    return result.stdout


def extract_verifier() -> str:
    return extract_step("verify")


def extract_release() -> str:
    return extract_step("release")


def workflow_environment() -> dict[str, str]:
    ruby = """
      require "json"
      require "yaml"
      doc = YAML.load_file(ARGV.fetch(0))
      print JSON.generate(doc["env"] || {})
    """
    result = subprocess.run(
        ["ruby", "-ryaml", "-e", ruby, str(WORKFLOW)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr.strip() or "could not read workflow env")
    return json.loads(result.stdout)


def write_fake_flyctl(directory: Path) -> None:
    path = directory / "flyctl"
    path.write_text(
        """#!/usr/bin/env python3
import os
from pathlib import Path
import sys

command = next((arg for arg in sys.argv[1:] if not arg.startswith("-")), "")
name = {"releases": "FLY_RELEASES", "status": "FLY_STATUS"}.get(command)
if name is None:
    print(f"unexpected flyctl command: {sys.argv[1:]}", file=sys.stderr)
    raise SystemExit(2)
if os.environ.get(f"{name}_EXIT") == "1":
    print(f"{command} API unavailable", file=sys.stderr)
    raise SystemExit(1)

sequence = os.environ.get(f"{name}_SEQUENCE")
if sequence is None:
    print(os.environ[f"{name}_JSON"])
else:
    state = Path(os.environ["FLY_STATE_DIR"])
    counter = state / f"{command}.count"
    index = int(counter.read_text()) if counter.exists() else 0
    values = sequence.splitlines()
    print(values[min(index, len(values) - 1)])
    counter.write_text(str(index + 1))
""",
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run_release(
    *,
    fly_stdout: str = "",
    fly_stderr: str = "",
    fly_exit: int = 0,
) -> subprocess.CompletedProcess[str]:
    body = extract_release()
    body = body.replace("${{ env.REGISTRY }}", "ghcr.io")
    body = body.replace("${{ env.IMAGE_NAME }}", "example/image")
    body = body.replace("${{ needs.build.outputs.digest }}", "sha256:" + "a" * 64)

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        flyctl = bin_dir / "flyctl"
        flyctl.write_text(
            """#!/bin/sh
printf '%s' "$FLY_STDOUT"
printf '%s' "$FLY_STDERR" >&2
exit "$FLY_EXIT"
""",
            encoding="utf-8",
        )
        flyctl.chmod(flyctl.stat().st_mode | stat.S_IXUSR)
        release = root / "release.sh"
        release.write_text(body, encoding="utf-8")

        environment = os.environ.copy()
        environment.update(
            {
                "FLY_API_TOKEN": "test-token",
                "FLY_APP": "test-app",
                "FLY_EXIT": str(fly_exit),
                "FLY_STDERR": fly_stderr,
                "FLY_STDOUT": fly_stdout,
                "PATH": f"{bin_dir}:{environment['PATH']}",
            }
        )
        environment.update(workflow_environment())
        return subprocess.run(
            ["bash", str(release)],
            cwd=REPO_ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )


def healthy_responses() -> tuple[list[dict[str, Any]], dict[str, Any]]:
    digest = EXPECTED_IMAGE.rsplit("@", 1)[1]
    releases: list[dict[str, Any]] = [
        {
            "ImageRef": EXPECTED_IMAGE,
            "InProgress": False,
            "Status": "complete",
            "Version": 42,
        }
    ]
    status: dict[str, Any] = {
        "Status": "deployed",
        "Machines": [
            {
                "checks": {"alive": {"status": "passing"}},
                "host_status": "ok",
                "image_ref": {
                    "digest": digest,
                    "registry": "ghcr.io",
                    "repository": "example/image",
                },
                "state": "started",
            }
        ]
    }
    return releases, status


def run_verifier(
    releases: list[dict[str, Any]],
    status: dict[str, Any],
    *,
    release_sequence: list[list[dict[str, Any]]] | None = None,
    release_exit: bool = False,
    timeout_seconds: int = 0,
) -> subprocess.CompletedProcess[str]:
    body = extract_verifier()

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        bin_dir = root / "bin"
        state_dir = root / "state"
        bin_dir.mkdir()
        state_dir.mkdir()
        write_fake_flyctl(bin_dir)
        verifier = root / "verify.sh"
        verifier.write_text(body, encoding="utf-8")

        environment = os.environ.copy()
        environment.update(
            {
                "DEPLOY_VERIFY_POLL_SECONDS": "1",
                "DEPLOY_VERIFY_TIMEOUT_SECONDS": str(timeout_seconds),
                "EXPECTED_IMAGE": EXPECTED_IMAGE,
                "FLY_API_TOKEN": "test-token",
                "FLY_APP": "test-app",
                "FLY_RELEASES_JSON": json.dumps(releases),
                "FLY_STATUS_JSON": json.dumps(status),
                "FLY_STATE_DIR": str(state_dir),
                "PATH": f"{bin_dir}:{environment['PATH']}",
            }
        )
        if release_sequence is not None:
            environment["FLY_RELEASES_SEQUENCE"] = "\n".join(
                json.dumps(item) for item in release_sequence
            )
        if release_exit:
            environment["FLY_RELEASES_EXIT"] = "1"
        return subprocess.run(
            ["bash", str(verifier)],
            cwd=REPO_ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )


class DeploymentVerificationTest(unittest.TestCase):
    def assert_release_output_is_redacted(
        self, result: subprocess.CompletedProcess[str]
    ) -> None:
        output = result.stderr + result.stdout
        for value in (
            "1234567890abcdef",
            "fedcba0987654321",
            "abcdef1234567890",
            "234567890abcdef1",
            "0123456789abcdef",
            "fdaa:0:1234::5678",
            "img_01JABCDEFGH1234567890",
            "app_01JABCDEFGH1234567890",
            "vol_01JABCDEFGH1234567890",
        ):
            self.assertNotIn(value, output)
        for marker in (
            "[redacted-fly-machine-id]",
            "[redacted-fly-private-ipv6]",
            "[redacted-fly-image-id]",
            "[redacted-fly-id]",
        ):
            self.assertIn(marker, output)
        self.assertIn(SAFE_FLY_DIAGNOSTIC, output)

    def test_release_output_is_redacted(self) -> None:
        result = run_release(
            fly_stdout=SENSITIVE_FLY_OUTPUT,
            fly_stderr=SAFE_FLY_DIAGNOSTIC + "\n",
        )

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assert_release_output_is_redacted(result)

    def test_release_preserves_flyctl_exit_status(self) -> None:
        result = run_release(
            fly_stdout=SENSITIVE_FLY_OUTPUT,
            fly_stderr=SAFE_FLY_DIAGNOSTIC + "\n",
            fly_exit=23,
        )

        self.assertEqual(result.returncode, 23)
        self.assert_release_output_is_redacted(result)

    def test_verified_release_is_accepted(self) -> None:
        releases, status = healthy_responses()
        result = run_verifier(releases, status)

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("deployment verified", result.stdout)

    def test_unhealthy_or_wrong_deployment_is_rejected(self) -> None:
        mutations = {
            "release still in progress": (
                lambda releases, status: releases[0].update(InProgress=True)
            ),
            "release failed": (
                lambda releases, status: releases[0].update(Status="failed")
            ),
            "wrong release digest": (
                lambda releases, status: releases[0].update(
                    ImageRef="ghcr.io/example/image@sha256:" + "b" * 64
                )
            ),
            "application not deployed": (
                lambda releases, status: status.update(Status="suspended")
            ),
            "machine stopped": (
                lambda releases, status: status["Machines"][0].update(state="stopped")
            ),
            "machine host unhealthy": (
                lambda releases, status: status["Machines"][0].update(
                    host_status="error"
                )
            ),
            "wrong machine digest": (
                lambda releases, status: status["Machines"][0]["image_ref"].update(
                    digest="sha256:" + "b" * 64
                )
            ),
            "no health checks": (
                lambda releases, status: status["Machines"][0].update(checks={})
            ),
            "failing health check": (
                lambda releases, status: status["Machines"][0]["checks"]["alive"].update(
                    status="critical"
                )
            ),
        }

        for name, mutate in mutations.items():
            with self.subTest(name=name):
                releases, status = healthy_responses()
                mutate(releases, status)
                result = run_verifier(releases, status)
                self.assertNotEqual(result.returncode, 0, name)
                self.assertIn(
                    "deployment verification failed",
                    result.stderr + result.stdout,
                )

    def test_api_failure_is_rejected(self) -> None:
        releases, status = healthy_responses()
        result = run_verifier(releases, status, release_exit=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deployment verification failed", result.stderr + result.stdout)

    def test_incomplete_release_is_polled(self) -> None:
        releases, status = healthy_responses()
        incomplete = [dict(releases[0], InProgress=True)]
        result = run_verifier(
            releases,
            status,
            release_sequence=[incomplete, releases],
            timeout_seconds=2,
        )

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("deployment verified", result.stdout)


if __name__ == "__main__":
    unittest.main()
