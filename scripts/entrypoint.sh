#!/bin/sh
set -eu

mkdir -p /data /data/restic-logs /app
chown -R vaultwarden:vaultwarden /data /app

if [ ! -f /data/backup-status.txt ]; then
    printf 'state=unknown\nupdated_at=0\nlast_success=0\nmessage=No backup run recorded\n' \
        > /data/backup-status.txt
    chown vaultwarden:vaultwarden /data/backup-status.txt
fi

touch /etc/msmtprc
chown vaultwarden:vaultwarden /etc/msmtprc
chmod 600 /etc/msmtprc

exec su-exec vaultwarden:vaultwarden "$@"
