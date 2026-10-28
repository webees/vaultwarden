#!/usr/bin/env python3
"""Boot an image and run the checks that only exist at container runtime.

The Caddyfile has to validate, the process stack has to come up unprivileged,
the backup paths have to work inside the image, and the proxy has to keep
credentials out of its access log. Shared by the validate and build workflows so
the merge path tests the exact digest it publishes.

Usage: tests/runtime_smoke.py <image>

Everything that runs inside the image is one command or a short `sh` snippet:
the image ships no Python on purpose, so that part cannot move here.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


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


TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent
FLY_CLIENT_IP = ".".join(("203", "0", "113", "9"))
CF_CONNECTING_IP = ".".join(("203", "0", "113", "99"))
X_FORWARDED_FOR_IP = ".".join(("198", "51", "100", "11"))
X_REAL_IP = ".".join(("198", "51", "100", "12"))

suite = Suite("runtime smoke")
containers: list[str] = []
images: list[str] = []
temp_dirs: list[Path] = []
sink: subprocess.Popen[str] | None = None


def run(*args: str, check: bool = True, stream: bool = False) -> subprocess.CompletedProcess[str]:
    """Run a command, capturing both streams so a failure can print them."""
    result = subprocess.run(args, capture_output=not stream, text=True)
    if check and result.returncode != 0:
        raise SystemExit(
            f"command failed ({result.returncode}): {' '.join(args)}\n"
            f"{result.stdout or ''}{result.stderr or ''}"
        )
    return result


def docker(*args: str, check: bool = True, stream: bool = False) -> subprocess.CompletedProcess[str]:
    return run("docker", *args, check=check, stream=stream)


def exec_in(
    container: str, *args: str, check: bool = True, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    env_args = [arg for key, value in (env or {}).items() for arg in ("--env", f"{key}={value}")]
    return docker("exec", *env_args, container, *args, check=check)


def shell_in(
    container: str, script: str, check: bool = True, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    """Run a short POSIX snippet in the container. The image has no Python."""
    return exec_in(container, "sh", "-c", script, check=check, env=env)


def expect_shell(image: str, script: str, success: str, failure: str) -> None:
    """Run one isolated image case, retrying only when an attempt never ends."""
    started = "__runtime_smoke_started__"
    ended = "__runtime_smoke_ended__="
    passed = "__runtime_smoke_passed__"
    attempts = 3
    wrapped = "\n".join((
        f"printf '%s\\n' '{started}'",
        "status=0",
        "(",
        script,
        ") || status=$?",
        f"printf '%s%s\\n' '{ended}' \"$status\"",
        f"[ \"$status\" -ne 0 ] || printf '%s\\n' '{passed}'",
        "exit \"$status\"",
        "",
    ))
    for _ in range(attempts):
        result = docker(
            "run", "--rm", "--entrypoint", "sh", image, "-c", wrapped, check=False
        )
        output = combined(result)
        status_match = re.search(rf"^{re.escape(ended)}([0-9]+)$", output, re.MULTILINE)
        passed_match = re.search(rf"^{re.escape(passed)}$", output, re.MULTILINE)
        if (
            status_match
            and passed_match
            and result.returncode == 0
            and status_match.group(1) == "0"
        ):
            suite.ok(success)
            return
        if status_match:
            suite.bad(failure)
            print(output, file=sys.stderr)
            return
        if result.returncode == 0:
            suite.bad(f"{failure}: shell case exited without lifecycle markers")
            print(output, file=sys.stderr)
            return
    suite.bad(f"{failure}: shell case was interrupted after {attempts} attempts")
    print(combined(result), file=sys.stderr)


def combined(result: subprocess.CompletedProcess[str]) -> str:
    """Both streams as one text, the way `docker logs 2>&1` reads."""
    return f"{result.stdout or ''}{result.stderr or ''}"


def cleanup() -> None:
    for name in containers:
        docker("rm", "--force", name, check=False)
    if sink is not None and sink.poll() is None:
        sink.terminate()
        try:
            sink.wait(timeout=10)
        except subprocess.TimeoutExpired:
            sink.kill()
    for image in images:
        docker("rmi", "--force", image, check=False)
    for path in temp_dirs:
        shutil.rmtree(path, ignore_errors=True)


def scratch(image: str, name: str) -> str:
    """A throwaway container with a shell, so a case starts from a clean /data."""
    # `sleep` as the entrypoint, not `sh`: an image started with `sh sleep 600`
    # would read "sleep" as a script file and exit before the case runs.
    docker("run", "--detach", "--name", name, "--entrypoint", "sleep", image, "600")
    containers.append(name)
    return name


def wait_for_alive(container: str) -> bool:
    for _ in range(30):
        if exec_in(container, "wget", "-qO-", "http://127.0.0.1:8080/alive", check=False).returncode == 0:
            return True
        time.sleep(2)
    return False


def probe_code(container: str, *args: str) -> str:
    return exec_in(container, "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", *args).stdout.strip()


def start_stack(image: str, name: str, extra_env: dict[str, str] | None = None) -> str:
    env_args = [arg for key, value in (extra_env or {}).items() for arg in ("--env", f"{key}={value}")]
    docker(
        "run",
        "--detach",
        "--name",
        name,
        "--env",
        "CADDY_DOMAINS=example.com",
        "--env",
        "DOMAIN=https://example.com",
        "--env",
        "I_REALLY_WANT_VOLATILE_STORAGE=true",
        *env_args,
        image,
    )
    containers.append(name)
    return name


def process_ids(container: str, name: str) -> list[int]:
    result = exec_in(container, "pidof", name, check=False)
    return [int(value) for value in result.stdout.split() if value.isdigit()]


def wait_for_replacement(container: str, name: str, old_pid: int) -> int | None:
    for _ in range(60):
        current = process_ids(container, name)
        replacement = next((pid for pid in current if pid != old_pid), None)
        if replacement is not None:
            return replacement
        time.sleep(0.1)
    return None


def check_process_supervision(container: str) -> None:
    """A crashed proxy or scheduler must come back without Overmind or tmux."""
    for service in ("caddy", "supercronic"):
        before = process_ids(container, service)
        if len(before) != 1:
            suite.bad(f"expected one {service} process before the restart probe, got {before}")
            suite.report()
        exec_in(container, "kill", "-9", str(before[0]))
        after = wait_for_replacement(container, service, before[0])
        if after is None:
            suite.bad(f"{service} was not restarted after a forced exit")
            print("\n".join(access_log(container).splitlines()[-30:]), file=sys.stderr)
            suite.report()
        suite.ok(f"{service} restarted with a new process id after a forced exit")

    if not wait_for_alive(container):
        suite.bad("the proxy did not recover after its forced restart")
        suite.report()
    log = access_log(container)
    for process, label in (("caddy", "caddy"), ("supercronic", "crontab")):
        if f"[{label}] exited with status 137, restarting in 0.1s" not in log:
            suite.bad(f"the process table did not log the {process} restart")
            print("\n".join(log.splitlines()[-30:]), file=sys.stderr)
            suite.report()
    suite.ok("the static process table records both restarts")


def check_invalid_restart_delay(image: str) -> None:
    result = docker(
        "run",
        "--rm",
        "--env",
        "SUPERVISE_RESTART_DELAY=0.0",
        image,
        check=False,
    )
    if result.returncode != 2 or "must be a positive number" not in combined(result):
        suite.bad("an invalid process restart delay did not fail before starting services")
        print(f"rc={result.returncode}\n{combined(result)}", file=sys.stderr)
        suite.report()
    suite.ok("an invalid process restart delay fails closed before services start")


def check_invalid_addresses(image: str) -> None:
    cases = (
        (("CADDY_DOMAINS=bad_host",), "not a valid DNS name"),
        (("DOMAIN=http://example.com",), "must be an https URL"),
    )
    for environment, message in cases:
        args = ["run", "--rm"]
        for value in environment:
            args.extend(("--env", value))
        result = docker(*args, image, check=False)
        if result.returncode != 2 or message not in combined(result):
            suite.bad("an invalid entrypoint address did not fail closed")
            print(f"rc={result.returncode}\n{combined(result)}", file=sys.stderr)
            suite.report()

    backup_cases = (
        ("relative/path", "", "RESTIC_REPOSITORY"),
        ("s3://example.invalid//bucket", "", "RESTIC_REPOSITORY"),
        ("s3://s3.example.invalid/bucket", "http://health.example.invalid", "HEALTHCHECK_URL"),
    )
    for repository, healthcheck, message in backup_cases:
        result = docker(
            "run", "--rm", "--entrypoint", "/restic.sh",
            "--env", f"RESTIC_REPOSITORY={repository}",
            "--env", f"HEALTHCHECK_URL={healthcheck}",
            image, "check-disk", check=False,
        )
        if result.returncode != 2 or message not in combined(result):
            suite.bad("an invalid backup address did not fail closed")
            print(f"rc={result.returncode}\n{combined(result)}", file=sys.stderr)
            suite.report()
    suite.ok("unsafe entrypoint, repository and heartbeat addresses fail closed")


def check_services_requires_unprivileged_user(image: str) -> None:
    result = docker(
        "run",
        "--rm",
        "--entrypoint",
        "/services.sh",
        image,
        check=False,
    )
    if result.returncode != 2 or "must run as the unprivileged service user" not in combined(result):
        suite.bad("the process table starts when invoked directly as root")
        print(f"rc={result.returncode}\n{combined(result)}", file=sys.stderr)
        suite.report()
    suite.ok("the process table refuses to start directly as root")


def check_timeout_process_group_cleanup(image: str) -> None:
    """A helper that ignores TERM must not survive its command's process group."""
    script = r"""
set -eu
mkdir -p /data/restic-logs /tmp/stub
chown -R vaultwarden:vaultwarden /data
printf '%s\n' \
    '#!/bin/sh' \
    '(trap "" TERM; sleep 300) &' \
    'echo "$!" > /tmp/helper.pid' \
    'exit 0' > /tmp/stub/restic
chmod +x /tmp/stub/restic
PATH="/tmp/stub:$PATH" RESTIC_PASSWORD=selftest /restic.sh snapshots >/tmp/run.log 2>&1
helper="$(cat /tmp/helper.pid)"
sleep 0.2
if [ -r "/proc/$helper/status" ]; then
    state="$(awk '/^State:/ {print $2}' "/proc/$helper/status")"
    if [ "$state" != "Z" ]; then
        kill -KILL "$helper" 2>/dev/null || :
        exit 1
    fi
fi
"""
    expect_shell(
        image,
        script,
        "a helper that ignores TERM does not survive its command",
        "a helper that ignores TERM survived the command cleanup",
    )


