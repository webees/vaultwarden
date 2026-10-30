#!/usr/bin/env python3
"""Run bounded, same-host performance checks against the built image."""

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
import ipaddress
import json
import math
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time
import tracemalloc
from urllib.error import URLError
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cloudflare_ranges  # noqa: E402


@dataclass(frozen=True)
class Result:
    name: str
    baseline_median_ms: float | None
    median_ms: float
    p95_ms: float
    peak_bytes: int
    peak_budget_bytes: int
    budget_ms: float
    baseline_delta_percent: float | None

    @property
    def passed(self) -> bool:
        return (
            self.median_ms <= self.budget_ms
            and self.p95_ms <= self.budget_ms * 1.5
            and self.peak_bytes > 0
            and self.peak_bytes <= self.peak_budget_bytes
            and self.baseline_within_tolerance
        )

    @property
    def baseline_within_tolerance(self) -> bool:
        if self.baseline_median_ms is None:
            return True
        tolerance_ms = max(2.0, self.baseline_median_ms * 0.10)
        return self.median_ms <= self.baseline_median_ms + tolerance_ms


@dataclass(frozen=True)
class Sample:
    elapsed_ms: float
    peak_bytes: int


def p95(values: list[float]) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)]


def measure(operation, samples: int) -> list[Sample]:
    for _ in range(2):
        operation()
    tracemalloc.start()
    try:
        measured = []
        for _ in range(max(5, samples)):
            tracemalloc.reset_peak()
            started = time.perf_counter_ns()
            operation()
            elapsed = (time.perf_counter_ns() - started) / 1_000_000
            measured.append(Sample(elapsed, tracemalloc.get_traced_memory()[1]))
    finally:
        tracemalloc.stop()
    return measured


def summarize(
    name: str,
    measured: list[Sample],
    budget_ms: float,
    peak_budget_bytes: int,
    baseline_median_ms: float | None = None,
) -> Result:
    median = statistics.median(item.elapsed_ms for item in measured)
    delta = (
        (median - baseline_median_ms) / baseline_median_ms * 100
        if baseline_median_ms is not None
        else None
    )
    return Result(
        name=name,
        baseline_median_ms=baseline_median_ms,
        median_ms=median,
        p95_ms=p95([item.elapsed_ms for item in measured]),
        peak_bytes=max(item.peak_bytes for item in measured),
        peak_budget_bytes=peak_budget_bytes,
        budget_ms=budget_ms,
        baseline_delta_percent=delta,
    )


def load_baseline(path: Path) -> dict[str, float]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise ValueError("baseline must be a JSON object")
    baseline: dict[str, float] = {}
    for name, value in document.items():
        if not isinstance(name, str) or not isinstance(value, (int, float)) or value <= 0:
            raise ValueError("baseline entries must be positive numbers keyed by scenario name")
        baseline[name] = float(value)
    return baseline


def apply_baseline(result: Result, baseline: dict[str, float]) -> Result:
    reference = baseline.get(result.name)
    if reference is None:
        raise ValueError(f"baseline is missing scenario: {result.name}")
    delta = (result.median_ms - reference) / reference * 100
    return replace(result, baseline_median_ms=reference, baseline_delta_percent=delta)


