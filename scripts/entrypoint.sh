#!/bin/bash
set -euo pipefail

mkdir -p /data/restic-logs /app
chown -R vaultwarden:vaultwarden /data /app

if [ ! -f /data/backup-status.txt ]; then
    printf 'state=unknown\nupdated_at=0\nlast_success=0\nmessage=No backup run recorded\n' \
        > /data/backup-status.txt
fi
chown vaultwarden:vaultwarden /data/backup-status.txt /data/restic-logs

# The admin panel persists every non-default setting, secrets included, in
# /data/config.json, and Vaultwarden gives that file priority over the
# environment. Keep it owner-only and name the overriding secret keys in the
# log so a Fly secret that "does nothing" has a visible cause. Values are never
# printed: the log is shipped off-box.
harden_config_json() {
    local config=/data/config.json key overriding=""
    [ -f "$config" ] || return 0
    chown vaultwarden:vaultwarden "$config"
    chmod 600 "$config"
    for key in admin_token smtp_username smtp_password signups_allowed; do
        if grep -Eq "\"${key}\"[[:space:]]*:" "$config"; then
            overriding="${overriding}${overriding:+, }${key}"
        fi
    done
    if [ -n "$overriding" ]; then
        echo "WARNING: /data/config.json overrides these environment variables: ${overriding}" >&2
        echo "WARNING: remove those keys from /data/config.json and restart so the Fly secrets apply" >&2
    fi
}
harden_config_json

# A snapshot never carries the live db.* files: the consistent database travels
# as backup.bak. Swapping it in has to happen while Vaultwarden is not running,
# so `restore` arms the swap with a marker and this applies it before the app
# opens the database on the next start.
#
# Every failure here keeps the existing database, keeps the marker so the
# operator can fix the file and restart, and lets the app start: exiting would
# crash-loop the machine on a restore that cannot be applied.
apply_pending_restore() {
    local new=/data/db.sqlite3.new
    if [ ! -f /data/backup.bak ]; then
        echo "restore-pending is set but /data/backup.bak is missing; leaving the database alone" >&2
        return 0
    fi
    # A hot copy that is not a database would replace a working one with
    # something Vaultwarden cannot open at all.
    if ! sqlite3 /data/backup.bak 'PRAGMA integrity_check' 2>/dev/null | grep -qx ok; then
        echo "restore-pending is set but /data/backup.bak is not a readable database; leaving the database alone" >&2
        return 0
    fi
    # Write the replacement next to the live file and rename it into place: the
    # old rm-then-cp left a window with no database at all, so a failure in
    # between (or a crash) let Vaultwarden start on a fresh empty one.
    rm -f "$new"
    if ! cp /data/backup.bak "$new"; then
        echo "could not copy /data/backup.bak into place; leaving the database alone" >&2
        rm -f "$new"
        return 0
    fi
    chown vaultwarden:vaultwarden "$new"
    # Install the replacement before touching the old sidecars. The rename is
    # atomic, so a failure here leaves the live database and the write-ahead log
    # that belongs to it exactly as they were. Deleting the log first threw away
    # the transactions that were only in it whenever the rename then failed,
    # which is the opposite of "leaving the database alone".
    if ! mv -f "$new" /data/db.sqlite3; then
        echo "could not replace /data/db.sqlite3; leaving the database alone" >&2
        rm -f "$new"
        return 0
    fi
    # The old write-ahead log belongs to the database that was just replaced and
    # must not be replayed on top of the new one. Nothing opens the database
    # between the rename above and this line, and a crash in between leaves the
    # marker set, so the next start runs this whole block again.
    rm -f /data/db.sqlite3-wal /data/db.sqlite3-shm
    rm -f /data/restore-pending
    echo "Applied the pending restore: /data/backup.bak is now the live database" >&2
}

if [ -f /data/restore-pending ]; then
    apply_pending_restore
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
    if { [ -n "${SMTP_USERNAME:-}" ] && [ -z "${SMTP_PASSWORD:-}" ]; } \
        || { [ -z "${SMTP_USERNAME:-}" ] && [ -n "${SMTP_PASSWORD:-}" ]; }; then
        echo "SMTP_USERNAME and SMTP_PASSWORD must be set together" >&2
        exit 1
    fi

    {
        printf 'defaults\n'
        if [ -n "${SMTP_USERNAME:-}" ]; then
            printf 'auth on\n'
        else
            printf 'auth off\n'
        fi
        printf 'tls on\n'
        printf 'tls_trust_file /etc/ssl/certs/ca-certificates.crt\n'
        printf 'logfile /dev/stderr\n'
        printf 'timeout %s\n' "${SMTP_TIMEOUT:-15}"
        printf 'account default\n'
        printf 'host %s\n' "$SMTP_HOST"
        printf 'port %s\n' "${SMTP_PORT:-587}"
        printf 'from %s\n' "${SMTP_FROM:-$SMTP_TO}"
        if [ -n "${SMTP_USERNAME:-}" ]; then
            printf 'user %s\n' "$SMTP_USERNAME"
            printf 'password %s\n' "$SMTP_PASSWORD"
        fi
    } > /etc/msmtprc
else
    : > /etc/msmtprc
fi
chown vaultwarden:vaultwarden /etc/msmtprc
chmod 600 /etc/msmtprc

exec su-exec vaultwarden:vaultwarden "$@"
