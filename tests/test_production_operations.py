#!/usr/bin/env python3
"""Exercise the fixed production operation dispatch without touching Fly."""

from __future__ import annotations

import os
from pathlib import Path
import json
import stat
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = Path(".github/workflows/dependency_updates.yml")
EXPECTED_OPTIONS = {
    "none",
    "audit",
    "check-freshness",
    "snapshots",
    "verify",
    "restore-test",
    "backup",
}
EXPECTED_COMMANDS = {
    "audit": "/restic.sh audit",
    "check-freshness": "/restic.sh check-freshness",
    "snapshots": "/restic.sh snapshots",
    "verify": "/restic.sh verify",
    "restore-test": "/restic.sh restore-test",
    "backup": "/restic.sh backup",
}
SENSITIVE_FLY_OUTPUT = """\
Machine ID: 1234567890abcdef
machine config for fedcba0987654321
lease for abcdef1234567890 acquired
{"MachineID":"0123456789abcdef"}
private fdaa:0:1234::5678 address
Image ID: img_01JABCDEFGH1234567890
app_01JABCDEFGH1234567890
vol_01JABCDEFGH1234567890
"""
SAFE_FLY_DIAGNOSTIC = "network policy rejected the request"


def load_workflow() -> dict[str, object]:
    ruby = """
      require "json"
      require "yaml"
      print JSON.generate(YAML.load_file(ARGV.fetch(0)))
    """
    result = subprocess.run(
        ["ruby", "-e", ruby, str(WORKFLOW)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr.strip() or "could not parse workflow")
    return json.loads(result.stdout)


def dispatch_inputs(workflow: dict[str, object]) -> dict[str, object]:
    event_config = workflow.get("on", workflow.get("true"))
    if not isinstance(event_config, dict):
        raise AssertionError("workflow dispatch event is missing")
    dispatch = event_config.get("workflow_dispatch")
    if not isinstance(dispatch, dict):
        raise AssertionError("workflow_dispatch is missing")
    inputs = dispatch.get("inputs")
    if not isinstance(inputs, dict):
        raise AssertionError("workflow_dispatch inputs are missing")
    return inputs


def operation_body(workflow: dict[str, object]) -> str:
    jobs = workflow.get("jobs")
    if not isinstance(jobs, dict):
        raise AssertionError("workflow jobs are missing")
    job = jobs.get("production_operation")
    if not isinstance(job, dict):
        raise AssertionError("production_operation job is missing")
    steps = job.get("steps")
    if not isinstance(steps, list):
        raise AssertionError("production_operation steps are missing")
    step = next(
        (item for item in steps if isinstance(item, dict) and item.get("id") == "operation"),
        None,
    )
    if not isinstance(step, dict) or not isinstance(step.get("run"), str):
        raise AssertionError("fixed operation step is missing")
    return step["run"]


def watchdog_body(workflow: dict[str, object]) -> str:
    jobs = workflow.get("jobs")
    if not isinstance(jobs, dict):
        raise AssertionError("workflow jobs are missing")
    job = jobs.get("watchdog")
    if not isinstance(job, dict):
        raise AssertionError("watchdog job is missing")
    steps = job.get("steps")
    if not isinstance(steps, list):
        raise AssertionError("watchdog steps are missing")
    step = next(
        (
            item
            for item in steps
            if isinstance(item, dict)
            and "/restic.sh check-freshness" in str(item.get("run", ""))
        ),
        None,
    )
    if not isinstance(step, dict) or not isinstance(step.get("run"), str):
        raise AssertionError("watchdog heartbeat step is missing")
    return step["run"]


def write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run_operation(
    body: str,
    operation: str,
    *,
    workflow_env: dict[str, str] | None = None,
    fly_stdout: str = "",
    fly_stderr: str = "",
    fly_exit: int = 0,
) -> tuple[subprocess.CompletedProcess[str], str]:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        args_file = root / "fly-args"

        write_executable(
            bin_dir / "timeout",
            """#!/bin/sh
shift
exec "$@"
""",
        )
        write_executable(
            bin_dir / "flyctl",
            """#!/bin/sh
printf '%s\n' "$*" > "$FLY_ARGS_FILE"
printf '%s' "$FLY_STDOUT"
printf '%s' "$FLY_STDERR" >&2
exit "$FLY_EXIT"
""",
        )
        script = root / "operation.sh"
        script.write_text(body, encoding="utf-8")

        environment = os.environ.copy()
        environment.update(
            {
                "FLY_API_TOKEN": "token-must-not-be-printed",
                "FLY_APP": "test-app",
                "FLY_ARGS_FILE": str(args_file),
                "FLY_EXIT": str(fly_exit),
                "FLY_STDERR": fly_stderr,
                "FLY_STDOUT": fly_stdout,
                "OPERATION": operation,
                "PATH": f"{bin_dir}:{environment['PATH']}",
            }
        )
        if workflow_env:
            environment.update(workflow_env)
        result = subprocess.run(
            ["bash", str(script)],
            cwd=REPO_ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        args = args_file.read_text(encoding="utf-8").strip() if args_file.exists() else ""
        return result, args


class ProductionOperationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = load_workflow()
        cls.body = operation_body(cls.workflow)
        cls.watchdog_body = watchdog_body(cls.workflow)
        cls.workflow_env = cls.workflow.get("env")
        if not isinstance(cls.workflow_env, dict):
            raise AssertionError("workflow environment is missing")

    def assert_fly_output_is_redacted(
        self, result: subprocess.CompletedProcess[str]
    ) -> None:
        output = result.stderr + result.stdout
        for value in (
            "1234567890abcdef",
            "fedcba0987654321",
            "abcdef1234567890",
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

    def test_dispatch_exposes_only_fixed_operations(self) -> None:
        operation = dispatch_inputs(self.workflow).get("operation")
        self.assertIsInstance(operation, dict)
        self.assertEqual(operation.get("type"), "choice")
        self.assertEqual(set(operation.get("options", [])), EXPECTED_OPTIONS)
        self.assertEqual(operation.get("default"), "none")

    def test_operation_uses_the_canonical_restic_command_only(self) -> None:
        self.assertNotIn("eval", self.body)
        self.assertNotIn("bash -c", self.body)
        self.assertIn("case \"$OPERATION\" in", self.body)
        self.assertIn("unsupported production operation", self.body)

        for operation, command in EXPECTED_COMMANDS.items():
            with self.subTest(operation=operation):
                result, args = run_operation(
                    self.body,
                    operation,
                    workflow_env=self.workflow_env,
                )
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertIn(f"ssh console --app test-app --command {command}", args)
                self.assertNotIn("token-must-not-be-printed", result.stdout)
                self.assertNotIn("token-must-not-be-printed", result.stderr)

    def test_invalid_operation_fails_before_flyctl(self) -> None:
        result, args = run_operation(self.body, "backup; touch should-not-exist")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(args, "")
        self.assertIn("unsupported production operation", result.stderr)

    def test_production_output_is_redacted_and_exit_status_is_preserved(self) -> None:
        result, _ = run_operation(
            self.body,
            "audit",
            workflow_env=self.workflow_env,
            fly_stdout=SENSITIVE_FLY_OUTPUT,
            fly_stderr=SAFE_FLY_DIAGNOSTIC + "\n",
            fly_exit=19,
        )

        self.assertEqual(result.returncode, 19)
        self.assert_fly_output_is_redacted(result)

    def test_watchdog_output_is_redacted_and_exit_status_is_preserved(self) -> None:
        result, args = run_operation(
            self.watchdog_body,
            "",
            workflow_env=self.workflow_env,
            fly_stdout=SENSITIVE_FLY_OUTPUT,
            fly_stderr=SAFE_FLY_DIAGNOSTIC + "\n",
            fly_exit=17,
        )

        self.assertEqual(result.returncode, 17)
        self.assertIn(
            "ssh console --app test-app --command /restic.sh check-freshness",
            args,
        )
        self.assert_fly_output_is_redacted(result)


if __name__ == "__main__":
    unittest.main()
