#!/bin/bash
set -euo pipefail

if [ "$(id -u)" = "0" ]; then
    echo "services.sh must run as the unprivileged service user" >&2
    exit 2
fi

# Keep the three long-running services in one static table. Caddy and the
# scheduler restart after a crash; Vaultwarden exiting stops the container so
# Fly's restart policy owns the recovery. `setsid` gives each child its own
# process group, so a signal reaches helpers as well as the direct command.
delay="${SUPERVISE_RESTART_DELAY:-5}"
supervisors=()

case "$delay" in
    ''|*[!0-9.]*|.*|*.|*.*.*)
        echo "SUPERVISE_RESTART_DELAY must be a positive number, got '${delay}'" >&2
        exit 2
        ;;
esac
case "$delay" in
    *[1-9]*) ;;
    *)
        echo "SUPERVISE_RESTART_DELAY must be a positive number, got '${delay}'" >&2
        exit 2
        ;;
esac

supervise() {
    local name="$1" restart="$2" child status
    shift 2
    child=""
    trap 'if [ -n "$child" ]; then
        kill -TERM -"$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || :
    fi
    exit 0' INT TERM

    while :; do
        setsid "$@" &
        child=$!
        if wait "$child"; then
            status=0
        else
            status=$?
        fi
        child=""
        if [ "$restart" != "true" ]; then
            return "$status"
        fi
        echo "[${name}] exited with status ${status}, restarting in ${delay}s" >&2
        sleep "$delay" &
        child=$!
        if wait "$child"; then
            status=0
        else
            status=$?
        fi
        child=""
        if [ "$status" -ne 0 ]; then
            return "$status"
        fi
    done
}

stop_services() {
    local pid
    trap - INT TERM
    for pid in "${supervisors[@]}"; do
        kill -TERM "$pid" 2>/dev/null || :
    done
    for pid in "${supervisors[@]}"; do
        wait "$pid" 2>/dev/null || :
    done
}

supervise vaultwarden false /vaultwarden &
supervisors+=("$!")
supervise caddy true caddy run --config /Caddyfile &
supervisors+=("$!")
supervise crontab true supercronic /crontab &
supervisors+=("$!")

trap 'stop_services; exit 0' INT TERM
if wait -n "${supervisors[@]}"; then
    status=0
else
    status=$?
fi
stop_services
exit "$status"