def check_backup_lock_error(image: str) -> None:
    """An unwritable lock is an operational error, not a concurrent run."""
    script = r"""
mkdir -p /data/restic-logs /tmp/stub
chown vaultwarden:vaultwarden /data /data/restic-logs
chmod 500 /data/restic-logs
printf '%s\n' \
    '#!/bin/sh' \
    'case "$*" in' \
    '    *api.telegram.org*) printf "telegram\n" >> /tmp/curl-calls; printf "%s\nHTTP_STATUS=200\n" "{\"ok\":true}" ;;' \
    '    *health.invalid*) printf "heartbeat\n" >> /tmp/curl-calls ;;' \
    'esac' > /tmp/stub/curl
chmod +x /tmp/stub/curl
rc=0
output="$(
    PATH="/tmp/stub:$PATH" RESTIC_PASSWORD=selftest \
    TELEGRAM_BOT_TOKEN='123456:selftest' TELEGRAM_CHAT_ID='@selftest_channel' \
    HEALTHCHECK_URL=https://health.invalid/ping /restic.sh backup 2>&1
)" || rc=$?
printf '%s\n' "$output"
[ "$rc" -eq 2 ] || exit 1
printf '%s\n' "$output" | grep -Fq 'Cannot create /data/restic-logs/backup.lock' || exit 1
if printf '%s\n' "$output" | grep -Fq 'Another backup is already running'; then
    exit 1
fi
[ "$(grep -c '^telegram$' /tmp/curl-calls)" -eq 1 ] || exit 1
[ "$(grep -c '^heartbeat$' /tmp/curl-calls)" -eq 1 ] || exit 1
sed -n 's/^message=//p' /data/backup-status.txt | grep -Fq 'Cannot create backup lock' || exit 1
"""
    expect_shell(
        image,
        script,
        "an unwritable backup lock fails as one operational alert",
        "an unwritable backup lock is masked or alerts more than once",
    )


def check_freshness_uptime_read_failure(image: str) -> None:
    """A missing instance age must fail closed, not look like a new volume."""
    script = r"""
set -eu
chown -R vaultwarden:vaultwarden /data
printf 'state=unknown\nupdated_at=0\nlast_success=0\nmessage=No backup recorded\n' \
    >/data/backup-status.txt
chown vaultwarden:vaultwarden /data/backup-status.txt
mkdir -p /tmp/stub
printf '#!/bin/sh\nexit 9\n' >/tmp/stub/cut
chmod +x /tmp/stub/cut
rc=0
PATH="/tmp/stub:$PATH" BACKUP_MAX_AGE=7200 \
    /restic.sh check-freshness >/tmp/freshness-uptime.log 2>&1 || rc=$?
[ "$rc" -eq 2 ]
grep -Fq 'Cannot determine the instance age' /tmp/freshness-uptime.log
grep -qx 'state=failed' /data/backup-status.txt

printf 'state=unknown\nupdated_at=0\nlast_success=0\nmessage=No backup recorded\n' \
    >/data/backup-status.txt
printf '#!/bin/sh\nprintf "not-a-number\\n"\n' >/tmp/stub/cut
rc=0
PATH="/tmp/stub:$PATH" BACKUP_MAX_AGE=7200 \
    /restic.sh check-freshness >/tmp/freshness-uptime.log 2>&1 || rc=$?
[ "$rc" -eq 2 ]
grep -Fq 'Cannot determine the instance age' /tmp/freshness-uptime.log
grep -qx 'state=failed' /data/backup-status.txt
"""
    expect_shell(
        image,
        script,
        "an unreadable or malformed instance age fails the freshness guard",
        "an unreadable or malformed instance age was treated as a new volume",
    )


def check_telegram_error_redaction(image: str) -> None:
    """Both Telegram credentials must stay out of the persistent run log."""
    script = r"""
set -eu
mkdir -p /data/restic-logs /tmp/stub
chown -R vaultwarden:vaultwarden /data
printf 'state=ok\nupdated_at=1\nlast_success=1\nmessage=stale\n' \
    >/data/backup-status.txt
chown vaultwarden:vaultwarden /data/backup-status.txt
cat >/tmp/stub/curl <<'EOF'
#!/bin/sh
printf '%s\n' '{"ok":false,"description":"rejected 123456:selftest @selftest_channel"}'
printf '%s\n' 401
EOF
chmod +x /tmp/stub/curl
rc=0
PATH="/tmp/stub:$PATH" TELEGRAM_BOT_TOKEN='123456:selftest' \
    TELEGRAM_CHAT_ID='@selftest_channel' BACKUP_MAX_AGE=60 \
    /restic.sh check-freshness >/tmp/telegram-redaction.log 2>&1 || rc=$?
[ "$rc" -eq 2 ]
if grep -Fq '123456:selftest' /tmp/telegram-redaction.log; then
    cat /tmp/telegram-redaction.log >&2
    exit 1
fi
if grep -Fq '@selftest_channel' /tmp/telegram-redaction.log; then
    cat /tmp/telegram-redaction.log >&2
    exit 1
fi
if ! grep -Fq '<redacted>' /tmp/telegram-redaction.log; then
    cat /tmp/telegram-redaction.log >&2
    exit 1
fi
"""
    expect_shell(
        image,
        script,
        "Telegram error responses redact the token and chat id",
        "a Telegram error response leaked a credential into the run log",
    )


def check_snapshot_argument_boundaries(image: str) -> None:
    """Snapshot references must never be parsed as restic options."""
    script = r"""
set -eu
chown -R vaultwarden:vaultwarden /data
mkdir -p /tmp/stub
cat >/tmp/stub/restic <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>/tmp/restic-args
case "$1" in
    stats) printf '{"total_size":1024}\n' ;;
esac
exit 0
EOF
chmod +x /tmp/stub/restic
rm -f /tmp/restic-args
RESTIC_PASSWORD=selftest RESTIC_REPOSITORY=/tmp/repo RESTORE_CONFIRM=yes \
    PATH="/tmp/stub:$PATH" /restic.sh restore --help >/tmp/restore-arg.log 2>&1
if ! grep -Fq 'restore --target / -- --help' /tmp/restic-args; then
    cat /tmp/restic-args /tmp/restore-arg.log >&2
    exit 1
fi

rc=0
RESTIC_PASSWORD=selftest RESTIC_REPOSITORY=/tmp/repo \
    PATH="/tmp/stub:$PATH" /restic.sh restore-test --help \
    >/tmp/restore-test-arg.log 2>&1 || rc=$?
[ "$rc" -eq 2 ]
if ! grep -Fq 'stats --json -- --help' /tmp/restic-args; then
    cat /tmp/restic-args /tmp/restore-test-arg.log >&2
    exit 1
fi
if ! grep -Eq '^restore --target /tmp/restic-restore\..* -- --help$' /tmp/restic-args; then
    cat /tmp/restic-args /tmp/restore-test-arg.log >&2
    exit 1
fi
"""
    expect_shell(
        image,
        script,
        "snapshot references stay behind the restic option boundary",
        "a snapshot reference is parsed as a restic option",
    )


def check_sqlite_integrity_contract(image: str) -> None:
    """A non-ok integrity result must fail even when sqlite3 exits zero."""
    script = r"""
set -eu
find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} +
rm -rf /tmp/stub /tmp/restic-calls
mkdir -p /data/restic-logs /tmp/stub
chown -R vaultwarden:vaultwarden /data
sqlite3 /data/db.sqlite3 \
    "PRAGMA ignore_check_constraints=ON; CREATE TABLE t(v INTEGER CHECK(v > 0)); INSERT INTO t VALUES(-1);"
printf 'test key\n' >/data/rsa_key.pem
chown vaultwarden:vaultwarden /data/rsa_key.pem
printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\\n" "$*" >>/tmp/restic-calls' \
    'exit 0' >/tmp/stub/restic
chmod 755 /tmp/stub/restic
rc=0
PATH="/tmp/stub:$PATH" RESTIC_PASSWORD=selftest RESTIC_REPOSITORY=/tmp/repo \
    /restic.sh backup >/tmp/sqlite-integrity.log 2>&1 || rc=$?
[ "$rc" -eq 2 ]
grep -Fq 'SQLite check' /tmp/sqlite-integrity.log
grep -Fq 'CHECK constraint failed in t' /tmp/sqlite-integrity.log
! grep -Eq '^backup ' /tmp/restic-calls
grep -Fq 'state=failed' /data/backup-status.txt
"""
    expect_shell(
        image,
        script,
        "a non-ok SQLite integrity result stops the backup",
        "a non-ok SQLite integrity result passed as a healthy backup",
    )


