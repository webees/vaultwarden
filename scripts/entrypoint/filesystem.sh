#!/bin/bash

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
    mkdir -p /data/restic-logs
    rm -rf -- "$mail_log"
    if [ ! -f "$status_file" ]; then
        printf 'state=unknown\nupdated_at=0\nlast_success=0\nmessage=No backup run recorded\n' \
            > "$status_file"
    fi

    chown -R vaultwarden:vaultwarden /data /app
    # chmod -R would follow application-created links outside the volume.
    chmod 0700 /data /app
    find /data -xdev -type d -exec chmod 0700 {} +
    find /data -xdev -type f -exec chmod 0600 {} +
    chmod 0600 "$status_file"
}
