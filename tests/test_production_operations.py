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


def write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run_operation(body: str, operation: str) -> tuple[subprocess.CompletedProcess[str], str]:
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
                "OPERATION": operation,
                "PATH": f"{bin_dir}:{environment['PATH']}",
            }
        )
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
                result, args = run_operation(self.body, operation)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertIn(f"ssh console --app test-app --command {command}", args)
                self.assertNotIn("token-must-not-be-printed", result.stdout)
                self.assertNotIn("token-must-not-be-printed", result.stderr)

    def test_invalid_operation_fails_before_flyctl(self) -> None:
        result, args = run_operation(self.body, "backup; touch should-not-exist")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(args, "")
        self.assertIn("unsupported production operation", result.stderr)


if __name__ == "__main__":
    unittest.main()