def check_restic_output_and_limit_failures(image: str) -> None:
    """A failed tail must not pass, and unsafe limits must fail before work."""
    script = r"""
set -eu
rm -rf /data/restic-logs /tmp/stub /tmp/tail-count /tmp/backend-called \
    /tmp/unsafe-log-dir
mkdir -p /data/restic-logs /tmp/stub
chown -R vaultwarden:vaultwarden /data
printf 'state=unknown\nupdated_at=0\nlast_success=0\nmessage=seed\n' \
    >/data/backup-status.txt
chown vaultwarden:vaultwarden /data/backup-status.txt

cat >/tmp/stub/tail <<'EOF'
#!/bin/sh
count_file=/tmp/tail-count
count="$(cat "$count_file" 2>/dev/null || echo 0)"
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
[ "$count" -ne 1 ] || exit 1
exec /bin/busybox tail "$@"
EOF
printf '%s\n' \
    '#!/bin/sh' \
    'printf called >>/tmp/backend-called' \
    'exit 0' >/tmp/stub/restic
chmod +x /tmp/stub/tail /tmp/stub/restic
rc=0
PATH="/tmp/stub:$PATH" RESTIC_PASSWORD=selftest RESTIC_REPOSITORY=/tmp/repo \
    /restic.sh snapshots >/tmp/restic-tail-failure.log 2>&1 || rc=$?
[ "$rc" -eq 2 ]
! grep -Fq '✓' /tmp/restic-tail-failure.log

rm -rf /data/restic-logs
mkdir -p /data/restic-logs
chown vaultwarden:vaultwarden /data/restic-logs
printf '%s\n' \
    '#!/bin/sh' \
    'head -c 2097152 /dev/zero | tr "\\000" x' \
    'exit 0' >/tmp/stub/restic
chmod +x /tmp/stub/restic
rc=0
PATH="/tmp/stub:$PATH" RESTIC_PASSWORD=selftest RESTIC_REPOSITORY=/tmp/repo \
    RESTIC_LOG_MAX_BYTES=4096 RESTIC_LOG_DIR_MAX_BYTES=4096 \
    /restic.sh snapshots >/tmp/restic-huge-output.log 2>&1 || rc=$?
[ "$rc" -eq 0 ]
log_file="$(find /data/restic-logs -maxdepth 1 -type f -name '*.log' | head -n 1)"
[ -n "$log_file" ]
[ "$(wc -c < "$log_file")" -le 4096 ]
[ -z "$(find /data/restic-logs -maxdepth 1 -type f -name '*.tmp.*' -print -quit)" ]
rm -f /tmp/restic-huge-output.log

# Every bound is checked before the log directory is created, the status marker
# changes, or a backend command starts.
status_before="$(cksum /data/backup-status.txt)"
for spec in \
    'RESTIC_LOG_MAX_BYTES=9223372036854775807' \
    'RESTIC_LOG_DIR_MAX_BYTES=9223372036854775807' \
    'RESTIC_QUICK_TIMEOUT=9223372036854775807' \
    'RESTIC_LONG_TIMEOUT=9223372036854775807' \
    'BACKUP_MAX_AGE=9223372036854775807' \
    'RESTIC_LOG_MAX_BYTES=0' \
    'RESTIC_LOG_MAX_BYTES=0100'; do
    rm -f /tmp/backend-called /tmp/tail-count
    rc=0
    env "$spec" PATH="/tmp/stub:$PATH" RESTIC_PASSWORD=selftest \
        RESTIC_REPOSITORY=/tmp/repo RESTIC_LOG_DIR=/tmp/unsafe-log-dir \
        /restic.sh snapshots >/tmp/restic-limit.log 2>&1 || rc=$?
    [ "$rc" -eq 2 ]
    [ ! -e /tmp/backend-called ]
    [ ! -e /tmp/unsafe-log-dir ]
    [ "$(cksum /data/backup-status.txt)" = "$status_before" ]
done

rm -rf /tmp/unsafe-log-dir
rc=0
RESTIC_PASSWORD=selftest RESTIC_REPOSITORY=/tmp/repo \
    RESTIC_LOG_MAX_BYTES=1048576 RESTIC_LOG_DIR_MAX_BYTES=524288 \
    RESTIC_LOG_DIR=/tmp/unsafe-log-dir /restic.sh snapshots \
    >/tmp/restic-limit.log 2>&1 || rc=$?
[ "$rc" -eq 2 ]
grep -Fq 'must not exceed RESTIC_LOG_DIR_MAX_BYTES' /tmp/restic-limit.log
[ ! -e /tmp/unsafe-log-dir ]
[ "$(cksum /data/backup-status.txt)" = "$status_before" ]
"""
    expect_shell(
        image,
        script,
        "bounded output failures and unsafe restic limits fail before work",
        "a tail failure passed or an unsafe restic limit reached the backend",
    )


def check_log_rotation_failure(image: str) -> None:
    """An unmaintainable log directory must stop before backend work."""
    script = r"""
set -eu
rm -rf /data/restic-logs
mkdir -p /data/restic-logs /tmp/stub
chown vaultwarden:vaultwarden /data /data/restic-logs
dd if=/dev/zero of=/data/restic-logs/unreadable.log bs=1024 count=64 2>/dev/null
chown root:root /data/restic-logs/unreadable.log
chmod 000 /data/restic-logs/unreadable.log
printf '%s\n' '#!/bin/sh' 'touch /tmp/backend-called' 'exit 0' > /tmp/stub/restic
printf '%s\n' \
    '#!/bin/sh' \
    'case "$*" in *"PRAGMA integrity_check"*) printf "ok\n" ;; esac' \
    'exit 0' > /tmp/stub/sqlite3
printf '%s\n' \
    '#!/bin/sh' \
    'case "$*" in *fail*) printf "fail\n" >> /tmp/heartbeat-calls ;; esac' \
    > /tmp/stub/curl
chmod +x /tmp/stub/restic /tmp/stub/sqlite3 /tmp/stub/curl
PATH="/tmp/stub:$PATH" RESTIC_PASSWORD=selftest \
    RESTIC_LOG_MAX_BYTES=1024 RESTIC_LOG_DIR_MAX_BYTES=1048576 \
    HEALTHCHECK_URL=https://health.invalid/ping \
    /restic.sh backup >/tmp/unreadable-backup.log 2>&1 || rc=$?
[ "${rc:-0}" -eq 2 ]
[ ! -e /tmp/backend-called ]
grep -Fq 'cannot enforce the per-file log cap' /tmp/unreadable-backup.log
grep -Fq 'refusing to create a new log' /tmp/unreadable-backup.log
grep -Fq 'state=failed' /data/backup-status.txt
grep -Fq 'message=Log directory limits cannot be enforced' /data/backup-status.txt
[ "$(grep -c '^fail$' /tmp/heartbeat-calls)" -eq 1 ]
"""
    expect_shell(
        image,
        script,
        "an unmaintainable log directory stops before backend work",
        "an unmaintainable log directory reached the backend or left a false success",
    )


def check_status_write_failure(image: str) -> None:
    """A backup must fail closed when its monitoring marker cannot be updated."""
    script = r"""
set -eu
rm -rf /data/* /tmp/logs /tmp/stub
mkdir -p /data /tmp/logs /tmp/stub
printf 'state=unknown\nupdated_at=0\nlast_success=0\nmessage=seed\n' > /data/backup-status.txt
chown root:root /data /data/backup-status.txt
chmod 500 /data
chmod 400 /data/backup-status.txt
chown vaultwarden:vaultwarden /tmp/logs
printf '%s\n' '#!/bin/sh' 'exit 0' > /tmp/stub/restic
printf '%s\n' \
    '#!/bin/sh' \
    'case "$*" in *"PRAGMA integrity_check"*) printf "ok\n" ;; esac' \
    'exit 0' > /tmp/stub/sqlite3
printf '%s\n' \
    '#!/bin/sh' \
    'case "$*" in' \
    '    *api.telegram.org*) printf "telegram\n" >> /tmp/logs/calls ;;' \
    '    *health.invalid/*/fail*) printf "heartbeat\n" >> /tmp/logs/calls ;;' \
    'esac' > /tmp/stub/curl
chmod +x /tmp/stub/restic /tmp/stub/sqlite3 /tmp/stub/curl
rc=0
output="$(
    PATH="/tmp/stub:$PATH" RESTIC_PASSWORD=selftest RESTIC_LOG_DIR=/tmp/logs \
    TELEGRAM_BOT_TOKEN='123456:selftest' TELEGRAM_CHAT_ID='@selftest_channel' \
    HEALTHCHECK_URL=https://health.invalid/ping /restic.sh backup 2>&1
)" || rc=$?
chmod 700 /data
printf '%s\n' "$output" >/tmp/status-write.log
[ "$rc" -eq 2 ]
grep -Fq 'Cannot record backup start state' /tmp/status-write.log
[ "$(grep -c '^telegram$' /tmp/logs/calls)" -eq 1 ]
[ "$(grep -c '^heartbeat$' /tmp/logs/calls)" -eq 1 ]
grep -Fq 'state=unknown' /data/backup-status.txt

rm -rf /data/*
mkdir /data/backup-status.txt
chown vaultwarden:vaultwarden /data /data/backup-status.txt
chmod 700 /data /data/backup-status.txt
: > /tmp/logs/calls
rc=0
output="$(
    PATH="/tmp/stub:$PATH" RESTIC_PASSWORD=selftest RESTIC_LOG_DIR=/tmp/logs \
    TELEGRAM_BOT_TOKEN='123456:selftest' TELEGRAM_CHAT_ID='@selftest_channel' \
    HEALTHCHECK_URL=https://health.invalid/ping /restic.sh backup 2>&1
)" || rc=$?
printf '%s\n' "$output" >/tmp/status-write.log
[ "$rc" -eq 2 ]
grep -Fq 'Cannot record backup start state' /tmp/status-write.log
[ "$(grep -c '^telegram$' /tmp/logs/calls)" -eq 1 ]
[ "$(grep -c '^heartbeat$' /tmp/logs/calls)" -eq 1 ]
[ -d /data/backup-status.txt ]
[ "$(find /data/backup-status.txt -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 0 ]
"""
    expect_shell(
        image,
        script,
        "an unwritable backup marker fails and alerts once",
        "an unwritable backup marker is treated as a successful backup",
    )


def check_app_exit_stops_stack(image: str) -> None:
    """Vaultwarden is authoritative: Fly must restart the whole container."""
    container = start_stack(
        image,
        f"app-exit-{os.getpid()}",
        {"SUPERVISE_RESTART_DELAY": "0.1"},
    )
    if not wait_for_alive(container):
        suite.bad("the app-exit probe never became ready")
        suite.report()
    vaultwarden = process_ids(container, "vaultwarden")
    if len(vaultwarden) != 1:
        suite.bad(f"expected one Vaultwarden process, got {vaultwarden}")
        suite.report()
    exec_in(container, "kill", "-9", str(vaultwarden[0]))

    state = ""
    for _ in range(60):
        state = docker(
            "inspect",
            "--format",
            "{{.State.Running}} {{.State.ExitCode}}",
            container,
        ).stdout.strip()
        if state.startswith("false "):
            break
        time.sleep(0.1)
    if state != "false 137":
        suite.bad(f"Vaultwarden exiting did not stop the full stack with status 137: {state!r}")
        print("\n".join(access_log(container).splitlines()[-30:]), file=sys.stderr)
        suite.report()
    suite.ok("a Vaultwarden crash stops the full process table for Fly to restart")


