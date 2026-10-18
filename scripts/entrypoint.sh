#!/bin/bash
set -euo pipefail

mkdir -p /data/restic-logs /app
chown -R vaultwarden:vaultwarden /data /app

if [ ! -f /data/backup-status.txt ]; then
    printf 'state=unknown\nupdated_at=0\nlast_success=0\nmessage=No backup run recorded\n' \
        > /data/backup-status.txt
fi
chown vaultwarden:vaultwarden /data/backup-status.txt /data/restic-logs

# Write the SMTP config as root, then hand it to the unprivileged user.
umask 077
if [ -n "${SMTP_HOST:-}" ] && [ -n "${SMTP_TO:-}" ]; then
    # Vaultwarden refuses to start when SMTP_HOST is set without SMTP_FROM,
    # while the backup script's msmtp config already defaults the sender to
    # SMTP_TO. Give the app the same default so enabling alerts (which only
    # needs HOST and TO here) cannot take the service down.
    export SMTP_FROM="${SMTP_FROM:-$SMTP_TO}"
    cat > /etc/msmtprc <<EOF
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /dev/stderr
timeout ${SMTP_TIMEOUT:-15}
account default
host $SMTP_HOST
port ${SMTP_PORT:-587}
from ${SMTP_FROM:-$SMTP_TO}
user ${SMTP_USERNAME:-}
password ${SMTP_PASSWORD:-}
EOF
else
    : > /etc/msmtprc
fi
chown vaultwarden:vaultwarden /etc/msmtprc
chmod 600 /etc/msmtprc

exec su-exec vaultwarden:vaultwarden "$@"
