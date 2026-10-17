#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Restic Backup Script                                                      ║
# ║ Usage: /restic.sh {backup|restore <id>|snapshots|verify|test}             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -o pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
APP_NAME="${FLY_APP_NAME:-Vaultwarden}"
DATA="/data"
LOG_DIR="${RESTIC_LOG_DIR:-/data/restic-logs}"
LOG="$LOG_DIR/$(date +%Y%m%d_%H%M%S).log"
MAX_LOG_BYTES="${RESTIC_LOG_MAX_BYTES:-262144}"
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
# The outer timeout keeps a stalled SMTP relay from blocking the whole backup run.
mail() {
    [ -z "${SMTP_TO:-}" ] && return
    # Strip ANSI colors and set UTF-8
    sed 's/\x1b\[[0-9;]*m//g' "$LOG" | timeout 45 mail \
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
    if [ "${#out}" -gt "$MAX_LOG_BYTES" ]; then
        out=$(printf '%s' "$out" | tail -c "$MAX_LOG_BYTES")
        out="[output truncated to the last ${MAX_LOG_BYTES} bytes]"$'\n'"$out"
    fi
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

    # umask 077: the file holds the SMTP password, so keep it root-only readable
    ( umask 077; cat > /etc/msmtprc << EOF
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log
timeout ${SMTP_TIMEOUT:-15}
account default
host $SMTP_HOST
port ${SMTP_PORT:-587}
from $SMTP_FROM
user $SMTP_USERNAME
password $SMTP_PASSWORD
EOF
    )
    chmod 600 /etc/msmtprc
}

# ── Business Logic ────────────────────────────────────────────────────────────

# Drop logs older than 10 hours and cap any oversized file left by an earlier run
cap_log_file() {
    local file="$1" size tmp
    [ -f "$file" ] || return 0
    size=$(wc -c < "$file" 2>/dev/null || echo 0)
    [ "$size" -gt "$MAX_LOG_BYTES" ] || return 0
    tmp="${file}.tmp.$$"
    if tail -c "$MAX_LOG_BYTES" "$file" > "$tmp"; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
    fi
}

cleanup_logs() {
    find "$LOG_DIR" -name "*.log" -type f -mmin +600 -delete
    for file in "$LOG_DIR"/*.log; do
        [ -e "$file" ] || continue
        cap_log_file "$file"
    done
}

# Backup, check and prune
backup() {
    # Clock accuracy comes from the Fly.io host; Alpine provides no ntpdate binary

    # Skip instead of fighting over the repository when a manual run is already active
    exec 9>"$LOG_DIR/backup.lock"
    if ! flock -n 9; then
        log echo -e "${Y}Another backup is already running, skipping this run${X}"
        exit 3
    fi

    # Remove stale locks left behind by an interrupted run (active locks are kept)
    restic unlock 2>/dev/null || true

    # Initialise only when the repository really is missing (restic exit code 10).
    # A wrong password (12) or an unreachable backend (1) must be reported as such,
    # otherwise "restic init" answers with a misleading "already initialized" error.
    restic cat config >/dev/null 2>&1 && rc=0 || rc=$?
    case "$rc" in
        0)  ;;
        10) log echo -e "${Y}Repository not initialized, initializing...${X}"
            run "restic init" "Repo init" ;;
        *)  run "restic cat config" "Repository access" ;;
    esac

    # SQLite hot backup (ensures consistency)
    run "sqlite3 '$DATA/db.sqlite3' '.backup $DATA/backup.bak'" "SQLite backup"
    run "sqlite3 '$DATA/backup.bak' 'PRAGMA integrity_check'" "SQLite check"

    # Core operations (exclude live db files, rebuildable cache, and local logs)
    run "restic backup --verbose --exclude='db.*' --exclude='icon_cache' --exclude='restic-logs' '$DATA'" "Data backup"
    run "restic check" "Health check"
    run "restic forget --keep-hourly 24 --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --keep-yearly 3 --prune" "Snapshot prune"

    cleanup_logs

    log echo -e "${G}Backup process complete ✨${X}"
    heartbeat ok
}

# Restore data from snapshot
restore() {
    [ -z "${1:-}" ] && { echo "Usage: $0 restore <snapshot-id>"; exit 1; }
    run "restic restore '$1' --target /" "Restore snapshot $1"
}

# Read back a slice of the stored data to prove the repository is really readable
verify() {
    run "restic check --read-data-subset=${VERIFY_SUBSET:-10%}" "Repository data verification"
    heartbeat ok
}

# ── Entry Point ───────────────────────────────────────────────────────────────

cleanup_logs

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
    verify)    verify ;;
    test)      echo "Test email from $APP_NAME backup system." | command mail -s "[$APP_NAME] Test Mail" "$SMTP_TO" && echo "Test mail sent to $SMTP_TO" ;;
    *)         echo "Usage: $0 {backup|restore <id>|snapshots|verify|test}"; exit 1 ;;
esac
