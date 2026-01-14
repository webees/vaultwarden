# Base image: Vaultwarden Alpine
FROM vaultwarden/server:latest-alpine

# Args & Env
ARG TARGETARCH
ARG SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.37/supercronic-linux-${TARGETARCH}
ARG OVERMIND_URL=https://github.com/DarthSim/overmind/releases/download/v2.5.1/overmind-v2.5.1-linux-${TARGETARCH}.gz

ENV WORKDIR=/app \
    TZ="Asia/Shanghai" \
    OVERMIND_PROCFILE=/Procfile \
    OVERMIND_CAN_DIE=crontab \
    ROCKET_PORT=8080

WORKDIR $WORKDIR

# Copy configs
COPY config/crontab config/Procfile config/Caddyfile scripts/restic.sh /

# Install dependencies
RUN apk add --no-cache \
    curl ca-certificates openssl tzdata \
    caddy restic tmux sqlite msmtp mailx \
    iptables ip6tables iputils-ping \
    && rm -rf /var/cache/apk/* \
    # Download binaries
    && curl -fsSL "$SUPERCRONIC_URL" -o /usr/local/bin/supercronic \
    && curl -fsSL "$OVERMIND_URL" | gunzip -c - > /usr/local/bin/overmind \
    # Sendmail symlinks
    && ln -sf /usr/bin/msmtp /usr/bin/sendmail \
    && ln -sf /usr/bin/msmtp /usr/sbin/sendmail \
    # Permissions
    && chmod +x /usr/local/bin/supercronic /usr/local/bin/overmind /restic.sh

CMD ["overmind", "start"]