def access_log(container: str) -> str:
    return combined(docker("logs", container, check=False))


def check_host_whitelist(container: str) -> None:
    allowed = probe_code(container, "-H", "Host: example.com", "http://127.0.0.1:8080/api/config")
    denied = probe_code(container, "-H", "Host: evil.example", "http://127.0.0.1:8080/api/config")
    # /alive is deliberately matched before the whitelist, or Fly would pull a
    # machine whose proxy is fine but whose domain secret is wrong.
    alive = probe_code(container, "-H", "Host: evil.example", "http://127.0.0.1:8080/alive")
    if (allowed, denied, alive) == ("200", "403", "200"):
        suite.ok("the host whitelist serves the configured domain, refuses others and keeps /alive reachable")
    else:
        suite.bad(f"host whitelist: allowed={allowed} denied={denied} alive={alive}")
        suite.report()


def check_client_ip(container: str) -> None:
    """Fly overwrites Fly-Client-IP at the edge; CF-Connecting-IP may not be trusted."""
    probe_code(container, "-H", "Host: example.com", "-H", f"Fly-Client-IP: {FLY_CLIENT_IP}", "http://127.0.0.1:8080/api/config")
    probe_code(container, "-H", "Host: example.com", "-H", f"CF-Connecting-IP: {CF_CONNECTING_IP}", "http://127.0.0.1:8080/api/config")


def check_admin_access_boundary(container: str) -> None:
    """The origin must not serve /admin around Cloudflare Access."""
    direct = probe_code(container, "-H", "Host: example.com", "http://127.0.0.1:8080/admin")
    forged = probe_code(
        container,
        "-H",
        "Host: example.com",
        "-H",
        f"Fly-Client-IP: {FLY_CLIENT_IP}",
        "-H",
        "Cf-Access-Jwt-Assertion: forged",
        "http://127.0.0.1:8080/admin",
    )
    no_jwt = probe_code(
        container,
        "-H",
        "Host: example.com",
        "-H",
        "Fly-Client-IP: 173.245.48.10",
        "http://127.0.0.1:8080/admin",
    )
    via_cloudflare = probe_code(
        container,
        "-H",
        "Host: example.com",
        "-H",
        "Fly-Client-IP: 173.245.48.10",
        "-H",
        f"CF-Connecting-IP: {FLY_CLIENT_IP}",
        "-H",
        "Cf-Access-Jwt-Assertion: selftest",
        "http://127.0.0.1:8080/admin",
    )
    ordinary = probe_code(container, "-H", "Host: example.com", "http://127.0.0.1:8080/api/config")
    # The pinned Vaultwarden build renders the admin entry point with a 200 even
    # when no token is configured. Accepting any non-403 status would also pass a
    # 502, so require the exact upstream response after Caddy's Access gate.
    if direct == forged == no_jwt == "403" and via_cloudflare == "200" and ordinary == "200":
        suite.ok("admin requires both a Cloudflare source and an Access assertion; ordinary paths stay open")
        return
    suite.bad(
        "admin boundary: "
        f"direct={direct} forged={forged} no_jwt={no_jwt} "
        f"via_cloudflare={via_cloudflare} ordinary={ordinary}"
    )
    suite.report()


def check_access_log(container: str) -> str:
    """Capture the log once, and prove the probes are in it before asserting on it."""
    log = access_log(container)
    if '"uri": "/api/config"' in log:
        suite.ok("the smoke probes reached the access log")
    else:
        suite.bad("no access log lines for the smoke probes")
        print("\n".join(log.splitlines()[-20:]), file=sys.stderr)
        suite.report()
    if f'"client_ip": "{FLY_CLIENT_IP}"' in log:
        suite.ok("Fly-Client-IP is trusted as the client address")
    else:
        suite.bad("Fly-Client-IP did not reach the access log")
        print("\n".join(line for line in log.splitlines() if '"client_ip"' in line), file=sys.stderr)
        suite.report()
    if f'"client_ip": "{CF_CONNECTING_IP}"' in log:
        suite.bad("a spoofed CF-Connecting-IP was trusted as the client address")
        suite.report()
    suite.ok("a spoofed CF-Connecting-IP is not trusted as the client address")
    return log


def check_redaction(container: str, log: str) -> None:
    """Every header the Caddyfile filters has to stay out of the access log."""
    filter_headers = re.findall(r"request>headers>(\S+) delete", (REPO_ROOT / "config" / "Caddyfile").read_text())
    if len(filter_headers) < 5:
        suite.bad(f"only {len(filter_headers)} header filter lines were found in the Caddyfile")
        suite.report()

    args = ["-H", "Host: example.com"]
    values: list[str] = []
    for header in filter_headers:
        key = header.lower()
        # Fly-Client-IP is the address Caddy parses into the log's client_ip
        # field, so its value belongs there and only its key can be asserted.
        if key == "fly-client-ip":
            continue
        if key == "x-forwarded-for":
            value = X_FORWARDED_FOR_IP
        elif key == "x-real-ip":
            value = X_REAL_IP
        else:
            value = f"smoke-{header}-{os.getpid()}"
        args += ["-H", f"{header}: {value}"]
        values.append(value)
    probe_code(container, *args, "http://127.0.0.1:8080/api/config")
    time.sleep(3)

    log = access_log(container)
    leaked = [value for value in values if value in log]
    if "fly-client-ip" in log.lower():
        leaked.append("Fly-Client-IP-header")
    if leaked:
        suite.bad(f"filtered headers reached the access log: {' '.join(leaked)}")
        suite.report()
    suite.ok(
        "every header the Caddyfile filters stays out of the access log "
        f"({len(values)} values, plus Fly-Client-IP as client_ip)"
    )


def check_query_redaction(container: str) -> None:
    """Query strings can carry one-time credentials and belong out of the log."""
    path_marker = f"smoke-query-{os.getpid()}"
    secret_marker = f"secret-query-{os.getpid()}"
    path = f"/query-probe-{path_marker}"
    query = f"token={secret_marker}&email={secret_marker}%40example.invalid"
    probe_code(container, "-H", "Host: example.com", f"http://127.0.0.1:8080{path}?{query}")
    time.sleep(3)

    log = access_log(container)
    def fail(message: str) -> None:
        suite.bad(message)
        print("\n".join(line for line in log.splitlines() if "query-probe" in line), file=sys.stderr)
        suite.report()

    if f'"uri": "{path}' not in log:
        fail("the query-redaction probe did not reach the access log")
    if secret_marker in log:
        fail("a query string value reached the access log")
    if f'"uri": "{path}?redacted"' not in log:
        fail("the access log does not retain a redacted query marker")
    suite.ok("query string values stay out of the access log")


def response_headers(container: str, *args: str) -> dict[str, str]:
    """Return the response headers, keyed case-insensitively."""
    raw = exec_in(container, "curl", "-sS", "-D", "-", "-o", "/dev/null", *args).stdout
    headers: dict[str, str] = {}
    for line in raw.splitlines():
        if ":" not in line:
            continue
        name, value = line.split(":", 1)
        headers[name.strip().lower()] = value.strip()
    return headers


def check_security_headers(container: str) -> None:
    """Every security header has to survive both a served and a denied request."""
    expected = {
        "strict-transport-security": "max-age=31536000;",
        "x-content-type-options": "nosniff",
        "x-frame-options": "DENY",
        "x-xss-protection": "1; mode=block",
        "referrer-policy": "strict-origin-when-cross-origin",
        "permissions-policy": "camera=(), microphone=(), geolocation=(), payment=()",
        "x-robots-tag": "noindex, nofollow",
    }
    expected_absent = {"server", "x-powered-by", "last-modified"}
    probes = (
        ("allowed request", "example.com", "/api/config"),
        ("host-denied request", "evil.example", "/api/config"),
    )
    for label, host, path in probes:
        actual = response_headers(
            container, "-H", f"Host: {host}", f"http://127.0.0.1:8080{path}"
        )
        wrong = [
            f"{name}={actual.get(name)!r} (want {value!r})"
            for name, value in expected.items()
            if actual.get(name) != value
        ]
        leaked = [name for name in sorted(expected_absent) if name in actual]
        if wrong or leaked:
            details = []
            if wrong:
                details.append("wrong or missing: " + ", ".join(wrong))
            if leaked:
                details.append("not removed: " + ", ".join(leaked))
            suite.bad(f"{label} security headers: {'; '.join(details)}")
            suite.report()
        suite.ok(
            f"{label} carries every configured security header "
            f"({len(expected)} set, {len(expected_absent)} removed)"
        )


def check_required_tools(image: str) -> None:
    """An apk edit that drops a tool only shows up at runtime, in production."""
    # setsid gives every captured command its own session, so the timeout can
    # signal the whole tree instead of the direct child BusyBox `timeout`
    # reaches.
    required = "bash caddy curl mail msmtp restic setsid sqlite3 su-exec tini supercronic".split()
    missing = docker(
        "run",
        "--rm",
        "--entrypoint",
        "sh",
        image,
        "-c",
        'for tool in "$@"; do command -v "$tool" >/dev/null || echo "$tool"; done',
        "sh",
        *required,
    ).stdout.split()
    if missing:
        suite.bad(f"missing from the image: {' '.join(missing)}")
        suite.report()
    suite.ok(f"the image carries every tool the stack runs ({' '.join(required)})")

    removed = "tmux overmind".split()
    present = docker(
        "run",
        "--rm",
        "--entrypoint",
        "sh",
        image,
        "-c",
        'for tool in "$@"; do command -v "$tool" >/dev/null && echo "$tool"; done',
        "sh",
        *removed,
        check=False,
    ).stdout.split()
    if present:
        suite.bad(f"obsolete process-manager tools remain in the image: {' '.join(present)}")
        suite.report()
    suite.ok("the image omits the obsolete Overmind and tmux process manager")


