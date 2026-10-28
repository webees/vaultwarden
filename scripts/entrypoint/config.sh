#!/bin/bash

# /data/config.json outranks environment variables; never log its values.
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
    for key in admin_token signups_allowed; do
        if grep -Eq "\"${key}\"[[:space:]]*:" "$config"; then
            overriding="${overriding}${overriding:+, }${key}"
        fi
    done
    while IFS= read -r key; do
        overriding="${overriding}${overriding:+, }${key}"
    done < <(
        grep -Eo '"smtp_[A-Za-z0-9_]+"[[:space:]]*:' "$config" \
            | sed -E 's/^"([^"]+)".*/\1/' \
            | sort -u
    )
    if [ -n "$overriding" ]; then
        echo "WARNING: /data/config.json overrides these environment variables: ${overriding}" >&2
        echo "WARNING: remove those keys from /data/config.json and restart so the Fly secrets apply" >&2
    fi
}
