#!/usr/bin/env python3
"""Test the bounded retry policy for Fly production operations."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/run_fly_operation.sh"


class FlyOperationTest(unittest.TestCase):
    def run_operation(self, mode: str, attempts: int = 3) -> tuple[subprocess.CompletedProcess[str], int]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "bin"
            binary.mkdir()
            counter = root / "counter"
            self.write_executable(
                binary / "timeout",
                "#!/bin/sh\nshift\nexec \"$@\"\n",
            )
            self.write_executable(
                binary / "flyctl",
                textwrap.dedent(
                    f"""\
                    #!/bin/sh
                    count=0
                    if [ -f "{counter}" ]; then count="$(cat "{counter}")"; fi
                    count=$((count + 1))
                    printf '%s' "$count" > "{counter}"
                    case "${{FLY_FAKE_MODE}}:$count" in
                      transient-then-success:1) echo 'Error: tunnel unavailable: timed out (context deadline exceeded)' >&2; exit 1 ;;
                      transient-then-success:*) echo 'operation completed'; exit 0 ;;
                      permanent-failure:*) echo 'Error: invalid command' >&2; exit 2 ;;
                      always-transient:*) echo 'Error: tunnel unavailable: connection refused' >&2; exit 1 ;;
                      timeout:*) exit 124 ;;
                      *) echo 'unexpected fake mode' >&2; exit 99 ;;
                    esac
                    """
                ),
            )
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{binary}:{env['PATH']}",
                    "FLY_APP": "example-app",
                    "OPERATION": "check-freshness",
                    "FLY_LOG_REDACT": "s/^//",
                    "FLY_OPERATION_MAX_ATTEMPTS": str(attempts),
                    "FLY_OPERATION_BUDGET_SECONDS": "60",
                    "FLY_OPERATION_RETRY_DELAY_SECONDS": "0",
                    "FLY_FAKE_MODE": mode,
                }
            )
            result = subprocess.run(
                ["bash", str(SCRIPT)],
                env=env,
                text=True,
                capture_output=True,
                timeout=10,
            )
            calls = int(counter.read_text(encoding="utf-8")) if counter.exists() else 0
            return result, calls

    @staticmethod
    def write_executable(path: Path, content: str) -> None:
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def test_transient_transport_failure_is_retried_once(self) -> None:
        result, calls = self.run_operation("transient-then-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, 2)
        self.assertIn("retrying in 0s", result.stderr)

    def test_permanent_command_failure_is_not_retried(self) -> None:
        result, calls = self.run_operation("permanent-failure")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(calls, 1)
        self.assertNotIn("retrying", result.stderr)

    def test_exhausted_transport_retries_fail_closed(self) -> None:
        result, calls = self.run_operation("always-transient")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, 3)
        self.assertIn("remained unavailable after 3 attempts", result.stderr)

    def test_timeout_is_not_retried(self) -> None:
        result, calls = self.run_operation("timeout")
        self.assertEqual(result.returncode, 124)
        self.assertEqual(calls, 1)
        self.assertIn("exceeded its 60s budget", result.stderr)


if __name__ == "__main__":
    unittest.main()
