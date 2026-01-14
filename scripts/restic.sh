#!/bin/bash
# =============================================================================
# Restic Backup - Vaultwarden
# =============================================================================
# SQLite hot backup + Restic incremental backup
# Usage: /restic.sh {backup|restore <id>|snapshots}
# =============================================================================

set -o pipefail

# =============================================================================
# Config
# =============================================================================
APP_NAME="Vaultwarden"                        # App name (for notification)
DATA="/data"                                  # Data directory
DB="$DATA/db.sqlite3"                         # SQLite main database
DB_BAK="$DATA/backup.bak"                     # SQLite hot backup
LOG_DIR="/var/log/restic"                     # Log directory
LOG="$LOG_DIR/$(date +%Y%m%d_%H%M%S).log"     # Current log file
mkdir -p "$LOG_DIR"

# Colors (ANSI escape)
R="\x1b[31;01m" G="\x1b[32;01m" Y="\x1b[33;01m" B="\x1b[34;01m" X="\x1b[0m"

# =============================================================================
# Utilities
# =============================================================================

# Log output (terminal + file)
log() { "$@" 2>&1 | tee -a "$LOG"; }

# Send email (strip ANSI colors)
mail() {
    [ -z "${SMTP_TO:-}" ] && return
    sed 's/\x1b\[[0-9;]*m//g' "$LOG" | command mail -s "[$APP_NAME] $1" "$SMTP_TO"
}

# Execute command and handle result
# Usage: run "command" "step name"
# Success: print step ✓
# Failure: print step ✗ + error details, send email, exit 2
run() {
    log echo -en "${B}$2${X} "                  # Print step name (no newline)
    local out
    out=$(eval "$1" 2>&1)                       # Execute and capture output
    if [ $? -eq 0 ]; then
        log echo -e "${G}✓${X}"                 # Success: green checkmark
        return 0
    fi
    log echo -e "${R}✗${X}"                     # Failure: red cross
    log echo "$out"                             # Error details
    mail "$2"                                   # Email notification
    exit 2
}

# Initialize mail config
initMail() {
    # Check required SMTP variables
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

# =============================================================================
# Command: backup
# =============================================================================
# Backup flow:
#   1. Unlock repo (clear stale locks)
#   2. Check/init repo
#   3. SQLite hot backup (.backup doesn't lock main db)
#   4. Verify backup integrity (PRAGMA integrity_check)
#   5. Restic incremental backup (exclude main db)
#   6. Restic repo consistency check
#   7. Prune old snapshots (7d/4w/3m/3y)
#   8. Cleanup old logs (>10h)
# =============================================================================
cmdBackup() {
    # Unlock (clear stale locks from interrupted backups)
    restic unlock 2>/dev/null || true

    # Check/init repo
    if ! restic cat config >/dev/null 2>&1; then
        log echo -e "${Y}Repo not initialized${X}"
        run "restic init" "Repo init"
    fi

    run "sqlite3 '$DB' '.backup $DB_BAK'" "SQLite backup"
    run "sqlite3 '$DB_BAK' 'PRAGMA integrity_check'" "SQLite verify"
    run "restic backup --verbose --exclude='db.*' '$DATA'" "Restic backup"
    run "restic check" "Restic check"
    run "restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --keep-yearly 3 --prune" "Snapshot prune"

    # Cleanup old logs (>600min = 10h)
    find "$LOG_DIR" -name "*.log" -type f -mmin +600 -delete

    log echo -e "${G}Backup complete ✨${X}"
}

# =============================================================================
# Command: restore <id>
# =============================================================================
cmdRestore() {
    [ -z "${1:-}" ] && { echo "Usage: $0 restore <id>"; exit 1; }
    run "restic restore '$1' --target /" "Restore $1"
}

# =============================================================================
# Main
# =============================================================================

# Environment check
[ -z "${RESTIC_PASSWORD:-}" ] && { echo "Missing RESTIC_PASSWORD"; exit 1; }

# Init mail
initMail

# Command router
case "${1:-}" in
    backup)    cmdBackup ;;
    restore)   cmdRestore "${2:-}" ;;
    snapshots) restic snapshots ;;
    *)
        echo "Usage: $0 {backup|restore <id>|snapshots}"
        exit 1
        ;;
esac
