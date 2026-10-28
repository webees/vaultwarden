#!/bin/bash

configure_smtp() {
    umask 077
    if [ -n "${SMTP_HOST:-}" ] && [ -n "${SMTP_TO:-}" ]; then
        export SMTP_FROM="${SMTP_FROM:-$SMTP_TO}"

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
}
