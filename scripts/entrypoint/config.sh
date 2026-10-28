#!/bin/bash

valid_dns_name() {
    local name="$1"
    [ "${#name}" -le 253 ] \
        && [[ "$name" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

validate_caddy_addresses() {
    local host port authority item index seen=' ' IFS=' '
    local -a domains=()
    CADDY_DOMAINS="${CADDY_DOMAINS:-localhost}"
    case "$CADDY_DOMAINS" in
        *[[:cntrl:]]*) echo "CADDY_DOMAINS must not contain control characters" >&2; return 2 ;;
    esac
    read -r -a domains <<< "$CADDY_DOMAINS"
    [ "${#domains[@]}" -gt 0 ] || { echo "CADDY_DOMAINS must contain at least one host" >&2; return 2; }
    for index in "${!domains[@]}"; do
        item="${domains[index]}"
        valid_dns_name "$item" || {
            echo "CADDY_DOMAINS entry $((index + 1)) is not a valid DNS name" >&2
            return 2
        }
        item="$(printf '%s' "$item" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        case "$seen" in *" $item "*) echo "CADDY_DOMAINS contains a duplicate host" >&2; return 2 ;; esac
        domains[index]="$item"
        seen+=" $item "
    done
    CADDY_DOMAINS="${domains[*]}"

    [ -z "${DOMAIN:-}" ] && return 0
    case "$DOMAIN" in
        *[[:space:][:cntrl:]]*) echo "DOMAIN must not contain whitespace or control characters" >&2; return 2 ;;
    esac
    case "$DOMAIN" in
        https://?*) authority="${DOMAIN#https://}" ;;
        *) echo "DOMAIN must be an https URL without userinfo, query, fragment, or path" >&2; return 2 ;;
    esac
    case "$authority" in *[/?#@[:space:][:cntrl:]]*|'') echo "DOMAIN must be an https URL without userinfo, query, fragment, or path" >&2; return 2 ;; esac
    host="$authority" port=""
    if [[ "$authority" == *:* ]]; then
        host="${authority%:*}"
        port="${authority##*:}"
        [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] \
            || { echo "DOMAIN contains an invalid port" >&2; return 2; }
    fi
    valid_dns_name "$host" || { echo "DOMAIN contains an invalid host" >&2; return 2; }
}

validate_restic_repository() {
    local repository="${RESTIC_REPOSITORY:-}" authority host path
    [ -n "$repository" ] || return 0
    case "$repository" in
        *[[:space:][:cntrl:]]*) echo "Error: RESTIC_REPOSITORY must not contain whitespace or control characters" >&2; exit 2 ;;
        /*)
            case "${repository}/" in *'/../'*|*'/./'*|*'//'*)
                echo "Error: RESTIC_REPOSITORY contains an ambiguous local path" >&2; exit 2 ;;
            esac
            return 0
            ;;
        s3://?*) ;;
        *) echo "Error: RESTIC_REPOSITORY must be an absolute path or s3:// URI" >&2; exit 2 ;;
    esac
    authority="${repository#s3://}"
    case "$authority" in *@*) echo "Error: RESTIC_REPOSITORY must not contain userinfo" >&2; exit 2 ;; esac
    host="${authority%%/*}" path="${authority#*/}"
    if [ "$path" = "$authority" ] || [ -z "$path" ] || ! valid_dns_name "$host"; then
        echo "Error: RESTIC_REPOSITORY has an invalid host or empty path" >&2
        exit 2
    fi
    case "$path" in
        *//*|*'/../'*|../*|*/..|*'/./'*|./*|*/.*|*[[:space:][:cntrl:]\\?#%]*)
            echo "Error: RESTIC_REPOSITORY contains an ambiguous or unsafe path" >&2
            exit 2
            ;;
    esac
}

validate_healthcheck_url() {
    local authority host port
    [ -z "${HEALTHCHECK_URL:-}" ] && return 0
    case "$HEALTHCHECK_URL" in
        *[[:space:][:cntrl:]]*) echo "Error: HEALTHCHECK_URL must not contain whitespace or control characters" >&2; exit 2 ;;
        https://?*) authority="${HEALTHCHECK_URL#https://}" ;;
        *) echo "Error: HEALTHCHECK_URL must use https" >&2; exit 2 ;;
    esac
    case "$authority" in
        *[#?@\\%]*|*'//'*|*'/../'*|../*|*/..|*'/./'*|./*|*/.*)
            echo "Error: HEALTHCHECK_URL contains an unsafe or ambiguous component" >&2
            exit 2
            ;;
    esac
    host="${authority%%/*}" port=""
    if [[ "$host" == *:* ]]; then
        port="${host##*:}" host="${host%:*}"
        [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] \
            || { echo "Error: HEALTHCHECK_URL contains an invalid port" >&2; exit 2; }
    fi
    valid_dns_name "$host" || { echo "Error: HEALTHCHECK_URL contains an invalid host" >&2; exit 2; }
    HEALTHCHECK_URL="${HEALTHCHECK_URL%/}"
}

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
