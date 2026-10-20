#!/bin/bash

# The application can write under /data, but the entrypoint runs as root. Never
# let a pre-existing link make a privileged chown/chmod act outside the volume.
replace_unsafe_path() {
    local path="$1" kind="$2"
    if [ -L "$path" ]; then
        echo "WARNING: replacing symlinked ${path}" >&2
        rm -f "$path"
        return 0
    fi
    case "$kind" in
        file) [ -f "$path" ] && return 0 ;;
        dir)  [ -d "$path" ] && return 0 ;;
        *)    echo "Internal error: unknown reserved path type '${kind}'" >&2; exit 2 ;;
    esac
    if [ -e "$path" ]; then
        echo "WARNING: replacing non-${kind} ${path}" >&2
        rm -rf "$path"
    fi
}

prepare_filesystem() {
    local status_file=/data/backup-status.txt mail_log=/data/restic-logs/msmtp.log
    mkdir -p /data /app
    replace_unsafe_path /data/restic-logs dir
    replace_unsafe_path "$status_file" file
    replace_unsafe_path "$mail_log" file
    mkdir -p /data/restic-logs
    if [ ! -f "$status_file" ]; then
        printf 'state=unknown\nupdated_at=0\nlast_success=0\nmessage=No backup run recorded\n' \
            > "$status_file"
    fi
    if [ ! -f "$mail_log" ]; then
        : > "$mail_log"
    fi

    chown -R vaultwarden:vaultwarden /data /app
    chmod 0700 /data/restic-logs
    chmod 0600 "$status_file"
    chmod 0600 "$mail_log"
}