def check_apk_stub(work: Path, image: str) -> None:
    """A failed `apk update` must not read as "nothing to upgrade"."""
    stub_image = f"deps-apk-stub-{os.getpid()}"
    stub_container = f"deps-apk-stub-{os.getpid()}"
    images.append(stub_image)
    stub = work / "apk-stub.sh"
    stub.write_text('#!/bin/sh\ncase "$1" in\n  update) exit 1 ;;\n  version) exit 0 ;;\n  *) exec /sbin/apk.real "$@" ;;\nesac\n')
    docker("run", "--detach", "--name", stub_container, image, "sleep", "60")
    containers.append(stub_container)
    exec_in(stub_container, "mv", "/sbin/apk", "/sbin/apk.real")
    docker("cp", str(stub), f"{stub_container}:/sbin/apk")
    exec_in(stub_container, "chmod", "+x", "/sbin/apk")
    docker("commit", "--change", "ENTRYPOINT []", stub_container, stub_image)
    docker("rm", "--force", stub_container)
    containers.remove(stub_container)

    result = run(str(REPO_ROOT / "scripts" / "deps.sh"), "apk", stub_image, check=False)
    if result.returncode == 0:
        suite.bad("deps.sh apk reported success although apk update failed")
        print(combined(result), file=sys.stderr)
        suite.report()
    suite.ok("deps.sh apk fails loudly when the index refresh fails")


def check_smtp_delivery(work: Path, image: str) -> None:
    """The monthly integrity check is the one job that still reports by email."""
    global sink
    smtp_dir = work / "smtp"
    smtp_dir.mkdir()
    cert, key = smtp_dir / "cert.pem", smtp_dir / "key.pem"
    ready, message, smtp_run = smtp_dir / "port", smtp_dir / "message.txt", smtp_dir / "run.log"
    run(
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
        "-keyout", str(key), "-out", str(cert),
        "-subj", "/CN=host.docker.internal",
        "-addext", "subjectAltName=DNS:host.docker.internal,DNS:localhost,IP:127.0.0.1",
    )
    sink = subprocess.Popen(
        [
            sys.executable, str(TESTS_DIR / "smtp_sink.py"),
            "--bind", "0.0.0.0",
            "--cert", str(cert), "--key", str(key),
            "--out", str(message), "--ready", str(ready), "--timeout", "120",
        ]
    )
    for _ in range(100):
        if ready.exists() and ready.stat().st_size:
            break
        time.sleep(0.1)
    if not (ready.exists() and ready.stat().st_size):
        print("the SMTP sink never reported its port", file=sys.stderr)
        suite.report()
    port = ready.read_text().strip()

    container = f"smtp-{os.getpid()}"
    docker(
        "run", "--detach", "--name", container,
        "--add-host=host.docker.internal:host-gateway",
        "--env", "CADDY_DOMAINS=example.com",
        "--env", "DOMAIN=https://example.com",
        "--env", "I_REALLY_WANT_VOLATILE_STORAGE=true",
        "--env", "SMTP_HOST=host.docker.internal",
        "--env", f"SMTP_PORT={port}",
        "--env", "SMTP_TO=ops@example.com",
        "--env", "SMTP_USERNAME=user",
        "--env", "SMTP_PASSWORD=secret",
        image,
    )
    containers.append(container)
    up = False
    for _ in range(30):
        has_config = exec_in(container, "test", "-s", "/etc/msmtprc", check=False).returncode == 0
        if has_config and wait_for_alive(container):
            up = True
            break
        time.sleep(2)
    if not up:
        print("the alert test container never came up", file=sys.stderr)
        print(access_log(container), file=sys.stderr)
        suite.report()

    # The sink is self-signed, so the container has to trust it: msmtp reads the
    # system bundle the image already points tls_trust_file at.
    docker("cp", str(cert), f"{container}:/tmp/sink-ca.pem")
    shell_in(container, "cat /tmp/sink-ca.pem >> /etc/ssl/certs/ca-certificates.crt")

    # The hourly jobs stay on Telegram, so drive the rare email path instead:
    # point the monthly integrity check at a repository that does not exist.
    result = exec_in(
        container,
        "/restic.sh",
        "verify",
        env={"RESTIC_PASSWORD": "selftest", "RESTIC_REPOSITORY": "/tmp/no-such-repository"},
        check=False,
    )
    smtp_run.write_text(combined(result))
    for _ in range(60):
        if message.exists() and message.stat().st_size:
            break
        time.sleep(1)
    if not (message.exists() and message.stat().st_size):
        suite.bad("no message reached the SMTP sink")
        print("\n".join(smtp_run.read_text().splitlines()[:20]), file=sys.stderr)
        suite.report()
    suite.ok("a real alert reached the SMTP sink over STARTTLS")

    delivered = message.read_text(errors="replace")
    suite.same(
        "the delivered message carries the alert subject",
        True,
        "Subject: [Vaultwarden] Repository verification failed" in delivered,
    )
    if "ops@example.com" not in delivered:
        suite.bad("the delivered message lost its recipient")
        print("\n".join(delivered.splitlines()[:15]), file=sys.stderr)
        suite.report()
    suite.ok("the delivered message is addressed to the configured recipient")
    if "Alert email sent" not in smtp_run.read_text():
        suite.bad("the run did not record the delivery")
        print("\n".join(smtp_run.read_text().splitlines()[:20]), file=sys.stderr)
        suite.report()
    suite.ok("the run recorded the delivery")
    mail_log = exec_in(
        container,
        "sh",
        "-c",
        'if [ -e /data/restic-logs/msmtp.log ]; then '
        'awk -v needle="$SMTP_TO" \'index($0, needle) {count++} END {print count + 0}\' '
        '/data/restic-logs/msmtp.log; else printf "0\\n"; fi',
        env={"SMTP_TO": "ops@example.com"},
    )
    suite.same("the mailer does not persist the recipient in a delivery log", "0", mail_log.stdout.strip())
    suite.same("the alert path keeps the failing run's exit status", 2, result.returncode)


def check_restore_swap(image: str) -> None:
    """A snapshot carries the hot copy, and the entrypoint applies it on boot."""
    container = scratch(image, f"restore-swap-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data\n"
        'sqlite3 /data/backup.bak "CREATE TABLE t(v); INSERT INTO t VALUES(7);"\n'
        'printf "stale-database" > /data/db.sqlite3\n'
        'printf "stale-wal" > /data/db.sqlite3-wal\n'
        'printf "stale-journal" > /data/db.sqlite3-journal\n'
        "touch /data/restore-pending\n",
    )
    shell_in(container, "/entrypoint.sh true")
    value = exec_in(container, "sqlite3", "/data/db.sqlite3", "SELECT v FROM t", check=False).stdout.strip()
    wal_left = exec_in(container, "test", "-e", "/data/db.sqlite3-wal", check=False).returncode == 0
    journal_left = exec_in(container, "test", "-e", "/data/db.sqlite3-journal", check=False).returncode == 0
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    owner = exec_in(container, "stat", "-c", "%U", "/data/db.sqlite3", check=False).stdout.strip()
    scratch_left = exec_in(container, "test", "-e", "/data/db.sqlite3.new", check=False).returncode == 0
    if (
        value == "7"
        and not wal_left
        and not journal_left
        and not marker_left
        and owner == "vaultwarden"
        and not scratch_left
    ):
        suite.ok("an armed restore swaps backup.bak and clears every SQLite sidecar")
        return
    suite.bad("an armed restore did not swap the database cleanly")
    print(
        f"value={value} wal_left={wal_left} journal_left={journal_left} "
        f"marker_left={marker_left} owner={owner} scratch_left={scratch_left}",
        file=sys.stderr,
    )
    suite.report()


def check_restore_without_hot_copy(image: str) -> None:
    """Without the hot copy there is nothing to swap, and guessing would lose data."""
    container = scratch(image, f"restore-unarmed-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data\n"
        'printf "stale-database" > /data/db.sqlite3\n'
        "touch /data/restore-pending\n",
    )
    shell_in(container, "/entrypoint.sh true")
    content = exec_in(container, "cat", "/data/db.sqlite3", check=False).stdout.strip()
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    if content == "stale-database" and marker_left:
        suite.ok("an armed restore without backup.bak leaves the database alone")
        return
    suite.bad("an armed restore without backup.bak changed the database")
    print(f"content={content} marker_left={marker_left}", file=sys.stderr)
    suite.report()


def check_restore_with_corrupt_hot_copy(image: str) -> None:
    """A hot copy that is not a database must not replace a working one."""
    container = scratch(image, f"restore-corrupt-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data\n"
        'printf "not-a-database" > /data/backup.bak\n'
        'sqlite3 /data/db.sqlite3 "CREATE TABLE t(v); INSERT INTO t VALUES(1);"\n'
        "touch /data/restore-pending\n",
    )
    started = exec_in(container, "/entrypoint.sh", "echo", "started", check=False).stdout
    value = exec_in(container, "sqlite3", "/data/db.sqlite3", "SELECT v FROM t", check=False).stdout.strip()
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    if value == "1" and marker_left and "started" in started:
        suite.ok("an armed restore with an unreadable hot copy leaves the database alone")
        return
    suite.bad("a corrupt backup.bak replaced the live database")
    print(f"value={value} marker_left={marker_left} started={started.strip()}", file=sys.stderr)
    suite.report()


