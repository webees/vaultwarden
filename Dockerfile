# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Vaultwarden Deployment                                                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Pinned on purpose: a floating tag silently changes the runtime between builds.
ARG VAULTWARDEN_VERSION=1.37.4
ARG VAULTWARDEN_DIGEST=sha256:19ea2b669945d842dadc3d500f2d6a795866a003330f59a47b9634658bae98bb
FROM vaultwarden/server:${VAULTWARDEN_VERSION}-alpine@${VAULTWARDEN_DIGEST}

# ── Build Args ────────────────────────────────────────────────────────────────
ARG TARGETARCH
# Upstream pins live here on purpose: .github/workflows/dependency_updates.yml
# checks them every two hours, opens a PR with the newest release, and merges it once
# validate passes, which rebuilds the image and rolls it out to Fly.
ARG SUPERCRONIC_VERSION=v0.2.51

# Artifact digests, so a replaced or truncated download fails the build.
ARG SUPERCRONIC_SHA256_amd64=cc232108374e8e2b537045f2d5eaa1229f619db314c3ba6a14d38b35dc0aa123
ARG SUPERCRONIC_SHA256_arm64=4ae22576a78223d8ccdf5f3b3660a5cbb5288416bf0ca96afc4a36d195932b94

# ── Environment ───────────────────────────────────────────────────────────────
ENV HOME=/app \
    XDG_DATA_HOME=/data \
    TZ="Asia/Shanghai" \
    ROCKET_PORT=8081

# Vaultwarden resolves its bundled `web-vault/` relative to the working
# directory. Keep the base image's `/`, not the application's `/app` home.
WORKDIR /

# ── Config Files ──────────────────────────────────────────────────────────────
COPY config/crontab \
    config/Caddyfile \
    config/cloudflare_ips.caddy \
    scripts/entrypoint.sh \
    scripts/services.sh \
    scripts/restic.sh \
    /
COPY scripts/entrypoint/ /entrypoint/

# ── Dependencies ──────────────────────────────────────────────────────────────
ARG CACHE_BUST=local
RUN set -eu; \
    date -u +%Y-%m-%dT%H:%M:%SZ; \
    case "$TARGETARCH" in \
        amd64) SUPERCRONIC_SHA256="$SUPERCRONIC_SHA256_amd64" ;; \
        arm64) SUPERCRONIC_SHA256="$SUPERCRONIC_SHA256_arm64" ;; \
        *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    # The base image is pinned, and `apk add` never touches packages that are
    # already installed, so the patched zlib/tzdata builds would otherwise never
    # reach the image. Upgrade first, then add what this image needs.
    apk --no-cache upgrade; \
    # bash is required by the shebangs of scripts/*.sh.
    apk add --no-cache \
        bash \
        curl \
        su-exec \
        ca-certificates \
        tzdata \
        caddy \
        restic \
        tini \
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
    chmod +x /usr/local/bin/supercronic /entrypoint.sh /services.sh /restic.sh; \
    # Symlink msmtp for mail commands
    ln -sf /usr/bin/msmtp /usr/bin/sendmail; \
    ln -sf /usr/bin/msmtp /usr/sbin/sendmail; \
    # Cleanup cache
    rm -rf /var/cache/apk/*

# ── Startup ───────────────────────────────────────────────────────────────────
# The root entrypoint finishes volume and secret-file setup, then replaces
# itself with an unprivileged tini. Tini stays PID 1, /services.sh owns the
# process table, and tini reaps helper processes.
ENTRYPOINT []
CMD ["/entrypoint.sh"]
