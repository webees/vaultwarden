#!/bin/bash
# shellcheck disable=SC1091
set -euo pipefail

. /entrypoint/filesystem.sh
. /entrypoint/config.sh
. /entrypoint/restore.sh
. /entrypoint/smtp.sh

prepare_filesystem
harden_config_json
if [ -f /data/restore-pending ]; then
    apply_pending_restore
fi
configure_smtp

if [ "$#" -eq 0 ]; then
    exec su-exec vaultwarden:vaultwarden tini -g -- /services.sh
fi
exec su-exec vaultwarden:vaultwarden "$@"
