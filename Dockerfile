# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Vaultwarden Deployment                                                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Pinned on purpose: a floating tag silently changes the runtime between builds.
ARG VAULTWARDEN_VERSION=1.37.4
ARG VAULTWARDEN_DIGEST=sha256:19ea2b669945d842dadc3d500f2d6a795866a003330f59a47b9634658bae98bb
FROM vaultwarden/server:${VAULTWARDEN_VERSION}-alpine@${VAULTWARDEN_DIGEST}

# ── Build Args ────────────────────────────────────────────────────────────────
ARG TARGETARCH
ARG SUPERCRONIC_VERSION=v0.2.49
ARG OVERMIND_VERSION=v2.5.1

# Artifact digests, so a replaced or truncated download fails the build.
# supercronic is hashed as downloaded; overmind is hashed after gunzip.
ARG SUPERCRONIC_SHA256_amd64=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1
ARG SUPERCRONIC_SHA256_arm64=02aa0cb229ba09050cba6638059dadb9eedc2276632ea43d6a57a2f8c1629dd5
ARG OVERMIND_SHA256_amd64=73fdf28313821ac4f76a18da29fb907707edc4a6b90e11c6c71984a2bd98c8ad
ARG OVERMIND_SHA256_arm64=6fbb37a51366516b0fd9ee33ae452caf791809354746bd0ef2a95292d5f2965a

# ── Environment ───────────────────────────────────────────────────────────────
ENV WORKDIR=/app \
    HOME=/app \
    XDG_DATA_HOME=/data \
    TZ="Asia/Shanghai" \
    OVERMIND_PROCFILE=/Procfile \
    OVERMIND_SHOW_TIMESTAMPS=0 \
    ROCKET_PORT=8081

WORKDIR $WORKDIR

# ── Config Files ──────────────────────────────────────────────────────────────
COPY config/crontab \
    config/Procfile \
    config/Caddyfile \
    config/cloudflare-ips.caddy \
    scripts/caddy-loop.sh \
    scripts/entrypoint.sh \
    scripts/cronloop.sh \
    scripts/restic.sh \
    /

# ── Dependencies ──────────────────────────────────────────────────────────────
ARG CACHE_BUST=local
RUN set -eu; \
    date -u +%Y-%m-%dT%H:%M:%SZ; \
    case "$TARGETARCH" in \
        amd64) SUPERCRONIC_SHA256="$SUPERCRONIC_SHA256_amd64"; OVERMIND_SHA256="$OVERMIND_SHA256_amd64" ;; \
        arm64) SUPERCRONIC_SHA256="$SUPERCRONIC_SHA256_arm64"; OVERMIND_SHA256="$OVERMIND_SHA256_arm64" ;; \
        *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    # bash is required by the shebangs of scripts/*.sh; tmux is used by overmind
    apk add --no-cache \
        bash \
        curl \
        su-exec \
        ca-certificates \
        openssl \
        tzdata \
        caddy \
        restic \
        tmux \
        sqlite \
        msmtp \
        mailx; \
    addgroup -S vaultwarden; \
    adduser -S -G vaultwarden -h /app -s /bin/sh vaultwarden; \
    touch /etc/msmtprc; \
    chown vaultwarden:vaultwarden /etc/msmtprc; \
    chmod 600 /etc/msmtprc; \
    curl -fsSL "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
        -o /usr/local/bin/supercronic; \
    echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c -; \
    curl -fsSL "https://github.com/DarthSim/overmind/releases/download/${OVERMIND_VERSION}/overmind-${OVERMIND_VERSION}-linux-${TARGETARCH}.gz" \
        | gunzip -c - > /usr/local/bin/overmind; \
    echo "${OVERMIND_SHA256}  /usr/local/bin/overmind" | sha256sum -c -; \
    chmod +x /usr/local/bin/supercronic /usr/local/bin/overmind /caddy-loop.sh /entrypoint.sh /cronloop.sh /restic.sh; \
    # Symlink msmtp for mail commands
    ln -sf /usr/bin/msmtp /usr/bin/sendmail; \
    ln -sf /usr/bin/msmtp /usr/sbin/sendmail; \
    # Cleanup cache
    rm -rf /var/cache/apk/*

# ── Startup ───────────────────────────────────────────────────────────────────
ENTRYPOINT []
CMD ["/entrypoint.sh", "overmind", "start"]
