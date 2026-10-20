#!/bin/bash
set -euo pipefail

entrypoint_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/entrypoint"
# shellcheck source=scripts/entrypoint/filesystem.sh
. "${entrypoint_dir}/filesystem.sh"
# shellcheck source=scripts/entrypoint/restore.sh
. "${entrypoint_dir}/restore.sh"
# shellcheck source=scripts/entrypoint/smtp.sh
. "${entrypoint_dir}/smtp.sh"

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
