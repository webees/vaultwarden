#!/usr/bin/env python3
"""Unit tests for scheduled workflow liveness checks."""

from __future__ import annotations

import importlib.util
import subprocess
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "automation_health", ROOT / "scripts/ci/automation_health.py"
)
assert SPEC and SPEC.loader
HEALTH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HEALTH)

NOW = datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc)


def run(*, run_id: int = 1, status: str = "completed",
        conclusion: str | None = "success",
        created_at: str = "2026-10-29T11:00:00Z", event: str = "schedule",
        title: str = "Dependency watchdog") -> dict[str, object]:
    return {
        "id": run_id, "status": status, "conclusion": conclusion,
        "created_at": created_at, "event": event, "display_title": title,
    }

def jobs(*, name: str = "check", status: str = "completed",
         conclusion: str = "success") -> dict[str, object]:
    return {"jobs": [{"name": name, "status": status, "conclusion": conclusion}]}

class AutomationHealthTest(unittest.TestCase):
    def check(
        self,
        runs: list[object],
        *,
        state: str = "active",
        max_age: int = 7200,
        title: str | None = None,
        job_payload: object | None = None,
    ) -> tuple[int, str]:
        job = jobs() if job_payload is None else job_payload
        payloads = [{"state": state}, {"workflow_runs": runs}, job]
        return HEALTH.check_workflow(
            "owner/repository",
            "workflow.yml",
            "check",
            max_age,
            display_title=title,
            now=NOW,
            api=lambda _endpoint: payloads.pop(0),
        )

    def assert_status(self, expected: int, runs: list[object], **kwargs: object) -> None:
        self.assertEqual(self.check(runs, **kwargs)[0], expected)  # type: ignore[arg-type]
    def test_fresh_success_is_healthy(self) -> None:
        self.assert_status(HEALTH.HEALTHY, [run()])
    def test_active_run_requires_a_recent_completed_success(self) -> None:
        for status in HEALTH.ACTIVE_STATUSES:
            with self.subTest(status=status):
                self.assert_status(
                    HEALTH.HEALTHY,
                    [run(run_id=2, status=status, conclusion=None), run(run_id=1)],
                )
                self.assert_status(
                    HEALTH.UNHEALTHY, [run(status=status, conclusion=None)]
                )

    def test_old_schedule_is_stale(self) -> None:
        self.assert_status(HEALTH.STALE, [run(conclusion="failure")], max_age=60)

    def test_old_active_schedule_fails_without_replay(self) -> None:
        for status in HEALTH.ACTIVE_STATUSES:
            with self.subTest(status=status):
                payload = run(status=status, conclusion=None, created_at="2026-10-29T11:58:00Z")
                self.assert_status(HEALTH.UNHEALTHY, [payload], max_age=60)

    def test_active_run_cannot_mask_an_old_success(self) -> None:
        payload = [
            run(run_id=2, status="in_progress", conclusion=None),
            run(run_id=1, created_at="2026-10-29T09:00:00Z"),
        ]
        self.assert_status(HEALTH.UNHEALTHY, payload, max_age=7200)

    def test_disabled_workflow_is_unhealthy(self) -> None:
        self.assert_status(HEALTH.UNHEALTHY, [run()], state="disabled_inactivity")

    def test_manual_or_wrong_title_cannot_prove_schedule_liveness(self) -> None:
        self.assert_status(HEALTH.STALE, [run(event="workflow_dispatch")])
        self.assert_status(
            HEALTH.STALE,
            [run(title="Nightly cleanup")],
            title="Dependency watchdog",
        )

    def test_latest_failure_does_not_fall_back_to_old_success(self) -> None:
        failure = run(run_id=2, conclusion="failure")
        old_success = run(run_id=1, created_at="2026-10-29T10:00:00Z")
        self.assert_status(HEALTH.UNHEALTHY, [old_success, failure])

    def test_expected_job_must_complete_successfully(self) -> None:
        for payload in (
            jobs(name="other"),
            jobs(status="queued", conclusion=""),
            jobs(conclusion="skipped"),
        ):
            with self.subTest(payload=payload):
                self.assert_status(HEALTH.UNHEALTHY, [run()], job_payload=payload)
        with self.assertRaises(HEALTH.HealthError):
            self.check([run()], job_payload={"jobs": "invalid"})

    def test_malformed_responses_fail_closed(self) -> None:
        cases = (
            [run(), "invalid"],
            [run(created_at="yesterday")],
            [run(created_at="2026-10-29T13:00:00Z")],
            [run(status="mystery", conclusion=None)],
            [run(conclusion=None)],
            [run(run_id=0)],
            [run(run_id=True)],
        )
        for payload in cases:
            with self.subTest(payload=payload), self.assertRaises(HEALTH.HealthError):
                self.check(payload)
        with self.assertRaises(HEALTH.HealthError):
            HEALTH.matching_runs({"workflow_runs": "invalid"}, None)
        with self.assertRaises(HEALTH.HealthError):
            self.check([run()], state={"state": 1})
        with self.assertRaises(HEALTH.HealthError): self.check([run()], title=1)  # type: ignore[arg-type]
        with self.assertRaises(HEALTH.HealthError): self.check([run()], title="")
        with self.assertRaises(HEALTH.HealthError):
            HEALTH.check_workflow(
                "owner/repository",
                "workflow.yml",
                "check",
                1,
                now=NOW,
                api=lambda _endpoint: ["unexpected"],
            )

    def test_api_errors_do_not_leak_command_output(self) -> None:
        failed = subprocess.CompletedProcess(
            [], 1, stdout="", stderr="sensitive diagnostic"
        )
        with mock.patch.object(HEALTH.subprocess, "run", return_value=failed):
            with self.assertRaisesRegex(HEALTH.HealthError, "request failed"):
                HEALTH.gh_api("repos/owner/repository/actions/workflows")
        timed_out = subprocess.TimeoutExpired(["gh", "api"], 30)
        with mock.patch.object(HEALTH.subprocess, "run", side_effect=timed_out):
            with self.assertRaisesRegex(HEALTH.HealthError, "could not complete"):
                HEALTH.gh_api("repos/owner/repository/actions/workflows")

    def test_invalid_invocation_is_rejected(self) -> None:
        cases = (
            ("owner", "workflow.yml", "check", 1),
            ("owner/repository", "../workflow.yml", "check", 1),
            ("owner/repository", "workflow.yml", "", 1),
            ("owner/repository", "workflow.yml", "check", 0),
            ("owner/repository", "workflow.yml", "check", -1),
            ("owner/repository", "workflow.yml", "check", True),
        )
        for repository, workflow, job, max_age in cases:
            with self.subTest(repository=repository, workflow=workflow):
                with self.assertRaises(HEALTH.HealthError):
                    HEALTH.check_workflow(
                        repository,
                        workflow,
                        job,
                        max_age,
                    )

        with self.assertRaises(HEALTH.HealthError):
            HEALTH.check_workflow(
                "owner/repository",
                "workflow.yml",
                "check",
                1,
                now=datetime(2026, 10, 29, 12, 0),
            )

if __name__ == "__main__":
    unittest.main()
