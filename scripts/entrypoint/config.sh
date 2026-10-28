#!/bin/bash

is_numeric_host() {
    local label
    local -a labels=()
    IFS=. read -r -a labels <<< "$1"
    [ "${#labels[@]}" -gt 0 ] || return 1
    for label in "${labels[@]}"; do
        [[ "$label" =~ ^[0-9]+$ || "$label" =~ ^0[xX][0-9A-Fa-f]+$ ]] || return 1
    done
}

valid_dns_name() {
    local name="$1"
    [ "${#name}" -le 253 ] \
        && ! is_numeric_host "$name" \
        && [[ "$name" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

valid_host_port() {
    local authority="$1" host port
    case "$authority" in
        ''|*@*|*//*|*[[:space:][:cntrl:]\\?#%]*) return 1 ;;
    esac
    host="$authority" port=""
    if [[ "$authority" == *:* ]]; then
        host="${authority%:*}" port="${authority##*:}"
        [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] || return 1
    fi
    valid_dns_name "$host"
}

validate_caddy_addresses() {
    local item index seen=' ' IFS=' '
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
    validate_https_url "$DOMAIN" false
}

validate_restic_repository() {
    local repository="${RESTIC_REPOSITORY:-}" authority host path
    [ -n "$repository" ] || return 0
    case "$repository" in
        *[[:space:][:cntrl:]]*) echo "Error: RESTIC_REPOSITORY must not contain whitespace or control characters" >&2; return 2 ;;
        /*)
            [ "${#repository}" -le 2048 ] || { echo "Error: RESTIC_REPOSITORY is too long" >&2; return 2; }
            case "$repository" in /|*'/../'*|../*|*/..|*'/./'*|./*|*/.*|*'//'*|*[\\?#%]*)
                echo "Error: RESTIC_REPOSITORY contains an ambiguous local path" >&2; return 2 ;;
            esac
            return 0
            ;;
        s3://?*) ;;
        *) echo "Error: RESTIC_REPOSITORY must be an absolute path or s3:// URI" >&2; return 2 ;;
    esac
    [ "${#repository}" -le 2048 ] || { echo "Error: RESTIC_REPOSITORY is too long" >&2; return 2; }
    authority="${repository#s3://}"
    case "$authority" in *@*) echo "Error: RESTIC_REPOSITORY must not contain userinfo" >&2; return 2 ;; esac
    host="${authority%%/*}" path="${authority#*/}"
    if [ "$path" = "$authority" ] || [ -z "$path" ] || ! valid_host_port "$host"; then
        echo "Error: RESTIC_REPOSITORY has an invalid host or empty path" >&2
        return 2
    fi
    case "$path" in
        *//*|*'/../'*|../*|*/..|*'/./'*|./*|*/.*|*[[:space:][:cntrl:]\\?#%@]*)
            echo "Error: RESTIC_REPOSITORY contains an ambiguous or unsafe path" >&2
            return 2
            ;;
    esac
}

validate_https_url() {
    local value="$1" allow_path="$2" authority path rest
    [ "${#value}" -le 2048 ] || { echo "Error: HTTPS URL is too long" >&2; return 2; }
    case "$value" in
        *[[:space:][:cntrl:]]*) echo "Error: HTTPS URL must not contain whitespace or control characters" >&2; return 2 ;;
        https://?*) rest="${value#https://}" ;;
        *) echo "Error: HTTPS URL must be an https URL" >&2; return 2 ;;
    esac
    authority="${rest%%/*}" path=""
    [ "$authority" = "$rest" ] || path="/${rest#*/}"
    if ! valid_host_port "$authority"; then
        echo "Error: HTTPS URL contains an invalid host or port" >&2
        return 2
    fi
    if [ "$allow_path" != true ] && [ -n "$path" ]; then
        echo "Error: DOMAIN must be an https URL without userinfo, query, fragment, or path" >&2
        return 2
    fi
    [ -z "$path" ] && return 0
    [ "${#path}" -le 1024 ] || { echo "Error: HTTPS URL path is too long" >&2; return 2; }
    case "$path" in
        *//*|*'/../'*|../*|*/..|*'/./'*|./*|*/.*|*[!A-Za-z0-9._~/-]*)
            echo "Error: HTTPS URL contains an unsafe or ambiguous path" >&2
            return 2
            ;;
    esac
}

validate_healthcheck_url() {
    [ -z "${HEALTHCHECK_URL:-}" ] && return 0
    validate_https_url "$HEALTHCHECK_URL" true \
        || { echo "Error: HEALTHCHECK_URL is unsafe or ambiguous" >&2; return 2; }
    HEALTHCHECK_URL="${HEALTHCHECK_URL%/}"
}

emit_address_audit() {
    [ "${ADDRESS_AUDIT_JSON:-0}" = 1 ] || return 0
    local -a domains=()
    local kind=unset domain=false healthcheck=false
    read -r -a domains <<< "$CADDY_DOMAINS"
    [ -z "${DOMAIN:-}" ] || domain=true
    [ -z "${HEALTHCHECK_URL:-}" ] || healthcheck=true
    case "${RESTIC_REPOSITORY:-}" in
        '') ;;
        s3://*) kind=s3 ;;
        /*) kind=local ;;
    esac
    printf '{"status":"ok","caddy_hosts":%d,"domain_configured":%s,"repository_kind":"%s","healthcheck_configured":%s}\n' \
        "${#domains[@]}" "$domain" "$kind" "$healthcheck"
}

audit_addresses() {
    validate_caddy_addresses || return $?
    validate_restic_repository || return $?
    validate_healthcheck_url || return $?
    emit_address_audit
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
