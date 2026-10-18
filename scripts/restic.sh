#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Restic Backup Script                                                      ║
# ║ Usage: /restic.sh {backup|restore <id>|restore-test [id]|snapshots|verify} ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -uo pipefail

# Run as the unprivileged owner so files created here never become root-owned.
# `fly ssh console` starts as root; without this, cleans before forever.
if [ "$(id -u)" = "0" ] && command -v su-exec >/dev/null 2>&1; then
    exec su-exec vaultwarden:vaultwarden "$0" "$@"
fi

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
CURRENT_STEP=""
mkdir -p "$LOG_DIR" 2>/dev/null || true

# ANSI colors
R="\x1b[31;01m" G="\x1b[32;01m" Y="\x1b[33;01m" B="\x1b[34;01m" X="\x1b[0m"

# ── Utilities ─────────────────────────────────────────────────────────────────

# Log output to file and stdout
log() { "$@" 2>&1 | tee -a "$LOG"; }

# Persist a small freshness marker for local monitoring
write_status() {
    local state="$1" message="${2:-}" now tmp
    now="$(date -u +%s)"
    tmp="${STATUS_FILE}.tmp.$$"
    local body
    printf -v body 'state=%s\nupdated_at=%s\nlast_success=%s\nmessage=%s\n' \
        "$state" "$now" "$LAST_SUCCESS" "$message"
    # Atomic rename when the log volume is writable, in-place fallback otherwise
    printf '%s' "$body" > "$tmp" 2>/dev/null && mv "$tmp" "$STATUS_FILE" 2>/dev/null && return 0
    rm -f "$tmp"
    printf '%s' "$body" > "$STATUS_FILE" 2>/dev/null || true
}

# Optional dead-man's-switch ping (e.g. healthchecks.io). No-op when HEALTHCHECK_URL is unset.
heartbeat() {
    [ -z "${HEALTHCHECK_URL:-}" ] && return 0
    local suffix=""
    [ "${1:-ok}" = "fail" ] && suffix="/fail"
    curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}${suffix}" >/dev/null 2>&1 \
        || log echo -e "${Y}Heartbeat ping failed${X}"
}

# Send email notification; the timeout keeps a stalled SMTP relay from blocking the run.
send_mail() {
    [ -z "${SMTP_TO:-}" ] && return
    # Strip ANSI colors and set UTF-8
    sed 's/\x1b\[[0-9;]*m//g' "$LOG" | timeout 45 mail \
        -a "Content-Type: text/plain; charset=UTF-8" \
        -s "[$APP_NAME] $1" "$SMTP_TO"
}

# Run command and log status
run() {
    local label="$1" timeout_seconds="$2" out_file raw_file rc
    shift 2
    CURRENT_STEP="$label"
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
    rc=0
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
    exit 2
}

# ── Business Logic ────────────────────────────────────────────────────────────

log_dir_size() {
    find "$LOG_DIR" -name '*.log' -type f -printf '%s\n' 2>/dev/null \
        | awk '{total += $1} END {print total + 0}' || echo 0
}

