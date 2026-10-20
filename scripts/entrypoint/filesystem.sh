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
    local status_file=/data/backup-status.txt
    mkdir -p /data /app
    replace_unsafe_path /data/restic-logs dir
    replace_unsafe_path "$status_file" file
    mkdir -p /data/restic-logs
    if [ ! -f "$status_file" ]; then
        printf 'state=unknown\nupdated_at=0\nlast_success=0\nmessage=No backup run recorded\n' \
            > "$status_file"
    fi

    chown -R vaultwarden:vaultwarden /data /app
    chmod 0700 /data/restic-logs
    chmod 0600 "$status_file"
}

# The admin panel persists every non-default setting, secrets included, in
# /data/config.json, and Vaultwarden gives that file priority over the
# environment. Keep it owner-only and name the overriding secret keys in the
# log so a Fly secret that "does nothing" has a visible cause. Values are never
# printed: the log is shipped off-box.
harden_config_json() {
    local config=/data/config.json key overriding=""
    if [ -L "$config" ]; then
        echo "WARNING: refusing symlinked /data/config.json" >&2
        return 0
    fi
    if [ -e "$config" ] && [ ! -f "$config" ]; then
        echo "WARNING: refusing non-file /data/config.json" >&2
        return 0
    fi
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
