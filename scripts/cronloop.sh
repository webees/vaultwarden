#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Supercronic Supervisor                                                     ║
# ║ Overmind does not restart processes that exit, so a dead scheduler would   ║
# ║ silently stop every backup. Keep supercronic alive from here instead.      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -u

CRONTAB_FILE="${CRONTAB_FILE:-/crontab}"
RESTART_DELAY="${CRON_RESTART_DELAY:-5}"

# Forward shutdown signals to supercronic and stop respawning during deploys
trap 'echo "[cronloop] signal received, shutting down" >&2; exit 0' INT TERM

while true; do
    supercronic "$CRONTAB_FILE"
    status=$?
    echo "[cronloop] supercronic exited with status ${status}, restarting in ${RESTART_DELAY}s" >&2
    sleep "$RESTART_DELAY"
done
