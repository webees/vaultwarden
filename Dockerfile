# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Vaultwarden Deployment                                                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
FROM vaultwarden/server:latest-alpine

# ── Build Args ────────────────────────────────────────────────────────────────
ARG TARGETARCH
ARG SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.37/supercronic-linux-${TARGETARCH}
ARG OVERMIND_URL=https://github.com/DarthSim/overmind/releases/download/v2.5.1/overmind-v2.5.1-linux-${TARGETARCH}.gz

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
RUN apk add --no-cache \
    curl \
    ca-certificates \
    openssl \
    tzdata \
    openntpd \
    caddy \
    restic \
    tmux \
    sqlite \
    msmtp \
    mailx \
    iptables \
    ip6tables \
    iputils-ping \
    # Download binary tools
    && curl -fsSL "$SUPERCRONIC_URL" -o /usr/local/bin/supercronic \
    && curl -fsSL "$OVERMIND_URL" | gunzip -c - > /usr/local/bin/overmind \
    && chmod +x /usr/local/bin/supercronic /usr/local/bin/overmind /restic.sh \
    # Symlink msmtp for mail commands
    && ln -sf /usr/bin/msmtp /usr/bin/sendmail \
    && ln -sf /usr/bin/msmtp /usr/sbin/sendmail \
    # Cleanup cache
    && rm -rf /var/cache/apk/*

# ── Startup ───────────────────────────────────────────────────────────────────
ENTRYPOINT []
CMD ["overmind", "start"]
