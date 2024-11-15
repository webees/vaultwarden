FROM vaultwarden/server:latest-alpine

WORKDIR /

ARG SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.29/supercronic-linux-amd64 \
    OVERMIND_URL=https://github.com/DarthSim/overmind/releases/download/v2.4.0/overmind-v2.4.0-linux-amd64.gz

ENV TZ="Asia/Shanghai" \

    OVERMIND_CAN_DIE=crontab \
    OVERMIND_PROCFILE=/Procfile \

    ROCKET_PORT=8080 \

    SMTP_HOST=smtp.gmail.com \
    SMTP_PORT=587 \
    SMTP_USERNAME=88888888@gmail.com \
    SMTP_PASSWORD=88888888 \
    SMTP_FROM=88888888@gmail.com \
    SMTP_TO= \

    RESTIC_REPOSITORY=s3://88888888.r2.cloudflarestorage.com/vaultwarden \
    RESTIC_PASSWORD= \
    AWS_ACCESS_KEY_ID= \
    AWS_SECRET_ACCESS_KEY=

COPY config/crontab \
     config/Procfile \
     config/Caddyfile \
     scripts/restic.sh \
     /

RUN apk add --no-cache \
        curl \
        caddy \
        restic \
        ca-certificates \
        openssl \
        tzdata \
        iptables \
        ip6tables \
        iputils-ping \
        tmux \
        sqlite \
        msmtp \
        mailx \

        && rm -rf /var/cache/apk/* \
        && curl -fsSL "$SUPERCRONIC_URL" -o /usr/local/bin/supercronic \
        && curl -fsSL "$OVERMIND_URL" | gunzip -c - > /usr/local/bin/overmind \

        && ln -sf /usr/bin/msmtp /usr/bin/sendmail \
        && ln -sf /usr/bin/msmtp /usr/sbin/sendmail \

        && chmod +x /usr/local/bin/supercronic \
        && chmod +x /usr/local/bin/overmind \
        && chmod +x /restic.sh

CMD ["overmind", "start"]
