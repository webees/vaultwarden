#!/bin/bash
# Keep Caddy alive if it crashes. Overmind does not restart exited processes,
# so without this a bad config or transient failure would take the proxy down.
set -u

CADDY_CONFIG="${CADDY_CONFIG:-/Caddyfile}"
RESTART_DELAY="${CADDY_RESTART_DELAY:-5}"

trap 'echo "[caddy-loop] signal received, shutting down" >&2; exit 0' INT TERM

while true; do
    caddy run --config "$CADDY_CONFIG"
    status=$?
    echo "[caddy-loop] caddy exited with status ${status}, restarting in ${RESTART_DELAY}s" >&2
    sleep "$RESTART_DELAY"
done