def require_temporary_path(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    roots = {Path("/tmp"), Path(os.environ.get("TMPDIR", "/tmp"))}
    if not any(resolved.is_relative_to(root.resolve()) for root in roots):
        raise ValueError("baseline files must stay under the system temporary directory")
    return resolved


def temporary_root() -> tempfile.TemporaryDirectory[str]:
    return tempfile.TemporaryDirectory(
        prefix="vaultwarden-audit-", dir=os.environ.get("TMPDIR", "/tmp")
    )


def cloudflare_ranges_from_config() -> tuple[str, str]:
    values = [
        line.split(maxsplit=1)[1]
        for line in (ROOT / "config/cloudflare_ips.caddy").read_text(encoding="utf-8").splitlines()
        if line.startswith("client_ip ")
    ]
    ipv4 = [value for value in values if ipaddress.ip_network(value).version == 4]
    ipv6 = [value for value in values if ipaddress.ip_network(value).version == 6]
    if len(ipv4) < cloudflare_ranges.MIN_IPV4_RANGES or len(ipv6) < cloudflare_ranges.MIN_IPV6_RANGES:
        raise AssertionError("checked-in Cloudflare ranges no longer satisfy parser minimums")
    return "\n".join(ipv4) + "\n", "\n".join(ipv6) + "\n"


def benchmark_cidr(samples: int) -> Result:
    ipv4, ipv6 = cloudflare_ranges_from_config()
    expected = len(ipv4.splitlines()) + len(ipv6.splitlines())

    def parse() -> None:
        parsed = cloudflare_ranges._parse_range_list(ipv4, 4, "audit-ipv4")
        parsed += cloudflare_ranges._parse_range_list(ipv6, 6, "audit-ipv6")
        if len(parsed) != expected:
            raise AssertionError("CIDR parser lost a checked-in range")

    measured = measure(parse, samples)
    return summarize("Cloudflare CIDR parse", measured, 10.0, 32 * 1024**2)


def build_database(path: Path) -> None:
    connection = sqlite3.connect(path)
    try:
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("CREATE TABLE audit(id INTEGER PRIMARY KEY, payload BLOB NOT NULL)")
        payload = bytes(range(256)) * 8
        connection.executemany(
            "INSERT INTO audit(payload) VALUES (?)", ((payload,) for _ in range(4096))
        )
        connection.commit()
        connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        connection.execute("PRAGMA journal_mode=DELETE")
    finally:
        connection.close()


def benchmark_sqlite(samples: int) -> Result:
    with temporary_root() as temporary:
        root = Path(temporary)
        source = root / "source.sqlite3"
        backup = root / "backup.sqlite3"
        build_database(source)

        def run() -> None:
            backup.unlink(missing_ok=True)
            source_connection = sqlite3.connect(source)
            target_connection = sqlite3.connect(backup)
            try:
                source_connection.backup(target_connection)
                integrity = target_connection.execute("PRAGMA integrity_check").fetchone()
                rows = target_connection.execute("SELECT count(*) FROM audit").fetchone()
            finally:
                target_connection.close()
                source_connection.close()
            if integrity != ("ok",) or rows != (4096,):
                raise AssertionError("SQLite backup or integrity check is incomplete")

        measured = measure(run, samples)
    return summarize("SQLite backup + integrity", measured, 1500.0, 64 * 1024**2)


def benchmark_isolated_restore(samples: int) -> Result:
    with temporary_root() as temporary:
        root = Path(temporary)
        source = root / "source.sqlite3"
        restore_root = root / "restore"
        build_database(source)

        def run() -> None:
            shutil.rmtree(restore_root, ignore_errors=True)
            restore_root.mkdir()
            restored = restore_root / "db.sqlite3"
            shutil.copyfile(source, restored)
            connection = sqlite3.connect(f"file:{restored}?mode=ro", uri=True)
            try:
                integrity = connection.execute("PRAGMA integrity_check").fetchone()
                tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            finally:
                connection.close()
            if integrity != ("ok",) or "audit" not in tables or source == restored:
                raise AssertionError("isolated restore did not produce an independent database")

        measured = measure(run, samples)
    return summarize("Isolated restore plan", measured, 1000.0, 64 * 1024**2)


def docker(*args: str, timeout: float = 30, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["docker", *args], capture_output=True, text=True, timeout=timeout, check=False
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or f"docker {' '.join(args)} failed")
    return result


MEMORY = re.compile(r"([0-9.]+)\s*(B|KiB|MiB|GiB)")


class MemoryUnavailable(ValueError):
    pass


def parse_docker_memory(output: str) -> int:
    match = MEMORY.search(output)
    if not match:
        raise ValueError("docker stats did not return a memory value")
    scale = {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3}
    value = int(float(match.group(1)) * scale[match.group(2)])
    if value <= 0:
        raise MemoryUnavailable("docker stats returned a non-positive memory value")
    return value


def docker_memory_bytes(container: str) -> int:
    result = docker("stats", "--no-stream", "--format", "{{.MemUsage}}", container, check=False)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"cannot read memory for {container}")
    return parse_docker_memory(result.stdout)


