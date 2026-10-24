#!/usr/bin/env python3
"""Synchronize Caddy trusted proxy ranges with Cloudflare's official lists."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import ipaddress
import os
from pathlib import Path
import stat
import sys
import tempfile
from typing import Optional, Sequence, TextIO, Union
from urllib.request import Request, urlopen


DEFAULT_RANGES_FILE = Path("config/cloudflare_ips.caddy")
DEFAULT_IPV4_URL = "https://www.cloudflare.com/ips-v4"
DEFAULT_IPV6_URL = "https://www.cloudflare.com/ips-v6"
MAX_RESPONSE_BYTES = 64 * 1024
MAX_RANGES_PER_FAMILY = 128
HTTP_TIMEOUT_SECONDS = 30

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
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        value = raw_line.strip()
        if not value:
            continue
        try:
            network = ipaddress.ip_network(value, strict=True)
        except ValueError as exc:
            raise ValueError(f"{source}:{line_number}: invalid CIDR") from exc
        if network.version != version:
            raise ValueError(
                f"{source}:{line_number}: expected IPv{version}, got IPv{network.version}"
            )
        if network in seen:
            raise ValueError(f"{source}:{line_number}: duplicate range")
        if len(networks) >= MAX_RANGES_PER_FAMILY:
            raise ValueError(f"{source}: more than {MAX_RANGES_PER_FAMILY} ranges")
        seen.add(network)
        networks.append(network)
    if not networks:
        raise ValueError(f"{source}: no ranges returned")
    return tuple(networks)


def _read_ranges_file(path: Path) -> tuple[list[str], tuple[Network, ...]]:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    try:
        first_rule = next(
            index for index, line in enumerate(lines) if line.startswith("client_ip ")
        )
    except StopIteration as exc:
        raise ValueError(f"{path}: no client_ip entries found") from exc

    header = lines[:first_rule]
    current: list[Network] = []
    seen: set[Network] = set()
    for line_number, line in enumerate(lines[first_rule:], start=first_rule + 1):
        if not line.strip():
            continue
        if not line.startswith("client_ip "):
            raise ValueError(f"{path}:{line_number}: unexpected content after ranges")
        value = line.removeprefix("client_ip ").strip()
        try:
            network = ipaddress.ip_network(value, strict=True)
        except ValueError as exc:
            raise ValueError(f"{path}:{line_number}: invalid CIDR") from exc
        if network in seen:
            raise ValueError(f"{path}:{line_number}: duplicate range")
        seen.add(network)
        current.append(network)
    if not current:
        raise ValueError(f"{path}: no client_ip entries found")
    return header, tuple(current)


def _render_ranges_file(header: Sequence[str], networks: Sequence[Network]) -> str:
    prefix = "\n".join(header).rstrip()
    rules = "\n".join(f"client_ip {network}" for network in networks)
    return f"{prefix}\n{rules}\n"


def _atomic_write(path: Path, text: str) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    descriptor, temporary = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def sync_ranges(
    path: Path, ipv4_text: str, ipv6_text: str, *, write: bool = True
) -> SyncResult:
    ipv4 = _parse_range_list(ipv4_text, 4, "Cloudflare IPv4")
    ipv6 = _parse_range_list(ipv6_text, 6, "Cloudflare IPv6")
    official = ipv4 + ipv6
    header, current = _read_ranges_file(path)

    current_set = set(current)
    official_set = set(official)
    changed = current_set != official_set
    if changed and write:
        _atomic_write(path, _render_ranges_file(header, official))

    return SyncResult(
        changed=changed,
        range_count=len(official),
        ipv4_count=len(ipv4),
        ipv6_count=len(ipv6),
        added_count=len(official_set - current_set),
        removed_count=len(current_set - official_set),
    )


def _fetch_text(url: str) -> str:
    request = Request(url, headers={"User-Agent": "vaultwarden-range-sync/1"})
    with urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
        body = response.read(MAX_RESPONSE_BYTES + 1)
    if len(body) > MAX_RESPONSE_BYTES:
        raise ValueError(f"{url}: response exceeds {MAX_RESPONSE_BYTES} bytes")
    return body.decode("utf-8", errors="strict")


def _write_outputs(result: SyncResult, handle: TextIO) -> None:
    values = {
        "changed": str(result.changed).lower(),
        "range_count": result.range_count,
        "ipv4_count": result.ipv4_count,
        "ipv6_count": result.ipv6_count,
        "added_count": result.added_count,
        "removed_count": result.removed_count,
    }
    for key, value in values.items():
        print(f"{key}={value}", file=handle)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    sync = subparsers.add_parser("sync", help="fetch, validate and synchronize ranges")
    sync.add_argument("--file", type=Path, default=DEFAULT_RANGES_FILE)
    sync.add_argument(
        "--ipv4-url", default=os.environ.get("CF_IPV4_URL", DEFAULT_IPV4_URL)
    )
    sync.add_argument(
        "--ipv6-url", default=os.environ.get("CF_IPV6_URL", DEFAULT_IPV6_URL)
    )
    sync.add_argument("--github-output", type=Path)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command != "sync":
            raise ValueError(f"unsupported command: {args.command}")
        result = sync_ranges(
            args.file, _fetch_text(args.ipv4_url), _fetch_text(args.ipv6_url)
        )
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
