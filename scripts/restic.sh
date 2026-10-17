#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Restic Backup Script                                                      ║
# ║ Usage: /restic.sh {backup|restore <id>|restore-test [id]|snapshots|verify|test} ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -o pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
APP_NAME="${FLY_APP_NAME:-Vaultwarden}"
DATA="/data"
LOG_DIR="${RESTIC_LOG_DIR:-/data/restic-logs}"
LOG="$LOG_DIR/$(date +%Y%m%d_%H%M%S).log"
MAX_LOG_BYTES="${RESTIC_LOG_MAX_BYTES:-262144}"
MAX_LOG_DIR_BYTES="${RESTIC_LOG_DIR_MAX_BYTES:-10485760}"
QUICK_TIMEOUT="${RESTIC_QUICK_TIMEOUT:-60}"
LONG_TIMEOUT="${RESTIC_LONG_TIMEOUT:-1800}"
STATUS_FILE="/data/backup-status.txt"
LAST_SUCCESS="$(sed -n 's/^last_success=//p' "$STATUS_FILE" 2>/dev/null | head -n 1)"
LAST_SUCCESS="${LAST_SUCCESS:-0}"
UPDATE_BACKUP_STATUS=0
mkdir -p "$LOG_DIR"

# ANSI colors
R="\x1b[31;01m" G="\x1b[32;01m" Y="\x1b[33;01m" B="\x1b[34;01m" X="\x1b[0m"

# ── Utilities ─────────────────────────────────────────────────────────────────

# Log output to file and stdout
log() { "$@" 2>&1 | tee -a "$LOG"; }

# Persist a small freshness marker for the external watchdog
write_status() {
    local state="$1" message="${2:-}" now tmp
    now="$(date -u +%s)"
    tmp="${STATUS_FILE}.tmp.$$"
    {
        printf 'state=%s\n' "$state"
        printf 'updated_at=%s\n' "$now"
        printf 'last_success=%s\n' "$LAST_SUCCESS"
        printf 'message=%s\n' "$message"
    } > "$tmp" && mv "$tmp" "$STATUS_FILE"
}

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
    local label="$1" timeout_seconds="$2" out_file raw_file
    shift 2
    out_file="$(mktemp "${TMPDIR:-/tmp}/restic-run.XXXXXX")" || {
        log echo -e "${R}Unable to create temporary output file${X}"
        exit 2
    }
    raw_file="$(mktemp "${TMPDIR:-/tmp}/restic-raw.XXXXXX")" || {
        rm -f "$out_file"
        log echo -e "${R}Unable to create temporary output file${X}"
        exit 2
    }
    log echo -en "${B}${label}${X} "
    # Hard-cap raw command output on disk at 8x the retained log size, so a
    # runaway command cannot fill the volume before the tail truncation runs.
    local raw_limit_kb=$(( (MAX_LOG_BYTES * 8 + 1023) / 1024 ))
    local rc=0
    (
        ulimit -f "$((raw_limit_kb * 2))"
        timeout -k 30 "$timeout_seconds" "$@"
    ) > "$raw_file" 2>&1 || rc=$?
    tail -c "$MAX_LOG_BYTES" "$raw_file" > "$out_file"
    rm -f "$raw_file"
    if [ "$rc" -eq 0 ]; then
        log echo -e "${G}✓${X}"
        rm -f "$out_file"
        return 0
    fi
    log echo -e "${R}✗${X}"
    if [ -s "$out_file" ]; then
        log echo "[output capped at ${MAX_LOG_BYTES} bytes]"
        log cat "$out_file"
    fi
    rm -f "$out_file"
    [ "$UPDATE_BACKUP_STATUS" = "1" ] && write_status failed "Task failed: $label"
    mail "Task Failed: $label"
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
logfile /dev/stderr
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