def check_restore_rejects_non_ok_integrity_output(image: str) -> None:
    """Only an integrity result of exactly `ok` may replace the live database."""
    container = scratch(image, f"restore-integrity-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data /stub\n"
        'real="$(command -v sqlite3)"\n'
        "printf '%b' '#!/bin/sh\\ncase \"$*\" in *\"PRAGMA integrity_check\"*) printf \"ok\\\\nCHECK constraint failed in t\\\\n\"; exit 0 ;; esac\\nexec '\"$real\"' \"$@\"\\n' > /stub/sqlite3\n"
        "chmod +x /stub/sqlite3\n"
        'sqlite3 /data/backup.bak "CREATE TABLE t(v); INSERT INTO t VALUES(7);"\n'
        'sqlite3 /data/db.sqlite3 "CREATE TABLE t(v); INSERT INTO t VALUES(2);"\n'
        "cp /data/db.sqlite3 /tmp/live-before\n"
        "touch /data/restore-pending\n",
    )
    started = shell_in(
        container, 'PATH="/stub:$PATH" /entrypoint.sh echo started', check=False
    )
    unchanged = (
        exec_in(
            container,
            "cmp",
            "-s",
            "/data/db.sqlite3",
            "/tmp/live-before",
            check=False,
        ).returncode
        == 0
    )
    value = exec_in(
        container, "sqlite3", "/data/db.sqlite3", "SELECT v FROM t", check=False
    ).stdout.strip()
    marker_left = (
        exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode
        == 0
    )
    scratch_left = (
        exec_in(container, "test", "-e", "/data/db.sqlite3.new", check=False).returncode
        == 0
    )
    if (
        started.returncode == 0
        and "started" in started.stdout
        and "not a readable database" in combined(started)
        and unchanged
        and value == "2"
        and marker_left
        and not scratch_left
    ):
        suite.ok("a non-ok restore integrity result keeps the live database")
        return
    suite.bad("a mixed integrity result was accepted as a healthy restore")
    print(
        f"rc={started.returncode} unchanged={unchanged} value={value} "
        f"marker_left={marker_left} scratch_left={scratch_left}",
        file=sys.stderr,
    )
    print(combined(started), file=sys.stderr)
    suite.report()


def check_restore_rejects_symlinked_hot_copy(image: str) -> None:
    """A restore input link must not make the root entrypoint read outside /data."""
    container = scratch(image, f"restore-symlink-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data /target\n"
        'sqlite3 /target/outside.sqlite3 "CREATE TABLE t(v); INSERT INTO t VALUES(9);"\n'
        'sqlite3 /data/db.sqlite3 "CREATE TABLE t(v); INSERT INTO t VALUES(2);"\n'
        "ln -s /target/outside.sqlite3 /data/backup.bak\n"
        "touch /data/restore-pending\n",
    )
    started = shell_in(container, "/entrypoint.sh echo started", check=False)
    value = exec_in(container, "sqlite3", "/data/db.sqlite3", "SELECT v FROM t", check=False).stdout.strip()
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    link_left = exec_in(container, "test", "-L", "/data/backup.bak", check=False).returncode == 0
    if (
        started.returncode == 0
        and "started" in started.stdout
        and value == "2"
        and marker_left
        and link_left
    ):
        suite.ok("a symlinked restore hot copy is refused without touching the database")
        return
    suite.bad("a symlinked restore hot copy replaced the live database")
    print(
        f"rc={started.returncode} value={value} marker_left={marker_left} link_left={link_left}",
        file=sys.stderr,
    )
    suite.report()


def check_restore_rejects_directory_destination(image: str) -> None:
    """A directory at the live database path must not become a restore target."""
    container = scratch(image, f"restore-dir-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data/db.sqlite3\n"
        'printf "live-directory" > /data/db.sqlite3/evidence\n'
        'sqlite3 /data/backup.bak "CREATE TABLE t(v); INSERT INTO t VALUES(7);"\n'
        "touch /data/restore-pending\n",
    )
    started = shell_in(container, "/entrypoint.sh echo started", check=False)
    directory_left = exec_in(container, "test", "-d", "/data/db.sqlite3", check=False).returncode == 0
    evidence = exec_in(container, "cat", "/data/db.sqlite3/evidence", check=False).stdout.strip()
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    scratch_left = exec_in(container, "test", "-e", "/data/db.sqlite3.new", check=False).returncode == 0
    nested_scratch_left = exec_in(container, "test", "-e", "/data/db.sqlite3/db.sqlite3.new", check=False).returncode == 0
    backup_left = exec_in(container, "test", "-f", "/data/backup.bak", check=False).returncode == 0
    output = combined(started)

    if (
        started.returncode == 0
        and "started" in started.stdout
        and directory_left
        and evidence == "live-directory"
        and marker_left
        and not scratch_left
        and not nested_scratch_left
        and backup_left
        and "/data/db.sqlite3 is not a regular file" in output
    ):
        suite.ok("a directory at the database path is refused without a false success")
        return
    suite.bad("a directory at the database path was treated as a restored database")
    print(
        f"rc={started.returncode} directory_left={directory_left} evidence={evidence!r} "
        f"marker_left={marker_left} scratch_left={scratch_left} "
        f"nested_scratch_left={nested_scratch_left} backup_left={backup_left}\n{output}",
        file=sys.stderr,
    )
    suite.report()


def check_restore_rejects_symlinked_destination(image: str) -> None:
    """A link at the live database path must not redirect the restore."""
    container = scratch(image, f"restore-target-link-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data /target\n"
        'sqlite3 /target/live.sqlite3 "CREATE TABLE t(v); INSERT INTO t VALUES(2);"\n'
        "ln -s /target/live.sqlite3 /data/db.sqlite3\n"
        'sqlite3 /data/backup.bak "CREATE TABLE t(v); INSERT INTO t VALUES(7);"\n'
        "touch /data/restore-pending\n",
    )
    started = shell_in(container, "/entrypoint.sh echo started", check=False)
    link_left = exec_in(container, "test", "-L", "/data/db.sqlite3", check=False).returncode == 0
    value = exec_in(container, "sqlite3", "/target/live.sqlite3", "SELECT v FROM t", check=False).stdout.strip()
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    scratch_left = exec_in(container, "test", "-e", "/data/db.sqlite3.new", check=False).returncode == 0
    backup_left = exec_in(container, "test", "-f", "/data/backup.bak", check=False).returncode == 0
    output = combined(started)

    if (
        started.returncode == 0
        and "started" in started.stdout
        and link_left
        and value == "2"
        and marker_left
        and not scratch_left
        and backup_left
        and "/data/db.sqlite3 is not a regular file" in output
    ):
        suite.ok("a symlink at the database path is refused without redirecting the restore")
        return
    suite.bad("a symlink at the database path redirected or replaced the restore target")
    print(
        f"rc={started.returncode} link_left={link_left} value={value} "
        f"marker_left={marker_left} scratch_left={scratch_left} backup_left={backup_left}\n{output}",
        file=sys.stderr,
    )
    suite.report()


def check_restore_allows_missing_destination(image: str) -> None:
    """A missing live database is a valid target for the pending restore."""
    container = scratch(image, f"restore-missing-target-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data\n"
        'sqlite3 /data/backup.bak "CREATE TABLE t(v); INSERT INTO t VALUES(7);"\n'
        "touch /data/restore-pending\n",
    )
    started = shell_in(container, "/entrypoint.sh echo started", check=False)
    value = exec_in(container, "sqlite3", "/data/db.sqlite3", "SELECT v FROM t", check=False).stdout.strip()
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    scratch_left = exec_in(container, "test", "-e", "/data/db.sqlite3.new", check=False).returncode == 0

    if (
        started.returncode == 0
        and "started" in started.stdout
        and value == "7"
        and not marker_left
        and not scratch_left
    ):
        suite.ok("a pending restore still accepts a missing database path")
        return
    suite.bad("a pending restore refused a missing database path")
    print(
        f"rc={started.returncode} value={value} marker_left={marker_left} scratch_left={scratch_left}\n"
        f"{combined(started)}",
        file=sys.stderr,
    )
    suite.report()


def check_restore_clears_stale_scratch_directory(image: str) -> None:
    """A stale reserved scratch path must not crash-loop the entrypoint."""
    container = scratch(image, f"restore-stale-scratch-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data/db.sqlite3.new/nested\n"
        'printf "stale" > /data/db.sqlite3.new/nested/file\n'
        'sqlite3 /data/backup.bak "CREATE TABLE t(v); INSERT INTO t VALUES(7);"\n'
        'sqlite3 /data/db.sqlite3 "CREATE TABLE t(v); INSERT INTO t VALUES(2);"\n'
        "touch /data/restore-pending\n",
    )
    started = shell_in(container, "/entrypoint.sh echo started", check=False)
    value = exec_in(container, "sqlite3", "/data/db.sqlite3", "SELECT v FROM t", check=False).stdout.strip()
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    scratch_left = exec_in(container, "test", "-e", "/data/db.sqlite3.new", check=False).returncode == 0
    if (
        started.returncode == 0
        and "started" in started.stdout
        and value == "7"
        and not marker_left
        and not scratch_left
    ):
        suite.ok("a stale restore scratch directory is cleared before the swap")
        return
    suite.bad("a stale restore scratch path prevented the pending restore")
    print(
        f"rc={started.returncode} value={value} marker_left={marker_left} scratch_left={scratch_left}",
        file=sys.stderr,
    )
    suite.report()


def check_restore_copy_failure(image: str) -> None:
    """A full volume must not leave the machine without a database at all."""
    container = scratch(image, f"restore-copyfail-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data /stub\n"
        'printf "#!/bin/sh\\nexit 1\\n" > /stub/cp\n'
        "chmod +x /stub/cp\n"
        'sqlite3 /data/backup.bak "CREATE TABLE t(v); INSERT INTO t VALUES(7);"\n'
        'sqlite3 /data/db.sqlite3 "CREATE TABLE t(v); INSERT INTO t VALUES(2);"\n'
        "touch /data/restore-pending\n",
    )
    shell_in(container, 'PATH="/stub:$PATH" /entrypoint.sh true', check=False)
    value = exec_in(container, "sqlite3", "/data/db.sqlite3", "SELECT v FROM t", check=False).stdout.strip()
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    if value == "2" and marker_left:
        suite.ok("a failed restore copy leaves the live database in place")
        return
    suite.bad("a failed restore copy destroyed the live database")
    print(f"value={value} marker_left={marker_left}", file=sys.stderr)
    suite.report()