# Drop logs older than 10 hours, cap oversized files, then trim the directory
trim_logs() {
    find "$LOG_DIR" -name '*.log' -type f -mmin +600 ! -path "$LOG" -delete
    local file size tmp
    for file in "$LOG_DIR"/*.log; do
        [ -f "$file" ] || continue
        size=$(wc -c < "$file" 2>/dev/null || echo 0)
        if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
            tmp="${file}.tmp.$$"
            if tail -c "$MAX_LOG_BYTES" "$file" > "$tmp"; then
                mv "$tmp" "$file"
            else
                rm -f "$tmp"
            fi
        fi
    done
    while IFS= read -r file; do
        [ -e "$file" ] || continue
        [ "$file" = "$LOG" ] && continue
        rm -f "$file"
        [ "$(log_dir_size)" -le "$MAX_LOG_DIR_BYTES" ] && break
    done < <(find "$LOG_DIR" -name '*.log' -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2-)
}

# Backup, check and prune
backup() {
    trap 'rc=$?; if [ "${rc:-0}" -ne 0 ] && [ "${rc:-0}" -ne 3 ]; then
        write_status failed "Task failed: ${CURRENT_STEP:-backup} (exit ${rc})"
        send_mail "Task Failed: ${CURRENT_STEP:-backup}"
        heartbeat fail
    fi' EXIT
    write_status running "Backup started"

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
    case "${rc:-1}" in
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

    trim_logs

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
    local snapshot="${1:-latest}" target tmp_parent free_bytes needed_bytes boot_log
    tmp_parent="${TMPDIR:-/tmp}"
    [ -n "$tmp_parent" ] && [ -d "$tmp_parent" ] || tmp_parent=/tmp
    target="$(mktemp -d "$tmp_parent/restic-restore.XXXXXX")"
    boot_log="$(mktemp "$tmp_parent/restic-boot.XXXXXX")"
    trap 'rm -rf "${target:-}" "${boot_log:-}"' EXIT

    needed_bytes="$(timeout -k 30 "$QUICK_TIMEOUT" restic stats --json "$snapshot" 2>/dev/null \
        | sed -n 's/.*"total_size": *\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    needed_bytes="${needed_bytes:-0}"
    free_bytes="$(df -Pk "$tmp_parent" | awk 'NR == 2 {print $4 * 1024}')"
    free_bytes="${free_bytes:-0}"
    needed_bytes=$((needed_bytes + needed_bytes / 5 + 67108864))
    if [ "$free_bytes" -lt "$needed_bytes" ]; then
        log echo -e "${R}Not enough free space for the restore drill${X}"
        log echo "available=${free_bytes} required=${needed_bytes}"
        exit 2
    fi

    run "Restore drill" "$LONG_TIMEOUT" restic restore "$snapshot" --target "$target"
    if [ ! -f "$target/data/backup.bak" ] || [ ! -f "$target/data/rsa_key.pem" ]; then
        log echo -e "${R}Restore drill is missing expected files${X}"
        exit 2
    fi
    run "Restore SQLite check" "$QUICK_TIMEOUT" sqlite3 "$target/data/backup.bak" "PRAGMA integrity_check"
    if ! sqlite3 "$target/data/backup.bak" ".tables" 2>/dev/null | grep -q .; then
        log echo -e "${R}Restored database has no tables${X}"
        exit 2
    fi

    log echo -e "${B}Restore cold boot${X} "
    if (
        cd "$target"
        DATA_FOLDER="$target/data" WEB_VAULT_ENABLED=false ROCKET_PORT=18081 \
            /vaultwarden > "$boot_log" 2>&1 &
        boot_pid=$!
        trap 'kill "${boot_pid:-0}" 2>/dev/null || true' EXIT
        boot_ok=0
        for _ in $(seq 1 60); do
            if wget -qO- http://127.0.0.1:18081/alive >/dev/null 2>&1; then
                boot_ok=1
                break
            fi
            sleep 0.5
        done
        kill "$boot_pid" 2>/dev/null || true
        wait "$boot_pid" 2>/dev/null || true
        [ "$boot_ok" = "1" ]
    ); then
        log echo -e "${G}✓${X}"
    else
        log echo -e "${R}✗${X}"
        log cat "$boot_log"
        exit 2
    fi
    log echo -e "${G}Restore drill complete${X}"
    heartbeat ok
}

# Read back a slice of the stored data to prove the repository is really readable
verify() {
    run "Repository data verification" "$LONG_TIMEOUT" restic check --read-data-subset="${VERIFY_SUBSET:-10%}"
    heartbeat ok
}

# ── Entry Point ───────────────────────────────────────────────────────────────

trim_logs

if [ -z "${RESTIC_PASSWORD:-}" ]; then
    [ "${1:-}" = "backup" ] && write_status failed "RESTIC_PASSWORD not set"
    echo "Error: RESTIC_PASSWORD not set"
    heartbeat fail
    exit 1
fi

case "${1:-}" in
    backup)    backup ;;
    restore)   restore "${2:-}" ;;
    restore-test) restore_test "${2:-}" ;;
    snapshots) timeout -k 30 "$QUICK_TIMEOUT" restic snapshots ;;
    verify)    verify ;;
    *)         echo "Usage: $0 {backup|restore <id>|restore-test [id]|snapshots|verify}"; exit 1 ;;
esac
