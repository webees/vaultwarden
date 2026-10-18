#!/bin/bash
# Reproducible checks for the helper scripts. No network, no restic repository
# and no production access: every case runs against a local fixture.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

failures=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
# BSD stat and GNU stat disagree about -f, so pick the flag per platform.
file_mode() {
    case "$(uname -s)" in
        Darwin) stat -f '%Lp' "$1" ;;
        *)      stat -c '%a' "$1" ;;
    esac
}

# ── supervise.sh ──────────────────────────────────────────────────────────────
echo "--- supervise.sh"
counter="$work/supervise.count"
: > "$counter"
SUPERVISE_RESTART_DELAY=0.05 ./scripts/supervise.sh probe \
    sh -c "printf 'run\n' >> \"$counter\"; exit 7" 2>"$work/supervise.err" &
supervisor=$!
sleep 1
kill -TERM "$supervisor" 2>/dev/null
wait "$supervisor"
supervisor_status=$?
runs="$(wc -l < "$counter" | tr -d ' ')"
if [ "$runs" -ge 2 ]; then
    ok "restarts a child that exits non-zero (${runs} runs observed)"
else
    bad "did not restart the child (${runs} runs observed)"
fi
same "exits with status 0 on SIGTERM" 0 "$supervisor_status"

# ── refresh-cloudflare-ips.sh ─────────────────────────────────────────────────
echo "--- refresh-cloudflare-ips.sh"
# Build a stub `curl` that answers with exactly N ranges per call.
# shellcheck disable=SC2016  # the $i belongs to the generated stub, not here
fake_curl() { # dir, ranges-per-call
    mkdir -p "$1"
    {
        printf '#!/bin/sh\n'
        printf 'i=0\n'
        printf 'while [ "$i" -lt %s ]; do\n' "$2"
        printf '    printf "10.0.%%s.0/24\\n" "$i"\n'
        printf '    i=$((i + 1))\n'
        printf 'done\n'
    } > "$1/curl"
    chmod +x "$1/curl"
}

cf="$work/cf"
mkdir -p "$cf/scripts" "$cf/config"
cp scripts/refresh-cloudflare-ips.sh "$cf/scripts/"
printf 'client_ip 203.0.113.0/24\n' > "$cf/config/cloudflare-ips.caddy"
seeded="$(cksum < "$cf/config/cloudflare-ips.caddy")"
target="$cf/config/cloudflare-ips.caddy"

fake_curl "$work/shim-low" 3
( cd / && PATH="$work/shim-low:$PATH" "$cf/scripts/refresh-cloudflare-ips.sh" ) \
    >"$work/low.out" 2>&1
low_status=$?
same "refuses a truncated Cloudflare response" 1 "$low_status"
same "keeps the existing list when the fetch is truncated" "$seeded" \
    "$(cksum < "$target")"

fake_curl "$work/shim-high" 12
( cd / && PATH="$work/shim-high:$PATH" "$cf/scripts/refresh-cloudflare-ips.sh" ) \
    >"$work/high.out" 2>&1
high_status=$?
same "rewrites the list on a healthy response" 0 "$high_status"
same "stores both the v4 and the v6 ranges" 24 "$(wc -l < "$target" | tr -d ' ')"
same "keeps the list readable for the unprivileged Caddy user" 644 "$(file_mode "$target")"

# ── deps.sh ───────────────────────────────────────────────────────────────────
echo "--- deps.sh"
pinned_version="$(sed -n 's/^ARG VAULTWARDEN_VERSION=//p' Dockerfile | head -n 1)"
GITHUB_OUTPUT="$work/deps-same" ./scripts/deps.sh compare \
    "VAULTWARDEN_VERSION=$pinned_version" >"$work/compare-same.out" 2>&1
same "reports no change for the value already pinned" "false" \
    "$(sed -n 's/^changed=//p' "$work/deps-same")"
GITHUB_OUTPUT="$work/deps-diff" ./scripts/deps.sh compare \
    "VAULTWARDEN_VERSION=0.0.0-selftest" >"$work/compare-diff.out" 2>&1
same "reports a change for a different value" "true" \
    "$(sed -n 's/^changed=//p' "$work/deps-diff")"
same "writes the changed flag exactly once" 1 \
    "$(grep -c '^changed=' "$work/deps-diff")"

echo
if [ "$failures" -eq 0 ]; then
    echo "helper self tests passed"
else
    printf '%s helper self test(s) failed\n' "$failures" >&2
    exit 1
fi
