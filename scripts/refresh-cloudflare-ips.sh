#!/bin/bash
# Refresh config/cloudflare-ips.caddy from Cloudflare's published origin ranges.
# The Caddyfile trusts CF-Connecting-IP only when Fly-Client-IP falls inside one
# of these ranges, so a stale file silently degrades client IP accuracy.
# Run from the repository root; CI runs it before every image build.
set -euo pipefail

readonly TARGET="config/cloudflare-ips.caddy"
readonly V4_URL="https://www.cloudflare.com/ips-v4"
readonly V6_URL="https://www.cloudflare.com/ips-v6"
# A truncated response must never overwrite the checked-in list.
readonly MIN_RANGES=20

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

{
    curl -fsSL "$V4_URL"
    printf '\n'
    curl -fsSL "$V6_URL"
    printf '\n'
} | awk 'NF {print "client_ip "$0}' > "$tmp"

count="$(awk 'END {print NR}' "$tmp")"
if [ "$count" -lt "$MIN_RANGES" ]; then
    echo "Cloudflare returned ${count} ranges (minimum ${MIN_RANGES}); keeping ${TARGET}" >&2
    exit 1
fi

mv "$tmp" "$TARGET"
# mktemp creates the file 0600; Caddy runs as the unprivileged `vaultwarden`
# user and reads this file from the image, so it has to stay world readable.
chmod 0644 "$TARGET"
echo "Refreshed ${TARGET} with ${count} Cloudflare ranges"
