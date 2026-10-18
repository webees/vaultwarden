#!/bin/bash
# Keep a child process alive. Overmind does not restart processes that exit, so
# the proxy and the scheduler would otherwise stay down after a single crash.
set -u

name="${1:?usage: supervise.sh <name> <command> [args...]}"
shift
delay="${SUPERVISE_RESTART_DELAY:-5}"

# `sleep` treats a non-numeric delay as an error, which turns the restart loop
# into a CPU spin. Reject zero too: it would restart a crashing child forever
# with no backoff. Fractional values remain valid for tests and fast probes.
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
[ "$#" -gt 0 ] || {
    echo "usage: supervise.sh <name> <command> [args...]" >&2
    exit 2
}

trap 'echo "[${name}] signal received, shutting down" >&2; exit 0' INT TERM

while :; do
    "$@"
    status=$?
    echo "[${name}] exited with status ${status}, restarting in ${delay}s" >&2
    sleep "$delay"
done
