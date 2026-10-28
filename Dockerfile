# Pinned so an upstream tag change cannot alter an existing build.
ARG VAULTWARDEN_VERSION=1.37.4
ARG VAULTWARDEN_DIGEST=sha256:19ea2b669945d842dadc3d500f2d6a795866a003330f59a47b9634658bae98bb
FROM vaultwarden/server:${VAULTWARDEN_VERSION}-alpine@${VAULTWARDEN_DIGEST}

ARG TARGETARCH
ARG SUPERCRONIC_VERSION=v0.2.51

ARG SUPERCRONIC_SHA256_amd64=cc232108374e8e2b537045f2d5eaa1229f619db314c3ba6a14d38b35dc0aa123
ARG SUPERCRONIC_SHA256_arm64=4ae22576a78223d8ccdf5f3b3660a5cbb5288416bf0ca96afc4a36d195932b94

ENV HOME=/app \
    XDG_DATA_HOME=/data \
    TZ="Asia/Shanghai" \
    ROCKET_PORT=8081

# Vaultwarden resolves its bundled web-vault relative to this directory.
WORKDIR /

ARG CACHE_BUST=local
RUN set -eu; \
    echo "cache-bust=${CACHE_BUST}"; \
    date -u +%Y-%m-%dT%H:%M:%SZ; \
    case "$TARGETARCH" in \
        amd64) SUPERCRONIC_SHA256="$SUPERCRONIC_SHA256_amd64" ;; \
        arm64) SUPERCRONIC_SHA256="$SUPERCRONIC_SHA256_arm64" ;; \
        *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    # The base is pinned, so installed packages need an explicit upgrade.
    apk --no-cache upgrade; \
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
    install -o vaultwarden -g vaultwarden -m 600 /dev/null /etc/msmtprc; \
    curl -fsSL "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
        -o /usr/local/bin/supercronic; \
    echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c -; \
    chmod +x /usr/local/bin/supercronic; \
    ln -sf /usr/bin/msmtp /usr/bin/sendmail; \
    ln -sf /usr/bin/msmtp /usr/sbin/sendmail

COPY config/crontab \
    config/Caddyfile \
    config/cloudflare_ips.caddy \
    scripts/entrypoint.sh \
    scripts/services.sh \
    scripts/restic.sh \
    /
COPY scripts/entrypoint/ /entrypoint/
RUN chmod +x /entrypoint.sh /services.sh /restic.sh

ENTRYPOINT []
CMD ["/entrypoint.sh"]