def check_restore_chown_failure(image: str) -> None:
    """A failed chown is a pre-swap failure, exactly like a failed copy.

    The entrypoint runs with `set -e`, so an unguarded chown aborted it: the
    machine exited instead of keeping the database it had and starting, which
    crash-loops on a restore that cannot be applied.
    """
    container = scratch(image, f"restore-chownfail-{os.getpid()}")
    # Fail only for the scratch copy the swap creates, so the ownership fixes the
    # entrypoint makes on /data and /app still succeed. `%b` turns the escapes
    # into newlines and the single-quoted section keeps `$*` literal for the stub.
    shell_in(
        container,
        "mkdir -p /data /stub\n"
        'real="$(command -v chown)"\n'
        "printf '%b' '#!/bin/sh\\ncase \"$*\" in *db.sqlite3.new*) exit 1 ;; esac\\nexec '\"$real\"' $*\\n' > /stub/chown\n"
        "chmod +x /stub/chown\n"
        'sqlite3 /data/backup.bak "CREATE TABLE t(v); INSERT INTO t VALUES(7);"\n'
        'sqlite3 /data/db.sqlite3 "CREATE TABLE t(v); INSERT INTO t VALUES(2);"\n'
        "touch /data/restore-pending\n",
    )
    started = shell_in(container, 'PATH="/stub:$PATH" /entrypoint.sh echo started', check=False)
    value = exec_in(container, "sqlite3", "/data/db.sqlite3", "SELECT v FROM t", check=False).stdout.strip()
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    scratch_left = exec_in(container, "test", "-e", "/data/db.sqlite3.new", check=False).returncode == 0
    if (
        started.returncode == 0
        and "started" in started.stdout
        and value == "2"
        and marker_left
        and not scratch_left
    ):
        suite.ok("a failed restore chown keeps the database and still starts the app")
        return
    suite.bad("a failed restore chown aborted the entrypoint instead of starting the app")
    print(
        f"rc={started.returncode} stdout={started.stdout.strip()!r} value={value} "
        f"marker_left={marker_left} scratch_left={scratch_left}",
        file=sys.stderr,
    )
    suite.report()


def check_restore_drill_bind_policy(image: str) -> None:
    """The temporary restored server must be loopback-only with signups disabled."""
    container = start_stack(
        image,
        f"restore-policy-{os.getpid()}",
        {"SUPERVISE_RESTART_DELAY": "0.1"},
    )
    if not wait_for_alive(container):
        suite.bad("the restore-policy probe never became ready")
        print(access_log(container), file=sys.stderr)
        suite.report()

    fixture_dir = Path(tempfile.mkdtemp(prefix="restore-policy-key-"))
    temp_dirs.append(fixture_dir)
    private_key = fixture_dir / "rsa_key.pem"
    run(
        "openssl",
        "genpkey",
        "-algorithm",
        "RSA",
        "-pkeyopt",
        "rsa_keygen_bits:2048",
        "-out",
        str(private_key),
    )
    docker("cp", str(private_key), f"{container}:/data/rsa_key.pem")

    script = r"""
set -eu
rm -rf /tmp/restore-policy-repo /tmp/drill-runtime-env /tmp/drill.log /tmp/backup.log
mkdir /tmp/restore-policy-repo
chown vaultwarden:vaultwarden /tmp/restore-policy-repo
chown vaultwarden:vaultwarden /data/rsa_key.pem
RESTIC_PASSWORD=selftest RESTIC_REPOSITORY=/tmp/restore-policy-repo \
    /restic.sh backup >/tmp/backup.log 2>&1
mv /vaultwarden /vaultwarden.real
cat > /vaultwarden <<'EOF'
#!/bin/sh
printf 'ROCKET_ADDRESS=%s\nCONFIG_FILE=%s\n' \
    "${ROCKET_ADDRESS:-}" "${CONFIG_FILE:-}" > /tmp/drill-runtime-env
if [ -n "${CONFIG_FILE:-}" ] \
    && grep -Fqx '{"signups_allowed": false}' "$CONFIG_FILE"; then
    printf 'SIGNUPS_DISABLED=true\n' >> /tmp/drill-runtime-env
else
    printf 'SIGNUPS_DISABLED=false\n' >> /tmp/drill-runtime-env
fi
exec /vaultwarden.real "$@"
EOF
chmod +x /vaultwarden
RESTIC_PASSWORD=selftest RESTIC_REPOSITORY=/tmp/restore-policy-repo \
    /restic.sh restore-test >/tmp/drill.log 2>&1
grep -qx 'ROCKET_ADDRESS=127.0.0.1' /tmp/drill-runtime-env
grep -qx 'SIGNUPS_DISABLED=true' /tmp/drill-runtime-env
"""
    result = docker(
        "exec",
        container,
        "sh",
        "-c",
        script,
        check=False,
    )
    if result.returncode == 0:
        suite.ok("the restore drill is loopback-only and refuses new signups")
    else:
        suite.bad("the restore drill is reachable beyond loopback or permits new signups")
        print(combined(result), file=sys.stderr)
        logs = docker(
            "exec",
            container,
            "sh",
            "-c",
            "cat /tmp/drill.log /tmp/backup.log",
            check=False,
        )
        print(logs.stdout, file=sys.stderr)


def check_entrypoint_symlink_safety(image: str) -> None:
    """Root must not chown or chmod files reached through links under /data."""
    container = scratch(image, f"entrypoint-links-{os.getpid()}")
    shell_in(
        container,
        "rm -rf /data/*\n"
        "mkdir -p /target/logs\n"
        "printf config > /target/config.json\n"
        "printf status > /target/status\n"
        "chmod 0644 /target/config.json /target/status\n"
        "chmod 0755 /target/logs\n"
        "chown -R root:root /target\n"
        "ln -s /target/config.json /data/config.json\n"
        "ln -s /target/status /data/backup-status.txt\n"
        "ln -s /target/logs /data/restic-logs\n",
    )
    before = {
        path: exec_in(container, "stat", "-c", "%u:%g:%a", path).stdout.strip()
        for path in ("/target/config.json", "/target/status", "/target/logs")
    }
    started = shell_in(container, "/entrypoint.sh true", check=False)
    after = {
        path: exec_in(container, "stat", "-c", "%u:%g:%a", path).stdout.strip()
        for path in ("/target/config.json", "/target/status", "/target/logs")
    }

    for label, path in (
        ("config.json", "/target/config.json"),
        ("backup status", "/target/status"),
        ("log directory", "/target/logs"),
    ):
        suite.same(
            f"the entrypoint leaves a symlink target unchanged for {label}",
            before[path],
            after[path],
        )

    config_is_link = exec_in(container, "test", "-L", "/data/config.json", check=False).returncode == 0
    status_is_file = exec_in(container, "test", "-f", "/data/backup-status.txt", check=False).returncode == 0
    status_is_link = exec_in(container, "test", "-L", "/data/backup-status.txt", check=False).returncode == 0
    logs_is_dir = exec_in(container, "test", "-d", "/data/restic-logs", check=False).returncode == 0
    logs_is_link = exec_in(container, "test", "-L", "/data/restic-logs", check=False).returncode == 0
    status_meta = exec_in(container, "stat", "-c", "%U:%a", "/data/backup-status.txt", check=False).stdout.strip()
    logs_meta = exec_in(container, "stat", "-c", "%U:%a", "/data/restic-logs", check=False).stdout.strip()

    if started.returncode != 0:
        suite.bad("the entrypoint refused to start with untrusted links under /data")
    suite.same("a symlinked config.json is preserved but skipped", True, config_is_link)
    suite.same("a symlinked backup status is replaced by a regular file", True, status_is_file and not status_is_link)
    suite.same("the replacement backup status is private to vaultwarden", "vaultwarden:600", status_meta)
    suite.same("a symlinked log directory is replaced by a real directory", True, logs_is_dir and not logs_is_link)
    suite.same("the replacement log directory is private to vaultwarden", "vaultwarden:700", logs_meta)
    if suite.failures:
        print(combined(started), file=sys.stderr)


def check_legacy_mail_log_removed(image: str) -> None:
    """A legacy mailer log must be removed without following a link."""
    container = scratch(image, f"mail-log-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data/restic-logs /target\n"
        "printf sentinel > /target/mail.log\n"
        "chmod 0644 /target/mail.log\n"
        "chown root:root /target/mail.log\n"
        "ln -s /target/mail.log /data/restic-logs/msmtp.log\n",
    )
    before = exec_in(container, "stat", "-c", "%u:%g:%a", "/target/mail.log").stdout.strip()
    started = shell_in(container, "/entrypoint.sh true", check=False)
    after = exec_in(container, "stat", "-c", "%u:%g:%a", "/target/mail.log").stdout.strip()
    log_left = exec_in(container, "test", "-e", "/data/restic-logs/msmtp.log", check=False).returncode == 0

    suite.same("the legacy SMTP delivery log is removed on boot", False, log_left)
    suite.same("removing the legacy SMTP log leaves its link target unchanged", before, after)
    if started.returncode != 0:
        suite.bad("the entrypoint refused to start while removing the legacy SMTP log")
        print(combined(started), file=sys.stderr)


def check_restore_swap_failure(image: str) -> None:
    """A rename that fails must not take the live write-ahead log with it.

    The old order deleted db.sqlite3-wal and db.sqlite3-shm before the rename.
    When the rename then failed, the machine kept the old database but lost the
    log that held its committed transactions, so "leaving the database alone"
    was only half true.
    """
    container = scratch(image, f"restore-swapfail-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data /stub\n"
        'printf "#!/bin/sh\\nexit 1\\n" > /stub/mv\n'
        "chmod +x /stub/mv\n"
        'sqlite3 /data/backup.bak "CREATE TABLE t(v); INSERT INTO t VALUES(7);"\n'
        'sqlite3 /data/db.sqlite3 "CREATE TABLE t(v); INSERT INTO t VALUES(2);"\n'
        "cp /data/db.sqlite3 /tmp/live-before\n"
        'printf "live-wal" > /data/db.sqlite3-wal\n'
        'printf "live-shm" > /data/db.sqlite3-shm\n'
        "touch /data/restore-pending\n",
    )
    shell_in(container, 'PATH="/stub:$PATH" /entrypoint.sh true', check=False)
    # cmp, not sqlite3: the point of the case is that the file is untouched, and
    # a deliberately invalid WAL must not be what decides the assertion.
    unchanged = exec_in(container, "cmp", "-s", "/data/db.sqlite3", "/tmp/live-before", check=False).returncode == 0
    wal_left = exec_in(container, "test", "-e", "/data/db.sqlite3-wal", check=False).returncode == 0
    shm_left = exec_in(container, "test", "-e", "/data/db.sqlite3-shm", check=False).returncode == 0
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    scratch_left = exec_in(container, "test", "-e", "/data/db.sqlite3.new", check=False).returncode == 0
    if unchanged and wal_left and shm_left and marker_left and not scratch_left:
        suite.ok("a failed restore swap keeps the live write-ahead log")
        return
    suite.bad("a failed restore swap removed the live write-ahead log")
    print(
        f"unchanged={unchanged} wal_left={wal_left} shm_left={shm_left} "
        f"marker_left={marker_left} scratch_left={scratch_left}",
        file=sys.stderr,
    )
    suite.report()


