#!/bin/bash
# Refresh config/cloudflare_ips.caddy from Cloudflare's published origin ranges.
# The Caddyfile trusts CF-Connecting-IP only when Fly-Client-IP falls inside one
# of these ranges, so a stale file silently degrades client IP accuracy.
# Run from the repository root; CI runs it before every image build.
set -euo pipefail

# Resolve the target from the script location so it works from any directory.
cd "$(dirname "$0")/.."

readonly TARGET="config/cloudflare_ips.caddy"
readonly V4_URL="https://www.cloudflare.com/ips-v4"
readonly V6_URL="https://www.cloudflare.com/ips-v6"
# A truncated response must never overwrite the checked-in list.
readonly MIN_RANGES=20
readonly HTTP_TIMEOUT="${CF_HTTP_TIMEOUT:-30}"

# Bounded fetch: a stalled request must not hold a CI job open for its full
# six-hour limit.
fetch() { curl -fsSL --max-time "$HTTP_TIMEOUT" --retry 2 --retry-delay 2 "$@"; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

{
    fetch "$V4_URL"
    printf '\n'
    fetch "$V6_URL"
    printf '\n'
} | awk 'NF {print "client_ip "$0}' > "$tmp"

count="$(awk 'END {print NR}' "$tmp")"
if [ "$count" -lt "$MIN_RANGES" ]; then
    echo "Cloudflare returned ${count} ranges (minimum ${MIN_RANGES}); keeping ${TARGET}" >&2
    exit 1
fi

# A response long enough to pass the count check can still be garbage: Cloudflare
# answers an outage with an HTML error page, and `client_ip <html>` is not a
# range. Writing it left a file that looked refreshed while `caddy validate`
# rejected it and the image build broke, so every line has to be an address.
invalid="$(awk '
    function ok(s,   addr, bits, n, parts, i) {
        bits = ""
        if (index(s, "/")) {
            addr = substr(s, 1, index(s, "/") - 1)
            bits = substr(s, index(s, "/") + 1)
            if (bits !~ /^[0-9]+$/) return 0
        } else {
            addr = s
        }
        if (addr ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
            n = split(addr, parts, ".")
            for (i = 1; i <= n; i++) if (parts[i] + 0 > 255) return 0
            return (bits == "" || bits + 0 <= 32)
        }
        if (addr ~ /^[0-9A-Fa-f]+:[0-9A-Fa-f:]*$/ && addr ~ /:/) {
            return (bits == "" || bits + 0 <= 128)
        }
        return 0
    }
    NF != 2 || $1 != "client_ip" || !ok($2) { bad++ }
    END { print bad + 0 }
' "$tmp")"
if [ "$invalid" -gt 0 ]; then
    echo "Cloudflare returned ${invalid} line(s) that are not address ranges; keeping ${TARGET}" >&2
    exit 1
fi

mv "$tmp" "$TARGET"
# mktemp creates the file 0600; Caddy runs as the unprivileged `vaultwarden`
# user and reads this file from the image, so it has to stay world readable.
chmod 0644 "$TARGET"
echo "Refreshed ${TARGET} with ${count} Cloudflare ranges"
