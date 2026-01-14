#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Restic Backup - Vaultwarden                                               ║
# ║ Usage: /restic.sh {backup|restore <id>|snapshots}                         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -o pipefail

# ┌───────────────────────────────────────────────────────────────────────────┐
# │ Configuration                                                             │
# └───────────────────────────────────────────────────────────────────────────┘
APP_NAME="Vaultwarden"
DATA="/data"
DB="$DATA/db.sqlite3"
DB_BAK="$DATA/backup.bak"
LOG_DIR="/var/log/restic"
LOG="$LOG_DIR/$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR"

# ANSI colors
R="\x1b[31;01m" G="\x1b[32;01m" Y="\x1b[33;01m" B="\x1b[34;01m" X="\x1b[0m"

# ┌───────────────────────────────────────────────────────────────────────────┐
# │ Utilities                                                                 │
# └───────────────────────────────────────────────────────────────────────────┘

log() { "$@" 2>&1 | tee -a "$LOG"; }

mail() {
    [ -z "${SMTP_TO:-}" ] && return
    sed 's/\x1b\[[0-9;]*m//g' "$LOG" | command mail -s "[$APP_NAME] $1" "$SMTP_TO"
}

run() {
    log echo -en "${B}$2${X} "
    local out
    out=$(eval "$1" 2>&1)
    if [ $? -eq 0 ]; then
        log echo -e "${G}✓${X}"
        return 0
    fi
    log echo -e "${R}✗${X}"
    log echo "$out"
    mail "$2"
    exit 2
}

initMail() {
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

# ┌───────────────────────────────────────────────────────────────────────────┐
# │ Commands                                                                  │
# └───────────────────────────────────────────────────────────────────────────┘

cmdBackup() {
    restic unlock 2>/dev/null || true

    if ! restic cat config >/dev/null 2>&1; then
        log echo -e "${Y}Repo not initialized${X}"
        run "restic init" "Repo init"
    fi

    run "sqlite3 '$DB' '.backup $DB_BAK'" "SQLite backup"
    run "sqlite3 '$DB_BAK' 'PRAGMA integrity_check'" "SQLite verify"
    run "restic backup --verbose --exclude='db.*' '$DATA'" "Restic backup"
    run "restic check" "Restic check"
    run "restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --keep-yearly 3 --prune" "Snapshot prune"

    find "$LOG_DIR" -name "*.log" -type f -mmin +600 -delete

    log echo -e "${G}Backup complete ✨${X}"
}

cmdRestore() {
    [ -z "${1:-}" ] && { echo "Usage: $0 restore <id>"; exit 1; }
    run "restic restore '$1' --target /" "Restore $1"
}

# ┌───────────────────────────────────────────────────────────────────────────┐
# │ Main                                                                      │
# └───────────────────────────────────────────────────────────────────────────┘

[ -z "${RESTIC_PASSWORD:-}" ] && { echo "Missing RESTIC_PASSWORD"; exit 1; }

initMail

case "${1:-}" in
    backup)    cmdBackup ;;
    restore)   cmdRestore "${2:-}" ;;
    snapshots) restic snapshots ;;
    *)         echo "Usage: $0 {backup|restore <id>|snapshots}"; exit 1 ;;
esac
