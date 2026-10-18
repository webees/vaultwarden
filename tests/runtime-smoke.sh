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
apk_stub_image=""
apk_stub_container=""
apk_stub_file=""

cleanup() {
    docker rm --force "$container" >/dev/null 2>&1 || true
    if [ -n "$apk_stub_container" ]; then
        docker rm --force "$apk_stub_container" >/dev/null 2>&1 || true
    fi
    if [ -n "$apk_stub_image" ]; then
        docker rmi --force "$apk_stub_image" >/dev/null 2>&1 || true
    fi
    if [ -n "$apk_stub_file" ]; then
        rm -f "$apk_stub_file"
    fi
}
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

# The daily dependency check must not read a failed apk index refresh as
# "nothing to upgrade": that silently hides security updates. Build a throwaway
# image whose `apk update` fails while `apk version` still succeeds empty.
apk_stub_image="deps-apk-stub-$$"
apk_stub_container="deps-apk-stub-$$"
apk_stub_file="$(mktemp)"
# shellcheck disable=SC2016  # $1/$@ are literals for the generated stub
printf '#!/bin/sh\ncase "$1" in\n  update) exit 1 ;;\n  version) exit 0 ;;\n  *) exec /sbin/apk.real "$@" ;;\nesac\n' \
    > "$apk_stub_file"
docker run --detach --name "$apk_stub_container" "$image" sleep 60 >/dev/null
docker exec "$apk_stub_container" mv /sbin/apk /sbin/apk.real
docker cp "$apk_stub_file" "$apk_stub_container:/sbin/apk"
docker exec "$apk_stub_container" chmod +x /sbin/apk
rm -f "$apk_stub_file"
apk_stub_file=""
docker commit --change 'ENTRYPOINT []' "$apk_stub_container" "$apk_stub_image" >/dev/null
docker rm --force "$apk_stub_container" >/dev/null
apk_stub_container=""
if "$tests_dir/../scripts/deps.sh" apk "$apk_stub_image" >/tmp/deps-apk-stub.log 2>&1; then
    echo "FAIL deps.sh apk reported success although apk update failed" >&2
    cat /tmp/deps-apk-stub.log >&2
    exit 1
fi
echo "deps.sh apk fails loudly when the index refresh fails"
