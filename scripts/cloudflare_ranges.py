#!/usr/bin/env python3
"""Synchronize Caddy trusted proxy ranges with Cloudflare's official lists."""

from __future__ import annotations

import argparse
from dataclasses import astuple, dataclass
import ipaddress
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
from typing import Optional, Sequence, TextIO, Union
from urllib.error import HTTPError
from urllib.request import Request, urlopen

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RANGES_FILE = REPO_ROOT / "config/cloudflare_ips.caddy"
DEFAULT_IPV4_URL = "https://www.cloudflare.com/ips-v4"
DEFAULT_IPV6_URL = "https://www.cloudflare.com/ips-v6"
MAX_RESPONSE_BYTES = 64 * 1024
MAX_RANGES_PER_FAMILY = 128
MIN_IPV4_RANGES = 10
MIN_IPV6_RANGES = 5
MIN_TOTAL_RANGES = 20
MIN_IPV4_PREFIX = 12
MIN_IPV6_PREFIX = 28
HTTP_TIMEOUT_SECONDS = 30
FETCH_ATTEMPTS = 3
FETCH_RETRY_DELAY_SECONDS = 2
RETRYABLE_HTTP_STATUSES = frozenset({408, 425, 429, 500, 502, 503, 504})
Network = Union[ipaddress.IPv4Network, ipaddress.IPv6Network]


@dataclass(frozen=True)
class SyncResult:
    changed: bool
    range_count: int
    ipv4_count: int
    ipv6_count: int
    added_count: int
    removed_count: int


def _parse_range_list(text: str, version: int, source: str) -> tuple[Network, ...]:
    networks: list[Network] = []
    seen: set[Network] = set()
    minimum = MIN_IPV4_PREFIX if version == 4 else MIN_IPV6_PREFIX
    for line_number, raw in enumerate(text.splitlines(), 1):
        value = raw.strip()
        if not value:
            continue
        try:
            network = ipaddress.ip_network(value, strict=True)
        except ValueError as exc:
            raise ValueError(f"{source}:{line_number}: invalid CIDR") from exc
        if network.version != version:
            raise ValueError(f"{source}:{line_number}: expected IPv{version}, got IPv{network.version}")
        if network.prefixlen < minimum:
            raise ValueError(f"{source}:{line_number}: prefix is wider than /{minimum}")
        if not network.is_global:
            raise ValueError(f"{source}:{line_number}: range is not globally routable")
        if network in seen:
            raise ValueError(f"{source}:{line_number}: duplicate range")
        if any(network.overlaps(other) for other in networks):
            raise ValueError(f"{source}:{line_number}: range overlaps another range")
        if len(networks) >= MAX_RANGES_PER_FAMILY:
            raise ValueError(f"{source}: more than {MAX_RANGES_PER_FAMILY} ranges")
        seen.add(network)
        networks.append(network)
    if not networks:
        raise ValueError(f"{source}: no ranges returned")
    return tuple(networks)


def _read_ranges_file(path: Path) -> tuple[list[str], tuple[Network, ...]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.startswith("client_ip "))
    except StopIteration as exc:
        raise ValueError(f"{path}: no client_ip entries found") from exc
    current: list[Network] = []
    seen: set[Network] = set()
    for line_number, line in enumerate(lines[start:], start + 1):
        if not line.strip():
            continue
        if not line.startswith("client_ip "):
            raise ValueError(f"{path}:{line_number}: unexpected content after ranges")
        try:
            network = ipaddress.ip_network(line.removeprefix("client_ip ").strip(), strict=True)
        except ValueError as exc:
            raise ValueError(f"{path}:{line_number}: invalid CIDR") from exc
        if network in seen:
            raise ValueError(f"{path}:{line_number}: duplicate range")
        seen.add(network)
        current.append(network)
    if not current:
        raise ValueError(f"{path}: no client_ip entries found")
    return lines[:start], tuple(current)


def _atomic_write(path: Path, text: str) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, stat.S_IMODE(path.stat().st_mode))
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)


def sync_ranges(path: Path, ipv4_text: str, ipv6_text: str, *, write: bool = True) -> SyncResult:
    ipv4 = _parse_range_list(ipv4_text, 4, "Cloudflare IPv4")
    ipv6 = _parse_range_list(ipv6_text, 6, "Cloudflare IPv6")
    if len(ipv4) < MIN_IPV4_RANGES:
        raise ValueError(f"Cloudflare IPv4: {len(ipv4)} ranges is below minimum {MIN_IPV4_RANGES}")
    if len(ipv6) < MIN_IPV6_RANGES:
        raise ValueError(f"Cloudflare IPv6: {len(ipv6)} ranges is below minimum {MIN_IPV6_RANGES}")
    if len(ipv4) + len(ipv6) < MIN_TOTAL_RANGES:
        raise ValueError(f"Cloudflare: {len(ipv4) + len(ipv6)} ranges is below minimum {MIN_TOTAL_RANGES}")
    official = ipv4 + ipv6
    header, current = _read_ranges_file(path)
    current_set, official_set = set(current), set(official)
    changed = current_set != official_set
    if changed and write:
        prefix = "\n".join(header).rstrip()
        rules = "\n".join(f"client_ip {network}" for network in official)
        _atomic_write(path, f"{prefix}\n\n{rules}\n")
    return SyncResult(changed, len(official), len(ipv4), len(ipv6),
                      len(official_set - current_set), len(current_set - official_set))


def _fetch_once(url: str) -> str:
    request = Request(url, headers={"User-Agent": "vaultwarden-range-sync/1"})
    with urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
        body = response.read(MAX_RESPONSE_BYTES + 1)
    if len(body) > MAX_RESPONSE_BYTES:
        raise ValueError(f"{url}: response exceeds {MAX_RESPONSE_BYTES} bytes")
    return body.decode("utf-8", errors="strict")


def _fetch_text(url: str) -> str:
    for attempt in range(1, FETCH_ATTEMPTS + 1):
        try:
            return _fetch_once(url)
        except HTTPError as exc:
            retryable = exc.code in RETRYABLE_HTTP_STATUSES
            exc.close()
            if not retryable or attempt == FETCH_ATTEMPTS:
                raise
        except OSError:
            if attempt == FETCH_ATTEMPTS:
                raise
        time.sleep(FETCH_RETRY_DELAY_SECONDS * 2 ** (attempt - 1))
    raise AssertionError("unreachable fetch retry state")


def _write_outputs(result: SyncResult, handle: TextIO) -> None:
    fields = ("changed", "range_count", "ipv4_count", "ipv6_count", "added_count", "removed_count")
    for key, value in zip(fields, astuple(result)):
        print(f"{key}={str(value).lower()}", file=handle)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    sync = subparsers.add_parser("sync", help="fetch, validate and synchronize ranges")
    sync.add_argument("--file", type=Path, default=DEFAULT_RANGES_FILE)
    sync.add_argument("--ipv4-url", default=os.environ.get("CF_IPV4_URL", DEFAULT_IPV4_URL))
    sync.add_argument("--ipv6-url", default=os.environ.get("CF_IPV6_URL", DEFAULT_IPV6_URL))
    sync.add_argument("--github-output", type=Path)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        result = sync_ranges(args.file, _fetch_text(args.ipv4_url), _fetch_text(args.ipv6_url))
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"cloudflare ranges: {exc}", file=sys.stderr)
        return 1
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as handle:
            _write_outputs(result, handle)
    else:
        _write_outputs(result, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