def check_restore_unsafe_sidecar(image: str) -> None:
    """A malformed old WAL must not be replaced or abort the entrypoint."""
    container = scratch(image, f"restore-sidecar-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data/db.sqlite3-wal\n"
        'sqlite3 /data/db.sqlite3 "CREATE TABLE t(v); INSERT INTO t VALUES(2);"\n'
        "cp /data/db.sqlite3 /tmp/live-before\n"
        'sqlite3 /data/backup.bak "CREATE TABLE t(v); INSERT INTO t VALUES(7);"\n'
        'printf evidence > /data/db.sqlite3-wal/keep\n'
        "touch /data/restore-pending\n",
    )
    started = shell_in(container, "/entrypoint.sh true", check=False)
    unchanged = exec_in(container, "cmp", "-s", "/data/db.sqlite3", "/tmp/live-before", check=False).returncode == 0
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    sidecar_left = exec_in(container, "test", "-d", "/data/db.sqlite3-wal", check=False).returncode == 0
    scratch_left = exec_in(container, "test", "-e", "/data/db.sqlite3.new", check=False).returncode == 0

    if started.returncode == 0 and unchanged and marker_left and sidecar_left and not scratch_left:
        suite.ok("an unsafe old WAL is preserved without replacing the live database")
        return
    suite.bad("an unsafe old WAL was removed after the live database had been replaced")
    print(
        f"rc={started.returncode} unchanged={unchanged} marker_left={marker_left} "
        f"sidecar_left={sidecar_left} scratch_left={scratch_left}",
        file=sys.stderr,
    )
    print(combined(started), file=sys.stderr)
    suite.report()


def check_restore_unsafe_rollback_journal(image: str) -> None:
    """A malformed rollback journal must block the swap before data is replaced."""
    container = scratch(image, f"restore-journal-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data/db.sqlite3-journal\n"
        'sqlite3 /data/db.sqlite3 "CREATE TABLE t(v); INSERT INTO t VALUES(2);"\n'
        "cp /data/db.sqlite3 /tmp/live-before\n"
        'sqlite3 /data/backup.bak "CREATE TABLE t(v); INSERT INTO t VALUES(7);"\n'
        "printf evidence > /data/db.sqlite3-journal/keep\n"
        "touch /data/restore-pending\n",
    )
    started = shell_in(container, "/entrypoint.sh true", check=False)
    unchanged = exec_in(container, "cmp", "-s", "/data/db.sqlite3", "/tmp/live-before", check=False).returncode == 0
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    journal_left = exec_in(container, "test", "-d", "/data/db.sqlite3-journal", check=False).returncode == 0
    scratch_left = exec_in(container, "test", "-e", "/data/db.sqlite3.new", check=False).returncode == 0

    if started.returncode == 0 and unchanged and marker_left and journal_left and not scratch_left:
        suite.ok("an unsafe rollback journal is preserved without replacing the live database")
        return
    suite.bad("an unsafe rollback journal was ignored after the live database had been replaced")
    print(
        f"rc={started.returncode} unchanged={unchanged} marker_left={marker_left} "
        f"journal_left={journal_left} scratch_left={scratch_left}",
        file=sys.stderr,
    )
    print(combined(started), file=sys.stderr)
    suite.report()


def check_restore_removes_sidecar_symlinks(image: str) -> None:
    """The restore removes old sidecar links without touching their targets."""
    container = scratch(image, f"restore-sidecar-links-{os.getpid()}")
    shell_in(
        container,
        "mkdir -p /data /target\n"
        'printf old-wal > /target/old-wal\n'
        'printf old-shm > /target/old-shm\n'
        'printf old-journal > /target/old-journal\n'
        'sqlite3 /data/db.sqlite3 "CREATE TABLE t(v); INSERT INTO t VALUES(2);"\n'
        'sqlite3 /data/backup.bak "CREATE TABLE t(v); INSERT INTO t VALUES(7);"\n'
        "ln -s /target/old-wal /data/db.sqlite3-wal\n"
        "ln -s /target/old-shm /data/db.sqlite3-shm\n"
        "ln -s /target/old-journal /data/db.sqlite3-journal\n"
        "touch /data/restore-pending\n",
    )
    started = shell_in(container, "/entrypoint.sh true", check=False)
    value = exec_in(
        container,
        "sqlite3",
        "/data/db.sqlite3",
        "SELECT v FROM t",
        check=False,
    ).stdout.strip()
    wal_link_left = exec_in(container, "test", "-L", "/data/db.sqlite3-wal", check=False).returncode == 0
    shm_link_left = exec_in(container, "test", "-L", "/data/db.sqlite3-shm", check=False).returncode == 0
    journal_link_left = exec_in(container, "test", "-L", "/data/db.sqlite3-journal", check=False).returncode == 0
    wal_target = exec_in(container, "cat", "/target/old-wal", check=False).stdout.strip()
    shm_target = exec_in(container, "cat", "/target/old-shm", check=False).stdout.strip()
    journal_target = exec_in(container, "cat", "/target/old-journal", check=False).stdout.strip()
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0

    if (
        started.returncode == 0
        and value == "7"
        and not wal_link_left
        and not shm_link_left
        and not journal_link_left
        and wal_target == "old-wal"
        and shm_target == "old-shm"
        and journal_target == "old-journal"
        and not marker_left
    ):
        suite.ok("old sidecar links are removed without touching their targets")
        return
    suite.bad("the restore changed a sidecar symlink target or kept the old link")
    print(
        f"rc={started.returncode} value={value} wal_link_left={wal_link_left} "
        f"shm_link_left={shm_link_left} journal_link_left={journal_link_left} "
        f"wal_target={wal_target!r} shm_target={shm_target!r} "
        f"journal_target={journal_target!r} marker_left={marker_left}",
        file=sys.stderr,
    )
    print(combined(started), file=sys.stderr)
    suite.report()


def check_log_mode(image: str) -> None:
    """The caller's umask must not decide whether a run log is world-readable."""
    mode = docker(
        "run",
        "--rm",
        "--entrypoint",
        "sh",
        image,
        "-c",
        "mkdir -p /data\n"
        "umask 000\n"
        "/entrypoint.sh true >/dev/null 2>&1\n"
        "/restic.sh snapshots >/dev/null 2>&1\n"
        'stat -c %a "$(ls -t /data/restic-logs/*.log | head -n 1)"\n',
    ).stdout.strip()
    suite.same("restic run logs stay private whatever umask the caller has", "600", mode)
    if mode != "600":
        suite.report()


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: tests/runtime_smoke.py <image>", file=sys.stderr)
        return 2
    image = sys.argv[1]
    work = Path(tempfile.mkdtemp(prefix="smoke-"))
    temp_dirs.append(work)

    docker("run", "--rm", "--entrypoint", "caddy", image, "validate", "--config", "/Caddyfile", "--adapter", "caddyfile")

    # No command override: the image's own CMD is what production runs, so the
    # smoke test exercises that path (tini as PID 1) rather than a copy of it.
    container = start_stack(
        image,
        f"smoke-{os.getpid()}",
        {"SUPERVISE_RESTART_DELAY": "0.1"},
    )
    if not wait_for_alive(container):
        print("/alive never came up", file=sys.stderr)
        print(access_log(container), file=sys.stderr)
        return 1
    suite.ok("/alive responded through Caddy")

    # Caddy decides who may reach the app and who the client is; both are
    # security controls, and neither was asserted anywhere.
    check_host_whitelist(container)
    check_client_ip(container)
    check_admin_access_boundary(container)
    check_security_headers(container)
    log = check_access_log(container)
    check_redaction(container, log)
    check_query_redaction(container)
    check_process_supervision(container)

    check_apk_stub(work, image)
    check_invalid_restart_delay(image)
    check_invalid_addresses(image)
    check_services_requires_unprivileged_user(image)
    check_timeout_process_group_cleanup(image)
    check_backup_lock_error(image)
    check_freshness_uptime_read_failure(image)
    check_telegram_error_redaction(image)
    check_snapshot_argument_boundaries(image)
    check_sqlite_integrity_contract(image)
    check_restic_output_and_limit_failures(image)
    check_log_rotation_failure(image)
    check_status_write_failure(image)
    check_app_exit_stops_stack(image)
    check_required_tools(image)
    check_smtp_delivery(work, image)
    check_restore_swap(image)
    check_restore_without_hot_copy(image)
    check_restore_with_corrupt_hot_copy(image)
    check_restore_rejects_non_ok_integrity_output(image)
    check_restore_rejects_symlinked_hot_copy(image)
    check_restore_rejects_directory_destination(image)
    check_restore_rejects_symlinked_destination(image)
    check_restore_allows_missing_destination(image)
    check_restore_clears_stale_scratch_directory(image)
    check_restore_copy_failure(image)
    check_restore_chown_failure(image)
    check_restore_drill_bind_policy(image)
    check_entrypoint_symlink_safety(image)
    check_legacy_mail_log_removed(image)
    check_restore_swap_failure(image)
    check_restore_unsafe_sidecar(image)
    check_restore_unsafe_rollback_journal(image)
    check_restore_removes_sidecar_symlinks(image)
    check_log_mode(image)

    suite.report()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        cleanup()
