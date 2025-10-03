# 🚀 Base image: Vaultwarden with Alpine
FROM vaultwarden/server:latest-alpine

# 🧱 Define target architecture (e.g., amd64, arm64)
ARG TARGETARCH
# 📁 Set working directory path
ENV WORKDIR /app
# 📂 Switch to working directory
WORKDIR $WORKDIR

# 🌍 Download URLs for tools
ARG SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.37/supercronic-linux-${TARGETARCH}
ARG OVERMIND_URL=https://github.com/DarthSim/overmind/releases/download/v2.5.1/overmind-v2.5.1-linux-${TARGETARCH}.gz

# 🕒 Environment variables
ENV TZ="Asia/Shanghai" \
    OVERMIND_PROCFILE=/Procfile \
    OVERMIND_CAN_DIE=crontab \
    ROCKET_PORT=8080

# 📦 Copy configs and scripts
COPY config/crontab \
     config/Procfile \
     config/Caddyfile \
     scripts/restic.sh \
     /

# ⚙️ Install dependencies and setup tools
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
    # ⬇️ Download binaries
    && curl -fsSL "$SUPERCRONIC_URL" -o /usr/local/bin/supercronic \
    && curl -fsSL "$OVERMIND_URL" | gunzip -c - > /usr/local/bin/overmind \
    # 🔗 Setup sendmail symlinks
    && ln -sf /usr/bin/msmtp /usr/bin/sendmail \
    && ln -sf /usr/bin/msmtp /usr/sbin/sendmail \
    # 🔑 Make binaries executable
    && chmod +x /usr/local/bin/supercronic \
    && chmod +x /usr/local/bin/overmind \
    && chmod +x /restic.sh

# ▶️ Start processes via Overmind
CMD ["overmind", "start"]