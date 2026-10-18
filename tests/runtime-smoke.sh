#!/bin/bash
# Boot an image and run the checks that only exist at container runtime: the
# Caddyfile must validate, the Overmind stack must come up unprivileged, and the
# backup paths must work inside the image. Shared by the validate and build
# workflows so the merge path tests the exact digest it publishes.
# Usage: tests/runtime-smoke.sh <image>
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: tests/runtime-smoke.sh <image>" >&2
    exit 2
fi

image="$1"
tests_dir="$(cd "$(dirname "$0")" && pwd)"
container="smoke-$$"

cleanup() { docker rm --force "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run --rm --entrypoint caddy "$image" validate --config /Caddyfile --adapter caddyfile

# No command override: the image's own CMD is what production runs, so the smoke
# test has to exercise that path (tini as PID 1) rather than a copy of it.
docker run --detach --name "$container" \
    --env CADDY_DOMAINS=example.com \
    --env DOMAIN=https://example.com \
    --env I_REALLY_WANT_VOLATILE_STORAGE=true \
    "$image" >/dev/null

alive=1
for _ in $(seq 1 30); do
    if docker exec "$container" wget -qO- http://127.0.0.1:8080/alive >/dev/null 2>&1; then
        alive=0
        break
    fi
    sleep 2
done
if [ "$alive" -ne 0 ]; then
    echo "/alive never came up" >&2
    docker logs "$container" >&2
    exit 1
fi
echo "/alive responded through Caddy"

docker cp "$tests_dir/lib.sh" "$container:/tmp/lib.sh"
docker cp "$tests_dir/image-selftest.sh" "$container:/tmp/image-selftest.sh"
docker exec "$container" sh /tmp/image-selftest.sh
