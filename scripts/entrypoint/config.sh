#!/bin/bash

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
    for key in admin_token signups_allowed; do
        if grep -Eq "\"${key}\"[[:space:]]*:" "$config"; then
            overriding="${overriding}${overriding:+, }${key}"
        fi
    done
    # Vaultwarden can add SMTP keys at any time. Match the prefix instead of
    # maintaining a short list that silently misses host, port or future keys.
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
