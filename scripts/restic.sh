#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Restic Backup Script                                                      ║
# ║ Usage: /restic.sh {backup|restore <id>|snapshots|test}                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -o pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
APP_NAME="${FLY_APP_NAME:-Vaultwarden}"
DATA="/data"
LOG_DIR="/var/log/restic"
LOG="$LOG_DIR/$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR"

# ANSI colors
R="\x1b[31;01m" G="\x1b[32;01m" Y="\x1b[33;01m" B="\x1b[34;01m" X="\x1b[0m"

# ── Utilities ─────────────────────────────────────────────────────────────────

# Log output to file and stdout
log() { "$@" 2>&1 | tee -a "$LOG"; }

# Optional dead-man's-switch ping (e.g. healthchecks.io). No-op when HEALTHCHECK_URL is unset.
heartbeat() {
    [ -z "${HEALTHCHECK_URL:-}" ] && return 0
    local suffix=""
    [ "${1:-ok}" = "fail" ] && suffix="/fail"
    curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}${suffix}" >/dev/null 2>&1 \
        || log echo -e "${Y}Heartbeat ping failed${X}"
}

# Send email notification
mail() {
    [ -z "${SMTP_TO:-}" ] && return
    # Strip ANSI colors and set UTF-8
    sed 's/\x1b\[[0-9;]*m//g' "$LOG" | command mail \
        -a "Content-Type: text/plain; charset=UTF-8" \
        -s "[$APP_NAME] $1" "$SMTP_TO"
}

# Run command and log status
run() {
    log echo -en "${B}$2${X} "
    local out
    if out=$(eval "$1" 2>&1); then
        log echo -e "${G}✓${X}"
        return 0
    fi
    log echo -e "${R}✗${X}"
    log echo "$out"
    mail "Task Failed: $2"
    heartbeat fail
    cleanup_logs
    exit 2
}

# Initialize SMTP configuration
initCfg() {
    [ -z "${SMTP_TO:-}" ] && return
    [ -z "${SMTP_HOST:-}" ] && return

    cat > /etc/msmtprc << EOF
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log
account default
host $SMTP_HOST
port ${SMTP_PORT:-587}
from $SMTP_FROM
user $SMTP_USERNAME
password $SMTP_PASSWORD
EOF
}

# ── Business Logic ────────────────────────────────────────────────────────────

# Drop backup logs older than 10 hours
cleanup_logs() {
    find "$LOG_DIR" -name "*.log" -type f -mmin +600 -delete
}

# Backup, check and prune
backup() {
    # Clock accuracy comes from the Fly.io host; Alpine provides no ntpdate binary

    # Unlock repository
    restic unlock 2>/dev/null || true

    # Initialize repository if needed
    if ! restic cat config >/dev/null 2>&1; then
        log echo -e "${Y}Repository not initialized, initializing...${X}"
        run "restic init" "Repo init"
    fi

    # SQLite hot backup (ensures consistency)
    run "sqlite3 '$DATA/db.sqlite3' '.backup $DATA/backup.bak'" "SQLite backup"
    run "sqlite3 '$DATA/backup.bak' 'PRAGMA integrity_check'" "SQLite check"

    # Core operations (exclude original db files, use backup.bak instead)
    run "restic backup --verbose --exclude='db.*' '$DATA'" "Data backup"
    run "restic check" "Health check"
    run "restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --keep-yearly 3 --prune" "Snapshot prune"

    cleanup_logs

    log echo -e "${G}Backup process complete ✨${X}"
    heartbeat ok
}

# Restore data from snapshot
restore() {
    [ -z "${1:-}" ] && { echo "Usage: $0 restore <snapshot-id>"; exit 1; }
    run "restic restore '$1' --target /" "Restore snapshot $1"
}

# ── Entry Point ───────────────────────────────────────────────────────────────

if [ -z "${RESTIC_PASSWORD:-}" ]; then
    echo "Error: RESTIC_PASSWORD not set"
    heartbeat fail
    exit 1
fi

initCfg

case "${1:-}" in
    backup)    backup ;;
    restore)   restore "${2:-}" ;;
    snapshots) restic snapshots ;;
    test)      echo "Test email from $APP_NAME backup system." | command mail -s "[$APP_NAME] Test Mail" "$SMTP_TO" && echo "Test mail sent to $SMTP_TO" ;;
    *)         echo "Usage: $0 {backup|restore <id>|snapshots|test}"; exit 1 ;;
esac
