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
BUILD_WORKFLOW = Path(".github/workflows/build_and_deploy.yml")
EXPECTED_OPTIONS = {
    "none",
    "audit",
    "check-freshness",
    "notify-test",
    "snapshots",
    "verify",
    "restore-test",
    "backup",
}
EXPECTED_ALERT_NEEDS = {"check", "production_operation", "watchdog"}
EXPECTED_COMMANDS = {
    "audit": "/restic.sh audit",
    "check-freshness": "/restic.sh check-freshness",
    "notify-test": "/restic.sh notify-test",
    "snapshots": "/restic.sh snapshots",
    "verify": "/restic.sh verify",
    "restore-test": "/restic.sh restore-test",
    "backup": "/restic.sh backup",
}
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
deadbeef  2026-10-21 10:00:00  8a7b6c5d4e3f2011         /data
"""
SAFE_FLY_DIAGNOSTIC = "network policy rejected the request"


def load_workflow(path: Path = WORKFLOW) -> dict[str, object]:
    ruby = """
      require "json"
      require "yaml"
      print JSON.generate(YAML.load_file(ARGV.fetch(0)))
    """
    result = subprocess.run(
        ["ruby", "-e", ruby, str(path)],
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


def notify_body(workflow: dict[str, object]) -> str:
    jobs = workflow.get("jobs")
    if not isinstance(jobs, dict):
        raise AssertionError("workflow jobs are missing")
    job = jobs.get("notify_failure")
    if not isinstance(job, dict):
        raise AssertionError("notify_failure job is missing")
    steps = job.get("steps")
    if not isinstance(steps, list):
        raise AssertionError("notify_failure steps are missing")
    step = next(
        (
            item
            for item in steps
            if isinstance(item, dict)
            and "Send the failure through Telegram" in str(item.get("name", ""))
        ),
        None,
    )
    if not isinstance(step, dict) or not isinstance(step.get("run"), str):
        raise AssertionError("Telegram failure step is missing")
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


def run_notifier(
    body: str,
    app_env: dict[str, str],
    *,
    fly_api_token: str | None = "fly-token-must-not-be-printed",
    curl_status: str = "200",
    curl_body: str = "",
    curl_stderr: str = "",
    curl_exit: int = 0,
) -> tuple[subprocess.CompletedProcess[str], str]:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        fly_args_file = root / "fly-args"
        args_file = root / "curl-args"

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
printf '%s\n' "$*" >> "$FLY_ARGS_FILE"
case "$*" in
  *"printenv TELEGRAM_BOT_TOKEN")
    [ -n "${FLY_TELEGRAM_BOT_TOKEN+x}" ] || exit 1
    printf '%s\n' "$FLY_TELEGRAM_BOT_TOKEN"
    ;;
  *"printenv TELEGRAM_CHAT_ID")
    [ -n "${FLY_TELEGRAM_CHAT_ID+x}" ] || exit 1
    printf '%s\n' "$FLY_TELEGRAM_CHAT_ID"
    ;;
  *) exit 1 ;;
esac
""",
        )
        write_executable(
            bin_dir / "curl",
            """#!/bin/sh
printf '%s\n' "$*" > "$CURL_ARGS_FILE"
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      shift
      output="$1"
      ;;
  esac
  shift
done
[ -z "$output" ] || printf '%s' "$CURL_BODY" > "$output"
printf '%s' "$CURL_STATUS"
printf '%s' "$CURL_STDERR" >&2
exit "$CURL_EXIT"
""",
        )
        script = root / "notify.sh"
        script.write_text(body, encoding="utf-8")

        environment = os.environ.copy()
        environment.update(
            {
                "CURL_ARGS_FILE": str(args_file),
                "CURL_BODY": curl_body,
                "CURL_EXIT": str(curl_exit),
                "CURL_STATUS": curl_status,
                "CURL_STDERR": curl_stderr,
                "FAILED_JOBS": (
                    "check=failure,production_operation=skipped,watchdog=skipped"
                ),
                "FLY_APP": "test-app",
                "FLY_ARGS_FILE": str(fly_args_file),
                "PATH": f"{bin_dir}:{environment['PATH']}",
                "RUNNER_TEMP": str(root),
                "RUN_URL": "https://example.invalid/actions/runs/1",
                "SHA": "0123456789abcdef0123456789abcdef01234567",
                "WORKFLOW": "Dependency Updates",
            }
        )
        environment.pop("FLY_TELEGRAM_BOT_TOKEN", None)
        environment.pop("FLY_TELEGRAM_CHAT_ID", None)
        if "TELEGRAM_BOT_TOKEN" in app_env:
            environment["FLY_TELEGRAM_BOT_TOKEN"] = app_env["TELEGRAM_BOT_TOKEN"]
        if "TELEGRAM_CHAT_ID" in app_env:
            environment["FLY_TELEGRAM_CHAT_ID"] = app_env["TELEGRAM_CHAT_ID"]
        if fly_api_token is None:
            environment.pop("FLY_API_TOKEN", None)
        else:
            environment["FLY_API_TOKEN"] = fly_api_token
        result = subprocess.run(
            ["bash", str(script)],
            cwd=REPO_ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        args = (
            fly_args_file.read_text(encoding="utf-8").strip()
            + "\nCURL "
            + (
                args_file.read_text(encoding="utf-8").strip()
                if args_file.exists()
                else ""
            )
            if fly_args_file.exists()
            else ""
        )
        return result, args


def visible_notifier_output(result: subprocess.CompletedProcess[str]) -> str:
    output = result.stderr + result.stdout
    return "\n".join(
        line for line in output.splitlines() if not line.startswith("::add-mask::")
    )


def split_notifier_args(args: str) -> tuple[list[str], str]:
    fly_args, marker, curl_args = args.partition("\nCURL ")
    return (
        [line for line in fly_args.splitlines() if line],
        curl_args.strip() if marker else "",
    )


class ProductionOperationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = load_workflow()
        cls.body = operation_body(cls.workflow)
        cls.watchdog_body = watchdog_body(cls.workflow)
        cls.notify_body = notify_body(cls.workflow)
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
            "8a7b6c5d4e3f2011",
            "abcdef1234567890",
            "234567890abcdef1",
            "0123456789abcdef",
            "fdaa:0:1234::5678",
            "img_01JABCDEFGH1234567890",
            "app_01JABCDEFGH1234567890",
            "vol_01JABCDEFGH1234567890",
            "fedcba0987654321",
        ):
            self.assertNotIn(value, output)
        for marker in (
            "[redacted-fly-machine-id]",
            "[redacted-fly-private-ipv6]",
            "[redacted-fly-image-id]",
            "[redacted-fly-id]",
            "[redacted-fly-machine-host]",
        ):
            self.assertIn(marker, output)
        self.assertIn("deadbeef", output)
        self.assertIn(SAFE_FLY_DIAGNOSTIC, output)

    def test_dispatch_exposes_only_fixed_operations(self) -> None:
        operation = dispatch_inputs(self.workflow).get("operation")
        self.assertIsInstance(operation, dict)
        self.assertEqual(operation.get("type"), "choice")
        self.assertEqual(set(operation.get("options", [])), EXPECTED_OPTIONS)
        self.assertEqual(operation.get("default"), "none")

    def test_build_trigger_matches_the_build_workflow_name(self) -> None:
        build = load_workflow(BUILD_WORKFLOW)
        build_name = build.get("name")
        self.assertIsInstance(build_name, str)
        self.assertTrue(build_name)

        events = self.workflow.get("on", self.workflow.get("true"))
        self.assertIsInstance(events, dict)
        workflow_run = events.get("workflow_run")
        self.assertIsInstance(workflow_run, dict)
        names = workflow_run.get("workflows")
        self.assertIsInstance(names, list)
        self.assertEqual(names, [build_name])

    def test_dependabot_auto_merge_uses_target_context_without_checkout(self) -> None:
        events = self.workflow.get("on", self.workflow.get("true"))
        self.assertIsInstance(events, dict)
        self.assertIn("pull_request_target", events)

        jobs = self.workflow.get("jobs")
        self.assertIsInstance(jobs, dict)
        check = jobs.get("check")
        auto = jobs.get("dependabot_automerge")
        self.assertIsInstance(check, dict)
        self.assertIsInstance(auto, dict)
        self.assertIn("github.event_name == 'workflow_run'", check.get("if", ""))
        self.assertIn("github.event_name == 'workflow_dispatch'", check.get("if", ""))
        self.assertNotIn("github.event_name != 'workflow_dispatch'", check.get("if", ""))

        gate = auto.get("if", "")
        self.assertIn("github.event_name == 'pull_request_target'", gate)
        self.assertIn("github.event.pull_request.user.login == 'dependabot[bot]'", gate)
        steps = auto.get("steps")
        self.assertIsInstance(steps, list)
        self.assertEqual(len(steps), 1)
        step = steps[0]
        self.assertNotIn("actions/checkout", json.dumps(auto))
        body = step.get("run", "")
        self.assertIn("gh pr merge", body)
        self.assertIn("--auto", body)
        self.assertIn("/pulls/${PR_NUMBER}/files", body)
        self.assertIn("refusing auto-merge for unexpected path", body)

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

    def test_failure_alert_waits_for_every_work_job_and_is_bounded(self) -> None:
        jobs = self.workflow.get("jobs")
        self.assertIsInstance(jobs, dict)
        notify = jobs.get("notify_failure")
        self.assertIsInstance(notify, dict)
        self.assertEqual(notify.get("if"), "failure()")
        self.assertEqual(set(notify.get("needs", [])), EXPECTED_ALERT_NEEDS)
        self.assertEqual(notify.get("permissions"), {})
        self.assertEqual(notify.get("timeout-minutes"), 5)

        steps = notify.get("steps")
        self.assertIsInstance(steps, list)
        setup = next(
            (
                step
                for step in steps
                if isinstance(step, dict)
                and "setup-flyctl" in str(step.get("uses", ""))
            ),
            None,
        )
        self.assertIsInstance(setup, dict)
        self.assertRegex(str(setup.get("uses")), r"@[0-9a-f]{40}$")

        self.assertIn("https://api.telegram.org/", self.notify_body)
        self.assertIn("::add-mask::", self.notify_body)
        self.assertIn("--data-urlencode", self.notify_body)
        self.assertNotIn("set -x", self.notify_body)

    def test_failure_alert_sends_and_redacts_credentials(self) -> None:
        token = "123456789:AAHfake-token-for-tests"
        chat_id = "@selftest_channel"
        app_env = {
            "TELEGRAM_BOT_TOKEN": token,
            "TELEGRAM_CHAT_ID": chat_id,
        }

        result, args = run_notifier(self.notify_body, app_env)
        fly_args, curl_args = split_notifier_args(args)

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("Telegram failure alert sent", result.stdout)
        self.assertEqual(len(fly_args), 2)
        self.assertEqual(
            sum("printenv TELEGRAM_BOT_TOKEN" in arg for arg in fly_args),
            1,
        )
        self.assertEqual(
            sum("printenv TELEGRAM_CHAT_ID" in arg for arg in fly_args),
            1,
        )
        self.assertIn("https://api.telegram.org/", curl_args)
        self.assertIn(f"chat_id={chat_id}", curl_args)
        self.assertIn("disable_web_page_preview=true", curl_args)
        output = visible_notifier_output(result)
        self.assertNotIn(token, output)
        self.assertNotIn(chat_id, output)

    def test_failure_alert_rejects_malformed_credentials_before_curl(self) -> None:
        app_env = {
            "TELEGRAM_BOT_TOKEN": "not-a-token",
            "TELEGRAM_CHAT_ID": "@selftest",
        }

        result, args = run_notifier(self.notify_body, app_env)
        _, curl_args = split_notifier_args(args)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(curl_args, "")
        self.assertIn("usable Telegram bot token", result.stderr)
        self.assertNotIn("not-a-token", result.stderr + result.stdout)
        self.assertNotIn("@selftest", result.stderr + result.stdout)

    def test_failure_alert_reports_missing_chat_id(self) -> None:
        token = "123456789:AAHfake-token-for-tests"
        app_env = {"TELEGRAM_BOT_TOKEN": token}

        result, args = run_notifier(self.notify_body, app_env)
        fly_args, curl_args = split_notifier_args(args)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(fly_args), 2)
        self.assertEqual(curl_args, "")
        self.assertIn(
            "Could not read TELEGRAM_CHAT_ID from the app environment",
            result.stderr,
        )
        self.assertNotIn(token, result.stderr + result.stdout)

    def test_failure_alert_reports_missing_fly_token(self) -> None:
        result, args = run_notifier(
            self.notify_body,
            {
                "TELEGRAM_BOT_TOKEN": "123456789:AAHfake-token-for-tests",
                "TELEGRAM_CHAT_ID": "@selftest_channel",
            },
            fly_api_token=None,
        )
        fly_args, curl_args = split_notifier_args(args)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(fly_args, [])
        self.assertEqual(curl_args, "")
        self.assertIn("FLY_API_TOKEN", result.stderr)
        self.assertNotIn("123456789:AAHfake-token-for-tests", result.stderr)

    def test_failure_alert_redacts_transport_and_api_errors(self) -> None:
        token = "123456789:AAHfake-token-for-tests"
        chat_id = "@selftest_channel"
        app_env = {
            "TELEGRAM_BOT_TOKEN": token,
            "TELEGRAM_CHAT_ID": chat_id,
        }
        cases = (
            {
                "curl_exit": 7,
                "curl_stderr": f"proxy rejected {token} for {chat_id}",
            },
            {
                "curl_status": "401",
                "curl_body": f'{{"description":"rejected {token} for {chat_id}"}}',
            },
        )

        for case in cases:
            with self.subTest(case=case):
                result, _ = run_notifier(self.notify_body, app_env, **case)
                output = visible_notifier_output(result)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("<redacted>", output)
                self.assertNotIn(token, output)
                self.assertNotIn(chat_id, output)


if __name__ == "__main__":
    unittest.main()
