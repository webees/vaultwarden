# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Vaultwarden Deployment                                                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Pinned on purpose: a floating tag silently changes the runtime between builds.
ARG VAULTWARDEN_VERSION=1.37.4
FROM vaultwarden/server:${VAULTWARDEN_VERSION}-alpine

# ── Build Args ────────────────────────────────────────────────────────────────
ARG TARGETARCH
ARG SUPERCRONIC_VERSION=v0.2.37
ARG OVERMIND_VERSION=v2.5.1

# Artifact digests, so a replaced or truncated download fails the build.
# supercronic is hashed as downloaded; overmind is hashed after gunzip.
ARG SUPERCRONIC_SHA256_amd64=14a91b905dc68eaf533557734198b5d4a46898109c29193becddda40bf7b09d2
ARG SUPERCRONIC_SHA256_arm64=b8fe14272949722290a6e0d271ad6198fbaa62cedb9c8bc3608b42996af0915c
ARG OVERMIND_SHA256_amd64=73fdf28313821ac4f76a18da29fb907707edc4a6b90e11c6c71984a2bd98c8ad
ARG OVERMIND_SHA256_arm64=6fbb37a51366516b0fd9ee33ae452caf791809354746bd0ef2a95292d5f2965a

# ── Environment ───────────────────────────────────────────────────────────────
ENV WORKDIR=/app \
    TZ="Asia/Shanghai" \
    OVERMIND_PROCFILE=/Procfile \
    OVERMIND_CAN_DIE=caddy,crontab \
    OVERMIND_SHOW_TIMESTAMPS=0 \
    ROCKET_PORT=8080

WORKDIR $WORKDIR

# ── Config Files ──────────────────────────────────────────────────────────────
COPY config/crontab \
    config/Procfile \
    config/Caddyfile \
    scripts/restic.sh \
    /

# ── Dependencies ──────────────────────────────────────────────────────────────
RUN set -eu; \
    case "$TARGETARCH" in \
        amd64) SUPERCRONIC_SHA256="$SUPERCRONIC_SHA256_amd64"; OVERMIND_SHA256="$OVERMIND_SHA256_amd64" ;; \
        arm64) SUPERCRONIC_SHA256="$SUPERCRONIC_SHA256_arm64"; OVERMIND_SHA256="$OVERMIND_SHA256_arm64" ;; \
        *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    # bash is required by the shebang of scripts/restic.sh; tmux is used by overmind
    apk add --no-cache \
        bash \
        curl \
        ca-certificates \
        openssl \
        tzdata \
        caddy \
        restic \
        tmux \
        sqlite \
        msmtp \
        mailx; \
    curl -fsSL "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
        -o /usr/local/bin/supercronic; \
    echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c -; \
    curl -fsSL "https://github.com/DarthSim/overmind/releases/download/${OVERMIND_VERSION}/overmind-${OVERMIND_VERSION}-linux-${TARGETARCH}.gz" \
        | gunzip -c - > /usr/local/bin/overmind; \
    echo "${OVERMIND_SHA256}  /usr/local/bin/overmind" | sha256sum -c -; \
    chmod +x /usr/local/bin/supercronic /usr/local/bin/overmind /restic.sh; \
    # Symlink msmtp for mail commands
    ln -sf /usr/bin/msmtp /usr/bin/sendmail; \
    ln -sf /usr/bin/msmtp /usr/sbin/sendmail; \
    # Cleanup cache
    rm -rf /var/cache/apk/*

# ── Startup ───────────────────────────────────────────────────────────────────
ENTRYPOINT []
CMD ["overmind", "start"]
