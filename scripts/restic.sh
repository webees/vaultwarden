#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Restic Backup Script                                                      ║
# ║ Usage: /restic.sh {backup|restore <id>|snapshots|mail-test}               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -o pipefail

# ┌───────────────────────────────────────────────────────────────────────────┐
# │ Configuration                                                             │
# └───────────────────────────────────────────────────────────────────────────┘
APP_NAME="Vaultwarden"
DATA="/data"
LOG_DIR="/var/log/restic"
LOG="$LOG_DIR/$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR"

# ANSI colors for terminal output
R="\x1b[31;01m" G="\x1b[32;01m" Y="\x1b[33;01m" B="\x1b[34;01m" X="\x1b[0m"

# ┌───────────────────────────────────────────────────────────────────────────┐
# │ Utilities                                                                 │
# └───────────────────────────────────────────────────────────────────────────┘

# Log output to both stdout and a log file
log() { "$@" 2>&1 | tee -a "$LOG"; }

# Send email notification on failure or test
mail() {
    [ -z "${SMTP_TO:-}" ] && return
    # Strip ANSI colors and add UTF-8 content-type
    sed 's/\x1b\[[0-9;]*m//g' "$LOG" | command mail \
        -a "Content-Type: text/plain; charset=UTF-8" \
        -s "[$APP_NAME] $1" "$SMTP_TO"
}

# Run a command and log its status
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
    mail "Task Failed: $2"
    exit 2
}

# Initialize msmtp configuration for email sending
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

# Perform full backup, check, and prune
cmdBackup() {
    # Sync time to ensure S3/R2 requests are valid
    ntpdate -u pool.ntp.org 2>/dev/null || log echo -e "${Y}NTP sync skipped${X}"

    # Unlock repository in case of previous interrupted runs
    restic unlock 2>/dev/null || true

    # Initialize repository if it doesn't exist
    if ! restic cat config >/dev/null 2>&1; then
        log echo -e "${Y}Repository not initialized, initializing now...${X}"
        run "restic init" "Repo init"
    fi

    # Execute restic operations
    run "restic backup --verbose '$DATA'" "Restic backup"
    run "restic check" "Restic check"
    run "restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --keep-yearly 3 --prune" "Snapshot prune"

    # Cleanup old logs (older than 10 hours)
    find "$LOG_DIR" -name "*.log" -type f -mmin +600 -delete

    log echo -e "${G}Backup process complete ✨${X}"
}

# Restore data from a specific snapshot ID
cmdRestore() {
    [ -z "${1:-}" ] && { echo "Usage: $0 restore <snapshot-id>"; exit 1; }
    run "restic restore '$1' --target /" "Restore $1"
}

# ┌───────────────────────────────────────────────────────────────────────────┐
# │ Execution Entry Point                                                     │
# └───────────────────────────────────────────────────────────────────────────┘

[ -z "${RESTIC_PASSWORD:-}" ] && { echo "Error: RESTIC_PASSWORD not set"; exit 1; }

initMail

case "${1:-}" in
    backup)    cmdBackup ;;
    restore)   cmdRestore "${2:-}" ;;
    snapshots) restic snapshots ;;
    mail-test) echo "This is a test email from the $APP_NAME backup system." | command mail -s "[$APP_NAME] Mail Test" "$SMTP_TO" && echo "Test email sent to $SMTP_TO" ;;
    *)         echo "Usage: $0 {backup|restore <id>|snapshots|mail-test}"; exit 1 ;;
esac
