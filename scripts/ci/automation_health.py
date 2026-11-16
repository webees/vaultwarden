#!/usr/bin/env python3
"""Verify that a workflow is enabled and its latest scheduled run is healthy."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any, Callable, Sequence

API_TIMEOUT_SECONDS = 20
HEALTHY, UNHEALTHY, STALE = 0, 1, 3
WORKFLOW_PATTERN = re.compile(r"[A-Za-z0-9_.-]+\.ya?ml")
REPOSITORY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
TIMESTAMP_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
ACTIVE_STATUSES = {"queued", "in_progress", "pending", "requested", "waiting"}

class HealthError(ValueError):
    """A response or invocation cannot establish a healthy state."""

def positive_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0

def gh_api(endpoint: str) -> Any:
    try:
        result = subprocess.run(
            ["gh", "api", endpoint], capture_output=True, text=True,
            timeout=API_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise HealthError("GitHub API request could not complete") from error
    if result.returncode != 0:
        raise HealthError("GitHub API request failed")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise HealthError("GitHub API returned invalid JSON") from error
    if not isinstance(payload, (dict, list)):
        raise HealthError("GitHub API returned an invalid response")
    return payload

def timestamp(value: object) -> datetime:
    if not isinstance(value, str) or not TIMESTAMP_PATTERN.fullmatch(value):
        raise HealthError("scheduled run has an invalid creation time")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise HealthError("scheduled run has an invalid creation time") from error

def matching_runs(
    payload: object, display_title: str | None
) -> list[tuple[datetime, int, dict[str, Any]]]:
    if not isinstance(payload, dict) or not isinstance(
        payload.get("workflow_runs"), list
    ):
        raise HealthError("scheduled run response has no workflow_runs list")
    matches: list[tuple[datetime, int, dict[str, Any]]] = []
    for item in payload["workflow_runs"]:
        if not isinstance(item, dict):
            raise HealthError("scheduled run response contains a non-object run")
        if item.get("event") != "schedule":
            continue
        if display_title is not None and item.get("display_title") != display_title:
            continue
        run_id = item.get("id")
        if not positive_int(run_id):
            raise HealthError("scheduled run has an invalid identifier")
        matches.append((timestamp(item.get("created_at")), run_id, item))
    return sorted(matches, key=lambda item: (item[0], item[1]), reverse=True)

def job_succeeded(payload: object, job_name: str) -> bool:
    if not isinstance(payload, dict) or not isinstance(payload.get("jobs"), list):
        raise HealthError("workflow job response has no jobs list")
    if not all(isinstance(item, dict) for item in payload["jobs"]):
        raise HealthError("workflow job response contains a non-object job")
    matches = [item for item in payload["jobs"] if item.get("name") == job_name]
    return bool(matches) and all(
        job.get("status") == "completed" and job.get("conclusion") == "success"
        for job in matches
    )

def validate_invocation(
    repository: str, workflow: str, job: str, max_age_seconds: int,
    display_title: str | None,
) -> None:
    if not isinstance(repository, str) or not REPOSITORY_PATTERN.fullmatch(repository):
        raise HealthError("repository must use the owner/name form")
    if not isinstance(workflow, str) or not WORKFLOW_PATTERN.fullmatch(workflow):
        raise HealthError("workflow must be a YAML file name")
    if not isinstance(job, str) or not job.strip():
        raise HealthError("job name must not be empty")
    if not positive_int(max_age_seconds):
        raise HealthError("max age must be positive")
    if display_title is not None and not (isinstance(display_title, str) and display_title.strip()):
        raise HealthError("display title must be a non-empty string or null")

def check_workflow(
    repository: str,
    workflow: str,
    job: str,
    max_age_seconds: int,
    *,
    display_title: str | None = None,
    now: datetime | None = None,
    api: Callable[[str], Any] = gh_api,
) -> tuple[int, str]:
    """Check natural schedule freshness and the latest completed job success."""
    validate_invocation(repository, workflow, job, max_age_seconds, display_title)
    current = now or datetime.now(timezone.utc)
    if not isinstance(current, datetime) or current.tzinfo is None or current.utcoffset() is None: raise HealthError("current time must include a timezone")

    state = api(f"repos/{repository}/actions/workflows/{workflow}")
    if not isinstance(state, dict) or not isinstance(state.get("state"), str):
        raise HealthError("workflow state response is malformed")
    if state["state"] != "active":
        return UNHEALTHY, f"{workflow} is not active"

    runs = api(f"repos/{repository}/actions/workflows/{workflow}/runs?event=schedule&per_page=100")
    matches = matching_runs(runs, display_title)
    if not matches:
        return STALE, f"{workflow} has no matching scheduled run"

    schedule_time, _, latest = matches[0]
    schedule_age = (current - schedule_time).total_seconds()
    if schedule_age < 0:
        raise HealthError("latest scheduled run has a future creation time")
    latest_status = latest.get("status")
    if latest_status not in ACTIVE_STATUSES and latest_status != "completed":
        raise HealthError("latest scheduled run has an invalid status")

    for completed_at, run_id, latest_completed in matches:
        if latest_completed.get("status") == "completed":
            break
    else:
        return UNHEALTHY, f"{workflow} has no completed scheduled run"
    completed_age = (current - completed_at).total_seconds()
    conclusion = latest_completed.get("conclusion")
    if not isinstance(conclusion, str) or not conclusion:
        raise HealthError("latest scheduled run has an invalid conclusion")
    if latest_status in ACTIVE_STATUSES and completed_age > max_age_seconds:
        return UNHEALTHY, f"{workflow} has no recent completed scheduled run"
    if conclusion != "success":
        return UNHEALTHY, f"{workflow} latest completed scheduled run did not succeed"
    jobs = api(f"repos/{repository}/actions/runs/{run_id}/jobs?per_page=100")
    if not job_succeeded(jobs, job):
        return UNHEALTHY, f"{workflow} did not complete its {job} job"
    if schedule_age > max_age_seconds:
        return STALE, f"{workflow} latest scheduled success is stale"
    return HEALTHY, f"{workflow} has a fresh successful {job} run"

def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--workflow", required=True)
    result.add_argument("--job", required=True)
    result.add_argument("--max-age", required=True, type=int)
    result.add_argument("--display-title")
    result.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    return result

def main(arguments: Sequence[str] | None = None) -> int:
    args = parser().parse_args(arguments)
    if not args.repository:
        print("automation health: GITHUB_REPOSITORY is required", file=sys.stderr)
        return UNHEALTHY
    try:
        status, message = check_workflow(
            args.repository,
            args.workflow,
            args.job,
            args.max_age,
            display_title=args.display_title,
        )
    except HealthError as error:
        print(f"automation health: {error}", file=sys.stderr)
        return UNHEALTHY
    if status == STALE:
        print(message, file=sys.stderr)
    else:
        print(message)
    return status

if __name__ == "__main__":
    raise SystemExit(main())