def run_to_exit(container: str, timeout: float = 60, peak: int = 0) -> tuple[int, str, int]:
    if peak <= 0:
        peak = docker_memory_bytes(container)
    deadline = time.monotonic() + timeout
    while True:
        running = docker("inspect", "-f", "{{.State.Running}}", container, check=False)
        if running.returncode or running.stdout.strip() != "true":
            break
        if time.monotonic() >= deadline:
            logs = docker("logs", container, check=False)
            docker("kill", container, check=False)
            output = f"{logs.stdout}{logs.stderr}".strip()
            raise AssertionError(f"container {container} exceeded {timeout:.0f}s: {output}")
        try:
            peak = max(peak, docker_memory_bytes(container))
        except MemoryUnavailable:
            pass
        time.sleep(0.05)
    status = int(docker("wait", container, timeout=30).stdout.strip())
    logs = docker("logs", container, check=False)
    return status, f"{logs.stdout}{logs.stderr}", peak


def benchmark_readiness(image: str, samples: int) -> Result:
    samples_out: list[Sample] = []
    for _ in range(samples):
        name = f"vaultwarden-audit-{secrets.token_hex(6)}"
        started = time.perf_counter_ns()
        try:
            docker(
                "run", "--rm", "--detach", "--name", name, "--memory", "256m",
                "--publish", "127.0.0.1::8080",
                "--env", "CADDY_DOMAINS=example.com",
                "--env", "DOMAIN=https://example.com",
                "--env", "SIGNUPS_ALLOWED=false",
                "--env", "I_REALLY_WANT_VOLATILE_STORAGE=true",
                "--env", f"ADMIN_TOKEN={'A' * 64}", image,
            )
            mapping = docker("port", name, "8080/tcp").stdout.strip().splitlines()[0]
            port = int(mapping.rsplit(":", 1)[1])
            deadline = time.monotonic() + 15
            peak = 0
            while time.monotonic() < deadline:
                peak = max(peak, docker_memory_bytes(name))
                try:
                    with urlopen(f"http://127.0.0.1:{port}/alive", timeout=1) as response:
                        if response.status == 200:
                            break
                except (URLError, OSError):
                    time.sleep(0.05)
            else:
                logs = docker("logs", name, check=False)
                output = f"{logs.stdout}{logs.stderr}".strip()
                raise AssertionError(
                    f"container {name} did not become ready: {output}"
                )
            elapsed = (time.perf_counter_ns() - started) / 1_000_000
            samples_out.append(Sample(elapsed, peak))
        finally:
            docker("rm", "-f", name, check=False)
    return summarize(
        "Container readiness",
        samples_out,
        10_000.0,
        192 * 1024**2,
    )


