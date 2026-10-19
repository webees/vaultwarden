"""Shared assertions for the Python test scripts.

The suites print the same lines the shell helpers used to print, so the CI logs
and the runbook read the same whichever one ran.
"""

from __future__ import annotations

import sys


class Suite:
    """Collect pass/fail lines and decide the exit status at the end."""

    def __init__(self, name: str) -> None:
        self.name = name
        self.failures = 0

    def ok(self, message: str) -> None:
        print(f"ok   {message}", flush=True)

    def bad(self, message: str) -> None:
        self.failures += 1
        print(f"FAIL {message}", file=sys.stderr, flush=True)

    def same(self, message: str, expected: object, actual: object) -> None:
        if expected == actual:
            self.ok(message)
        else:
            self.bad(f"{message} (expected [{expected}], got [{actual}])")

    def report(self) -> None:
        if self.failures:
            print(f"{self.failures} {self.name} failed", file=sys.stderr, flush=True)
            raise SystemExit(1)
        print(f"{self.name} passed", flush=True)
