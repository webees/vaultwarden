#!/bin/bash
# Keep a child process alive. Overmind does not restart processes that exit, so
# the proxy and the scheduler would otherwise stay down after a single crash.
set -u

name="${1:?usage: supervise.sh <name> <command> [args...]}"
shift
delay="${SUPERVISE_RESTART_DELAY:-5}"

trap 'echo "[${name}] signal received, shutting down" >&2; exit 0' INT TERM

while :; do
    "$@"
    status=$?
    echo "[${name}] exited with status ${status}, restarting in ${delay}s" >&2
    sleep "$delay"
done
