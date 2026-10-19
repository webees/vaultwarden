#!/usr/bin/env python3
"""Boot an image and run the checks that only exist at container runtime.

The Caddyfile has to validate, the Overmind stack has to come up unprivileged,
the backup paths have to work inside the image, and the proxy has to keep
credentials out of its access log. Shared by the validate and build workflows so
the merge path tests the exact digest it publishes.

Usage: tests/runtime-smoke.py <image>

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

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lib import Suite  # noqa: E402 - the import path above has to be set first

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent

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
    probe_code(container, "-H", "Host: example.com", "-H", "Fly-Client-IP: 203.0.113.9", "http://127.0.0.1:8080/api/config")
    probe_code(container, "-H", "Host: example.com", "-H", "CF-Connecting-IP: 203.0.113.99", "http://127.0.0.1:8080/api/config")


def check_access_log(container: str) -> str:
    """Capture the log once, and prove the probes are in it before asserting on it."""
    log = access_log(container)
    if '"uri": "/api/config"' in log:
        suite.ok("the smoke probes reached the access log")
    else:
        suite.bad("no access log lines for the smoke probes")
        print("\n".join(log.splitlines()[-20:]), file=sys.stderr)
        suite.report()
    if '"client_ip": "203.0.113.9"' in log:
        suite.ok("Fly-Client-IP is trusted as the client address")
    else:
        suite.bad("Fly-Client-IP did not reach the access log")
        print("\n".join(line for line in log.splitlines() if '"client_ip"' in line), file=sys.stderr)
        suite.report()
    if '"client_ip": "203.0.113.99"' in log:
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
            value = "198.51.100.11"
        elif key == "x-real-ip":
            value = "198.51.100.12"
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


def check_required_tools(image: str) -> None:
    """An apk edit that drops a tool only shows up at runtime, in production."""
    required = "bash caddy curl mail msmtp restic sqlite3 su-exec tini tmux supercronic overmind".split()
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
    """Email is the only channel that reports a broken backup end to end."""
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
            sys.executable, str(TESTS_DIR / "smtp-sink.py"),
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

    # A stale freshness check is the cheapest real failure path that sends mail.
    result = exec_in(
        container,
        "/restic.sh",
        "check-freshness",
        env={"RESTIC_PASSWORD": "selftest", "BACKUP_MAX_AGE": "1"},
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
    suite.same("the delivered message carries the alert subject", True, "Subject: [Vaultwarden] Backup stale" in delivered)
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
        "touch /data/restore-pending\n",
    )
    shell_in(container, "/entrypoint.sh true")
    value = exec_in(container, "sqlite3", "/data/db.sqlite3", "SELECT v FROM t", check=False).stdout.strip()
    wal_left = exec_in(container, "test", "-e", "/data/db.sqlite3-wal", check=False).returncode == 0
    marker_left = exec_in(container, "test", "-e", "/data/restore-pending", check=False).returncode == 0
    owner = exec_in(container, "stat", "-c", "%U", "/data/db.sqlite3", check=False).stdout.strip()
    scratch_left = exec_in(container, "test", "-e", "/data/db.sqlite3.new", check=False).returncode == 0
    if value == "7" and not wal_left and not marker_left and owner == "vaultwarden" and not scratch_left:
        suite.ok("an armed restore swaps backup.bak in before the app starts")
        return
    suite.bad("an armed restore did not swap the database cleanly")
    print(
        f"value={value} wal_left={wal_left} marker_left={marker_left} owner={owner} scratch_left={scratch_left}",
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
        print("usage: tests/runtime-smoke.py <image>", file=sys.stderr)
        return 2
    image = sys.argv[1]
    work = Path(tempfile.mkdtemp(prefix="smoke-"))
    temp_dirs.append(work)

    docker("run", "--rm", "--entrypoint", "caddy", image, "validate", "--config", "/Caddyfile", "--adapter", "caddyfile")

    # No command override: the image's own CMD is what production runs, so the
    # smoke test exercises that path (tini as PID 1) rather than a copy of it.
    container = start_stack(image, f"smoke-{os.getpid()}")
    if not wait_for_alive(container):
        print("/alive never came up", file=sys.stderr)
        print(access_log(container), file=sys.stderr)
        return 1
    suite.ok("/alive responded through Caddy")

    # Caddy decides who may reach the app and who the client is; both are
    # security controls, and neither was asserted anywhere.
    check_host_whitelist(container)
    check_client_ip(container)
    log = check_access_log(container)
    check_redaction(container, log)

    docker("cp", str(TESTS_DIR / "lib.sh"), f"{container}:/tmp/lib.sh")
    docker("cp", str(TESTS_DIR / "image-selftest.sh"), f"{container}:/tmp/image-selftest.sh")
    docker("exec", container, "sh", "/tmp/image-selftest.sh", stream=True)

    check_apk_stub(work, image)
    check_required_tools(image)
    check_smtp_delivery(work, image)
    check_restore_swap(image)
    check_restore_without_hot_copy(image)
    check_restore_with_corrupt_hot_copy(image)
    check_restore_copy_failure(image)
    check_log_mode(image)

    suite.report()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        cleanup()