log_dir_size() {
    local file size total=0
    for file in "$LOG_DIR"/*.log; do
        [ -e "$file" ] || continue
        size=$(wc -c < "$file" 2>/dev/null || echo 0)
        total=$((total + size))
    done
    echo "$total"
}

trim_log_dir() {
    local file total
    total=$(log_dir_size)
    [ "$total" -gt "$MAX_LOG_DIR_BYTES" ] || return 0
    while IFS= read -r file; do
        [ -e "$file" ] || continue
        [ "$file" = "$LOG" ] && continue
        rm -f "$file"
        total=$(log_dir_size)
        [ "$total" -le "$MAX_LOG_DIR_BYTES" ] && break
    done < <(ls -1tr "$LOG_DIR"/*.log 2>/dev/null)
}

cleanup_logs() {
    find "$LOG_DIR" -name "*.log" -type f -mmin +600 ! -path "$LOG" -delete
    for file in "$LOG_DIR"/*.log; do
        [ -e "$file" ] || continue
        cap_log_file "$file"
    done
    trim_log_dir
}

# Backup, check and prune
backup() {
    UPDATE_BACKUP_STATUS=1
    write_status running "Backup started"

    # Clock accuracy comes from the Fly.io host; Alpine provides no ntpdate binary

    # Skip instead of fighting over the repository when a manual run is already active
    exec 9>"$LOG_DIR/backup.lock"
    if ! flock -n 9; then
        log echo -e "${Y}Another backup is already running, skipping this run${X}"
        exit 3
    fi

    # Remove stale locks left behind by an interrupted run (active locks are kept)
    timeout -k 30 "$QUICK_TIMEOUT" restic unlock 2>/dev/null || true

    # Initialise only when the repository really is missing (restic exit code 10).
    # A wrong password (12) or an unreachable backend (1) must be reported as such,
    # otherwise "restic init" answers with a misleading "already initialized" error.
    timeout -k 30 "$QUICK_TIMEOUT" restic cat config >/dev/null 2>&1 && rc=0 || rc=$?
    case "$rc" in
        0)  ;;
        10) log echo -e "${Y}Repository not initialized, initializing...${X}"
            run "Repo init" "$QUICK_TIMEOUT" restic init ;;
        *)  run "Repository access" "$QUICK_TIMEOUT" restic cat config ;;
    esac

    # SQLite hot backup (ensures consistency)
    run "SQLite backup" "$QUICK_TIMEOUT" sqlite3 "$DATA/db.sqlite3" ".backup $DATA/backup.bak"
    run "SQLite check" "$QUICK_TIMEOUT" sqlite3 "$DATA/backup.bak" "PRAGMA integrity_check"

    # Core operations (exclude live db files, rebuildable cache, and local logs)
    local log_exclude=()
    case "$LOG_DIR" in
        "$DATA"/*) log_exclude=(--exclude="${LOG_DIR#"$DATA"/}") ;;
    esac
    run "Data backup" "$LONG_TIMEOUT" restic backup --verbose \
        --exclude='db.*' --exclude='icon_cache' --exclude='backup-status.txt' \
        "${log_exclude[@]}" "$DATA"
    run "Health check" "$LONG_TIMEOUT" restic check
    run "Snapshot prune" "$LONG_TIMEOUT" restic forget \
        --keep-hourly 24 --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --keep-yearly 3 --prune

    cleanup_logs

    LAST_SUCCESS="$(date -u +%s)"
    write_status ok "Backup complete"
    log echo -e "${G}Backup process complete ✨${X}"
    heartbeat ok
}

# Restore data from snapshot
restore() {
    [ -z "${1:-}" ] && { echo "Usage: $0 restore <snapshot-id>"; exit 1; }
    run "Restore snapshot $1" "$LONG_TIMEOUT" restic restore "$1" --target /
}

# Restore a snapshot into a temporary directory and validate the important files
restore_test() {
    local snapshot="${1:-latest}" target
    target="$(mktemp -d /tmp/restic-restore.XXXXXX)"
    trap 'rm -rf "$target"' EXIT
    run "Restore drill" "$LONG_TIMEOUT" restic restore "$snapshot" --target "$target"
    if [ ! -f "$target/data/backup.bak" ] || [ ! -f "$target/data/rsa_key.pem" ]; then
        log echo -e "${R}Restore drill is missing expected files${X}"
        exit 2
    fi
    run "Restore SQLite check" "$QUICK_TIMEOUT" sqlite3 "$target/data/backup.bak" "PRAGMA integrity_check"
    log echo -e "${G}Restore drill complete${X}"
    heartbeat ok
}

# Read back a slice of the stored data to prove the repository is really readable
verify() {
    run "Repository data verification" "$LONG_TIMEOUT" restic check --read-data-subset="${VERIFY_SUBSET:-10%}"
    heartbeat ok
}

# ── Entry Point ───────────────────────────────────────────────────────────────

cleanup_logs

if [ -z "${RESTIC_PASSWORD:-}" ]; then
    if [ "${1:-}" = "backup" ]; then
        UPDATE_BACKUP_STATUS=1
        write_status failed "RESTIC_PASSWORD not set"
    fi
    echo "Error: RESTIC_PASSWORD not set"
    heartbeat fail
    exit 1
fi

initCfg

case "${1:-}" in
    backup)    backup ;;
    restore)   restore "${2:-}" ;;
    restore-test) restore_test "${2:-}" ;;
    snapshots) timeout -k 30 "$QUICK_TIMEOUT" restic snapshots ;;
    verify)    verify ;;
    test)      echo "Test email from $APP_NAME backup system." | timeout 45 mail -s "[$APP_NAME] Test Mail" "$SMTP_TO" && echo "Test mail sent to $SMTP_TO" ;;
    *)         echo "Usage: $0 {backup|restore <id>|restore-test [id]|snapshots|verify|test}"; exit 1 ;;
esac
