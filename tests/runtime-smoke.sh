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
smtp_container=""
smtp_pid=""
smtp_dir=""

cleanup() {
    docker rm --force "$container" >/dev/null 2>&1 || true
    if [ -n "$apk_stub_container" ]; then
        docker rm --force "$apk_stub_container" >/dev/null 2>&1 || true
    fi
    if [ -n "$smtp_container" ]; then
        docker rm --force "$smtp_container" >/dev/null 2>&1 || true
    fi
    if [ -n "$smtp_pid" ]; then
        kill "$smtp_pid" >/dev/null 2>&1 || true
    fi
    if [ -n "$apk_stub_image" ]; then
        docker rmi --force "$apk_stub_image" >/dev/null 2>&1 || true
    fi
    if [ -n "$apk_stub_file" ]; then
        rm -f "$apk_stub_file"
    fi
    if [ -n "$smtp_dir" ]; then
        rm -rf "$smtp_dir"
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

# Caddy decides who may reach the app and who the client is; both are security
# controls, and neither was asserted anywhere. Read them where they are
# observable: the status code and the access log Caddy writes to stdout.
probe_code() { docker exec "$container" curl -s -o /dev/null -w '%{http_code}' "$@"; }

code_allowed="$(probe_code -H 'Host: example.com' http://127.0.0.1:8080/api/config)"
code_denied="$(probe_code -H 'Host: evil.example' http://127.0.0.1:8080/api/config)"
# /alive is deliberately matched before the whitelist, or Fly would pull a
# machine whose proxy is fine but whose domain secret is wrong.
code_alive="$(probe_code -H 'Host: evil.example' http://127.0.0.1:8080/alive)"
if [ "$code_allowed" = "200" ] && [ "$code_denied" = "403" ] && [ "$code_alive" = "200" ]; then
    echo "the host whitelist serves the configured domain, refuses others and keeps /alive reachable"
else
    echo "FAIL host whitelist: allowed=${code_allowed} denied=${code_denied} alive=${code_alive}" >&2
    exit 1
fi

# Fly overwrites Fly-Client-IP at the edge, so it may be trusted. CF-Connecting-IP
# may not: a direct client could otherwise pick the address that lands in the log.
probe_code -H 'Host: example.com' -H 'Fly-Client-IP: 203.0.113.9' \
    http://127.0.0.1:8080/api/config >/dev/null
probe_code -H 'Host: example.com' -H 'CF-Connecting-IP: 203.0.113.99' \
    http://127.0.0.1:8080/api/config >/dev/null

probe_secret="smoke-cred-$$"
probe_code -H 'Host: example.com' -H "Authorization: Bearer ${probe_secret}" \
    -H "Cookie: session=${probe_secret}" -H "X-Api-Key: ${probe_secret}" \
    http://127.0.0.1:8080/api/config >/dev/null
sleep 3

# Captured once, and proven non-empty first: an empty string would make both
# assertions below pass without a single access log line behind them.
access_log="$(docker logs "$container" 2>&1)"
if printf '%s\n' "$access_log" | grep -q '"uri": "/api/config"'; then
    echo "the smoke probes reached the access log"
else
    echo "FAIL no access log lines for the smoke probes" >&2
    printf '%s\n' "$access_log" | tail -20 >&2
    exit 1
fi

if printf '%s\n' "$access_log" | grep -q '"client_ip": "203.0.113.9"'; then
    echo "Fly-Client-IP is trusted as the client address"
else
    echo "FAIL Fly-Client-IP did not reach the access log" >&2
    printf '%s\n' "$access_log" | grep -o '"client_ip": "[^"]*"' | sort | uniq -c >&2
    exit 1
fi

if printf '%s\n' "$access_log" | grep -q '"client_ip": "203.0.113.99"'; then
    echo "FAIL a spoofed CF-Connecting-IP was trusted as the client address" >&2
    exit 1
fi
echo "a spoofed CF-Connecting-IP is not trusted as the client address"

if printf '%s\n' "$access_log" | grep -q "$probe_secret"; then
    echo "FAIL credentials reached the access log" >&2
    exit 1
fi
echo "credentials sent to the proxy never reach the access log"

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
rm -f /tmp/deps-apk-stub.log

# Email is the only channel that reports a broken backup, and every other check
# stubs `mail` out. Nothing proved that mailx, the sendmail symlink, msmtp and
# the trust store actually deliver a message, so send one to a local STARTTLS
# sink and assert on what reached the wire.
smtp_dir="$(mktemp -d)"
smtp_ready="$smtp_dir/port"
smtp_message="$smtp_dir/message.txt"
smtp_run="$smtp_dir/run.log"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$smtp_dir/key.pem" -out "$smtp_dir/cert.pem" \
    -subj "/CN=host.docker.internal" \
    -addext "subjectAltName=DNS:host.docker.internal,DNS:localhost,IP:127.0.0.1" \
    >/dev/null 2>&1
python3 "$tests_dir/smtp-sink.py" \
    --cert "$smtp_dir/cert.pem" --key "$smtp_dir/key.pem" \
    --out "$smtp_message" --ready "$smtp_ready" --timeout 120 &
smtp_pid=$!
for _ in $(seq 1 100); do
    [ -s "$smtp_ready" ] && break
    sleep 0.1
done
smtp_port="$(cat "$smtp_ready" 2>/dev/null || true)"
if [ -z "$smtp_port" ]; then
    echo "the SMTP sink never reported its port" >&2
    exit 1
fi

smtp_container="smtp-$$"
docker run --detach --name "$smtp_container" \
    --add-host=host.docker.internal:host-gateway \
    --env CADDY_DOMAINS=example.com \
    --env DOMAIN=https://example.com \
    --env I_REALLY_WANT_VOLATILE_STORAGE=true \
    --env SMTP_HOST=host.docker.internal \
    --env SMTP_PORT="$smtp_port" \
    --env SMTP_TO=ops@example.com \
    --env SMTP_USERNAME=user \
    --env SMTP_PASSWORD=secret \
    "$image" >/dev/null

smtp_up=1
for _ in $(seq 1 30); do
    if docker exec "$smtp_container" sh -c \
        'test -s /etc/msmtprc && wget -qO- http://127.0.0.1:8080/alive >/dev/null 2>&1'; then
        smtp_up=0
        break
    fi
    sleep 2
done
if [ "$smtp_up" -ne 0 ]; then
    echo "the alert test container never came up" >&2
    docker logs "$smtp_container" >&2
    exit 1
fi

# The sink is self-signed, so the container has to trust it: msmtp reads the
# system bundle that the image already points tls_trust_file at.
docker cp "$smtp_dir/cert.pem" "$smtp_container:/tmp/sink-ca.pem"
docker exec "$smtp_container" sh -c \
    'cat /tmp/sink-ca.pem >> /etc/ssl/certs/ca-certificates.crt'

# A stale freshness check is the cheapest real failure path that sends mail.
smtp_rc=0
docker exec "$smtp_container" sh -c \
    'RESTIC_PASSWORD=selftest BACKUP_MAX_AGE=1 /restic.sh check-freshness' \
    >"$smtp_run" 2>&1 || smtp_rc=$?

delivered=1
for _ in $(seq 1 60); do
    if [ -s "$smtp_message" ]; then
        delivered=0
        break
    fi
    sleep 1
done
if [ "$delivered" -ne 0 ]; then
    echo "FAIL no message reached the SMTP sink" >&2
    sed -n '1,20p' "$smtp_run" >&2
    exit 1
fi
echo "a real alert reached the SMTP sink over STARTTLS"

if grep -q '^Subject: \[Vaultwarden\] Backup stale' "$smtp_message"; then
    echo "the delivered message carries the alert subject"
else
    echo "FAIL the delivered message has an unexpected subject" >&2
    sed -n '1,15p' "$smtp_message" >&2
    exit 1
fi
if grep -q 'ops@example.com' "$smtp_message"; then
    echo "the delivered message is addressed to the configured recipient"
else
    echo "FAIL the delivered message lost its recipient" >&2
    sed -n '1,15p' "$smtp_message" >&2
    exit 1
fi
if grep -q 'Alert email sent' "$smtp_run"; then
    echo "the run recorded the delivery"
else
    echo "FAIL the run did not record the delivery" >&2
    sed -n '1,20p' "$smtp_run" >&2
    exit 1
fi
if [ "$smtp_rc" -eq 2 ]; then
    echo "the alert path keeps the failing run's exit status"
else
    echo "FAIL the freshness check exited ${smtp_rc} instead of 2" >&2
    exit 1
fi
