#!/bin/bash
set -euo pipefail

mkdir -p /data/restic-logs /app
chown -R vaultwarden:vaultwarden /data /app

if [ ! -f /data/backup-status.txt ]; then
    printf 'state=unknown\nupdated_at=0\nlast_success=0\nmessage=No backup run recorded\n' \
        > /data/backup-status.txt
fi
chown vaultwarden:vaultwarden /data/backup-status.txt /data/restic-logs

# A snapshot never carries the live db.* files: the consistent database travels
# as backup.bak. Swapping it in has to happen while Vaultwarden is not running,
# so `restore` arms the swap with a marker and this applies it before the app
# opens the database on the next start.
if [ -f /data/restore-pending ]; then
    if [ -f /data/backup.bak ]; then
        rm -f /data/db.sqlite3 /data/db.sqlite3-wal /data/db.sqlite3-shm
        cp /data/backup.bak /data/db.sqlite3
        chown vaultwarden:vaultwarden /data/db.sqlite3
        rm -f /data/restore-pending
        echo "Applied the pending restore: /data/backup.bak is now the live database" >&2
    else
        echo "restore-pending is set but /data/backup.bak is missing; leaving the database alone" >&2
    fi
fi

# Write the SMTP config as root, then hand it to the unprivileged user.
umask 077
if [ -n "${SMTP_HOST:-}" ] && [ -n "${SMTP_TO:-}" ]; then
    # Vaultwarden refuses to start when SMTP_HOST is set without SMTP_FROM,
    # while the backup script's msmtp config already defaults the sender to
    # SMTP_TO. Give the app the same default so enabling alerts (which only
    # needs HOST and TO here) cannot take the service down.
    export SMTP_FROM="${SMTP_FROM:-$SMTP_TO}"

    # Each value becomes one msmtprc line, so a newline would inject extra
    # directives. Refuse before writing anything instead of producing a
    # surprising config.
    for value in "$SMTP_HOST" "$SMTP_TO" "$SMTP_FROM" "${SMTP_USERNAME:-}" \
        "${SMTP_PASSWORD:-}" "${SMTP_PORT:-587}" "${SMTP_TIMEOUT:-15}"; do
        case "$value" in
            *$'\n'*|*$'\r'*)
                echo "SMTP values must not contain newlines" >&2
                exit 1
                ;;
        esac
    done

    {
        printf 'defaults\n'
        printf 'auth on\n'
        printf 'tls on\n'
        printf 'tls_trust_file /etc/ssl/certs/ca-certificates.crt\n'
        printf 'logfile /dev/stderr\n'
        printf 'timeout %s\n' "${SMTP_TIMEOUT:-15}"
        printf 'account default\n'
        printf 'host %s\n' "$SMTP_HOST"
        printf 'port %s\n' "${SMTP_PORT:-587}"
        printf 'from %s\n' "${SMTP_FROM:-$SMTP_TO}"
        printf 'user %s\n' "${SMTP_USERNAME:-}"
        printf 'password %s\n' "${SMTP_PASSWORD:-}"
    } > /etc/msmtprc
else
    : > /etc/msmtprc
fi
chown vaultwarden:vaultwarden /etc/msmtprc
chmod 600 /etc/msmtprc

exec su-exec vaultwarden:vaultwarden "$@"