def benchmark_log_trim(image: str, samples: int) -> Result:
    script = r"""
set -eu
mkdir -p /data/restic-logs
chown -R vaultwarden:vaultwarden /data
rm -f /tmp/audit-stop /tmp/audit-rss-peak
touch /tmp/audit-ready
while [ ! -e /tmp/audit-start ]; do sleep 0.01; done
(
    set +e
    peak=0
    while [ ! -e /tmp/audit-stop ]; do
        rss=$(awk '/^VmRSS:/{sum += $2} END {print sum + 0}' /proc/[0-9]*/status 2>/dev/null)
        rss=${rss:-0}
        [ "$rss" -le "$peak" ] || peak=$rss
        sleep 0.02
    done
    printf '%s\n' "$peak" > /tmp/audit-rss-peak
) & monitor=$!
dd if=/dev/zero of=/data/restic-logs/audit.log bs=1024 count=600 2>/dev/null
chown vaultwarden:vaultwarden /data/restic-logs/audit.log
RESTIC_LOG_MAX_BYTES=262144 RESTIC_LOG_DIR_MAX_BYTES=1048576 BACKUP_MAX_USAGE_PERCENT=100 /restic.sh check-disk >/dev/null
size=$(wc -c < /data/restic-logs/audit.log)
[ "$size" -le 262144 ]
: > /tmp/audit-stop
wait "$monitor"
printf 'max_log_bytes=%s rss_peak_bytes=%s\n' "$size" "$(( $(cat /tmp/audit-rss-peak) * 1024 ))"
"""
    samples_out: list[Sample] = []
    for _ in range(samples):
        name = f"vaultwarden-audit-{secrets.token_hex(6)}"
        try:
            docker(
                "run", "--detach", "--name", name, "--memory", "256m",
                image, "/bin/bash", "-c", script,
            )
            deadline = time.monotonic() + 10
            while docker("exec", name, "test", "-e", "/tmp/audit-ready", check=False).returncode:
                if time.monotonic() >= deadline:
                    raise AssertionError("log trim benchmark did not become ready")
                time.sleep(0.02)
            peak = docker_memory_bytes(name)
            started = time.perf_counter_ns()
            docker("exec", name, "touch", "/tmp/audit-start")
            status, output, measured_peak = run_to_exit(name, peak=peak)
            if status != 0 or "max_log_bytes=" not in output:
                raise AssertionError(f"log trim failed with status {status}: {output.strip()}")
            rss_match = re.search(r"rss_peak_bytes=(\d+)", output)
            if not rss_match:
                raise AssertionError(f"log trim memory measurement is missing: {output.strip()}")
            peak = max(measured_peak, int(rss_match.group(1)))
            elapsed = (time.perf_counter_ns() - started) / 1_000_000
            samples_out.append(Sample(elapsed, peak))
        finally:
            docker("rm", "-f", name, check=False)
    return summarize(
        "Log truncation",
        samples_out,
        3000.0,
        192 * 1024**2,
    )


def print_result(result: Result) -> None:
    baseline = "n/a" if result.baseline_median_ms is None else f"{result.baseline_median_ms:.3f}ms"
    delta = "n/a" if result.baseline_delta_percent is None else f"{result.baseline_delta_percent:+.1f}%"
    print(
        f"{result.name}: baseline={baseline} "
        f"median={result.median_ms:.3f}ms p95={result.p95_ms:.3f}ms "
        f"delta={delta} peak={result.peak_bytes}/"
        f"{result.peak_budget_bytes} "
        f"budget={result.budget_ms:.0f}ms {'PASS' if result.passed else 'FAIL'}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", help="Docker image built from this repository")
    parser.add_argument("--samples", type=int, default=7)
    baseline_group = parser.add_mutually_exclusive_group()
    baseline_group.add_argument("--baseline", type=Path, help="compare medians with a same-host JSON baseline")
    baseline_group.add_argument("--write-baseline", type=Path, help="write measured medians for a later comparison")
    args = parser.parse_args()
    if args.samples < 5:
        parser.error("--samples must be at least 5")
    try:
        if args.baseline:
            args.baseline = require_temporary_path(args.baseline)
        if args.write_baseline:
            args.write_baseline = require_temporary_path(args.write_baseline)
    except ValueError as error:
        parser.error(str(error))
    if not shutil.which("docker"):
        print("docker is required for black-box performance checks", file=sys.stderr)
        return 2
    print(f"host={platform.platform()} cpu_count={os.cpu_count()} samples={args.samples}")
    results = [
        benchmark_cidr(args.samples),
        benchmark_sqlite(args.samples),
        benchmark_isolated_restore(args.samples),
        benchmark_readiness(args.image, args.samples),
        benchmark_log_trim(args.image, args.samples),
    ]
    if args.baseline:
        baseline = load_baseline(args.baseline)
        results = [apply_baseline(result, baseline) for result in results]
    if args.write_baseline:
        payload = {result.name: result.median_ms for result in results}
        args.write_baseline.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    for result in results:
        print_result(result)
    return 0 if all(result.passed for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
