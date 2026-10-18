#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ Restic Backup Script                                                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Usage: /restic.sh {backup|check-freshness|restore <id>|restore-test [id]|snapshots|verify}
#        `restore <id>` overwrites the live /data and needs RESTORE_CONFIRM=yes.

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

# Log an error and abort; used when the scratch files below cannot be created.
die() { log echo -e "${R}$1${X}"; exit 2; }

# Reject misconfigured limits instead of clearing every log file or timing out
# every restic command without saying why.
require_positive_int() {
    case "${2:-}" in
        ''|*[!0-9]*)
            echo "Error: $1 must be a positive integer, got '${2:-}'" >&2
            exit 2
            ;;
    esac
    [ "${2:-0}" -gt 0 ] || {
        echo "Error: $1 must be a positive integer, got '${2:-}'" >&2
        exit 2
    }
}

# Run a command without the backup lock. A child that outlives the run would
# keep the lock forever, and every later backup would exit 3 as a "concurrent
# run" - an exit that is deliberately not alerted.
no_lock() ( exec 9>&-; exec "$@" )

# Remove locks left behind by a run that was killed mid-flight. restic keeps
# locks whose process is still alive, so this cannot disturb a running backup,
# but without it one interrupted run makes verify/restore fail with "repository
# is already locked" until the next hourly backup happens to clear it.
clear_stale_locks() {
    no_lock timeout -k 30 "$QUICK_TIMEOUT" restic unlock >/dev/null 2>&1 || true
}

# Whether another run holds the backup lock, as three states:
#   0 a run holds it, 1 nobody holds it, 2 it cannot be inspected.
# A read-only open avoids creating the lock file, and "cannot inspect" must not
# be collapsed into "not running": that turns a live backup into a false alert.
backup_is_running() {
    exec 8<"$LOG_DIR/backup.lock" 2>/dev/null || return 2
    if flock -n 8; then
        exec 8>&-
        return 1
    fi
    exec 8>&-
    return 0
}

# Send email notification; the timeout keeps a stalled SMTP relay from blocking the run.
send_mail() {
    [ -z "${SMTP_TO:-}" ] && return
    # Strip ANSI colors and set UTF-8. The outcome is written to the log so
    # "the alert never arrived" can be diagnosed from the run itself instead of
    # from whatever the mailer happened to print on stderr.
    local out rc
    out="$(
        (
            exec 9>&-
            sed 's/\x1b\[[0-9;]*m//g' "$LOG" | timeout 45 mail \
                -a "Content-Type: text/plain; charset=UTF-8" \
                -s "[$APP_NAME] $1" "$SMTP_TO"
        ) 2>&1
    )"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        log echo -e "${G}Alert email sent to ${SMTP_TO}${X}"
        return 0
    fi
    log echo -e "${R}Alert email failed (exit ${rc})${X}"
    [ -n "$out" ] && log printf '%s\n' "$out"
    return 0
}

# Warn when the audit trail cannot be written: a run with no log file and no
# status file is invisible to whoever has to diagnose it later.
check_audit_trail() {
    if ! ( : >> "$LOG" ) 2>/dev/null; then
        echo "Warning: cannot write ${LOG}; this run leaves no persistent log" >&2
    fi
    if ! ( : >> "$STATUS_FILE" ) 2>/dev/null; then
        echo "Warning: cannot write ${STATUS_FILE}; backup state will not be recorded" >&2
    fi
}

# Restore-drill scratch paths. These are global on purpose: an EXIT trap runs
# after the function has returned, so a `local` would already be unset and the
# cleanup would silently delete nothing, leaving a full copy in /tmp.
RESTORE_TMP_DIR=""
RESTORE_BOOT_LOG=""

cleanup_restore_tmp() {
    [ -n "$RESTORE_TMP_DIR" ] && rm -rf "$RESTORE_TMP_DIR"
    [ -n "$RESTORE_BOOT_LOG" ] && rm -f "$RESTORE_BOOT_LOG"
    return 0
}

# Run command and log status
run() {
    local label="$1" timeout_seconds="$2" out_file raw_file rc
    shift 2
    CURRENT_STEP="$label"
    out_file="$(mktemp "${TMPDIR:-/tmp}/restic-run.XXXXXX")" \
        || die "Unable to create temporary output file"
    raw_file="$(mktemp "${TMPDIR:-/tmp}/restic-raw.XXXXXX")" \
        || { rm -f "$out_file"; die "Unable to create temporary output file"; }
    log echo -en "${B}${label}${X} "
    # Hard-cap raw command output on disk at 8x the retained log size, so a
    # runaway command cannot fill the volume before the tail truncation runs.
    local raw_limit_kb=$(( (MAX_LOG_BYTES * 8 + 1023) / 1024 ))
    rc=0
    (
        # Never hand the backup lock to a child: a helper that outlives this run
        # would keep the lock forever, and every later backup would exit 3 as a
        # "concurrent run" without alerting anyone.
        exec 9>&-
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

# The image ships BusyBox find, which supports no GNU printf-format predicate: a
# size or mtime query that relies on one fails silently and turns the directory
# cap into a no-op. stat -c is available in the same BusyBox.
log_dir_size() {
    find "$LOG_DIR" -name '*.log' -type f -exec stat -c '%s' {} + 2>/dev/null \
        | awk '{total += $1} END {print total + 0}' || echo 0
}

# Drop logs older than 10 hours, cap oversized files, then trim the directory.
# Returns non-zero when the directory is still above the cap: a silent no-op
# here lets the volume fill while every run keeps recording success.
trim_logs() {
    find "$LOG_DIR" -name '*.log' -type f -mmin +600 ! -path "$LOG" -delete 2>/dev/null || true
    local file size tmp total
    for file in "$LOG_DIR"/*.log; do
        [ -f "$file" ] || continue
        size=$(wc -c < "$file" 2>/dev/null || echo 0)
        if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
            tmp="${file}.tmp.$$"
            if tail -c "$MAX_LOG_BYTES" "$file" > "$tmp"; then
                mv "$tmp" "$file" || rm -f "$tmp"
            else
                rm -f "$tmp"
            fi
        fi
    done
    total="$(log_dir_size)"
    [ "$total" -le "$MAX_LOG_DIR_BYTES" ] && return 0
    while IFS= read -r file; do
        [ -e "$file" ] || continue
        [ "$file" = "$LOG" ] && continue
        size="$(stat -c '%s' "$file" 2>/dev/null || echo 0)"
        if rm -f "$file"; then
            total=$(( total - size ))
            [ "$total" -le "$MAX_LOG_DIR_BYTES" ] && return 0
        fi
    done < <(find "$LOG_DIR" -name '*.log' -type f -exec stat -c '%Y %n' {} + 2>/dev/null \
        | sort -n | cut -d' ' -f2-)
    echo "Warning: log directory holds ${total} bytes, above the ${MAX_LOG_DIR_BYTES} byte cap and could not be trimmed" >&2
    return 1
}

# Backup, check and prune
backup() {
    trap 'rc=$?; if [ "${rc:-0}" -ne 0 ] && [ "${rc:-0}" -ne 3 ]; then
        write_status failed "Task failed: ${CURRENT_STEP:-backup} (exit ${rc})"
        send_mail "Task Failed: ${CURRENT_STEP:-backup}"
        heartbeat fail
    fi' EXIT

    # Skip instead of fighting over the repository when a manual run is already active
    exec 9>"$LOG_DIR/backup.lock"
    if ! flock -n 9; then
        log echo -e "${Y}Another backup is already running, skipping this run${X}"
        exit 3
    fi

    # Only the run that owns the lock may publish "running": a skipped run that
    # wrote it first would erase the state the live run is maintaining.
    write_status running "Backup started"
    clear_stale_locks

    # Initialise only when the repository really is missing (restic exit code 10).
    # A wrong password (12) or an unreachable backend (1) must be reported as such,
    # otherwise "restic init" answers with a misleading "already initialized" error.
    no_lock timeout -k 30 "$QUICK_TIMEOUT" restic cat config >/dev/null 2>&1 && rc=0 || rc=$?
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

    local trim_message=""
    trim_logs || trim_message=" (log trim failed)"

    LAST_SUCCESS="$(date -u +%s)"
    write_status ok "Backup complete${trim_message}"
    log echo -e "${G}Backup process complete ✨${X}"
    if [ -n "$trim_message" ]; then
        heartbeat fail
    else
        heartbeat ok
    fi
}

# Restore data from snapshot
restore() {
    [ -z "${1:-}" ] && { echo "Usage: $0 restore <snapshot-id>"; exit 1; }
    # `restic restore --target /` writes straight over the live /data while
    # Vaultwarden holds db.sqlite3 open, so a single keystroke between `restore`
    # and `restore-test` can destroy the running instance. Keep the destructive
    # path behind an explicit confirmation instead of one typo away.
    if [ "${RESTORE_CONFIRM:-}" != "yes" ]; then
        echo "Refusing to overwrite /data without RESTORE_CONFIRM=yes" >&2
        echo "Run 'restore-test' to verify a snapshot first, or confirm the in-place restore on purpose." >&2
        exit 2
    fi
    clear_stale_locks
    run "Restore snapshot $1" "$LONG_TIMEOUT" restic restore "$1" --target /
    # The snapshot carries the database as the consistent hot copy, not as the
    # live db.* files, so the command above leaves the old database in place.
    # Say so, or the operator walks away from a half-restored instance whose
    # keys were rolled back while its data was not.
    log echo -e "${Y}The live db.* files are not in the snapshot; the consistent copy is /data/backup.bak.${X}"
    log echo "To finish: 'touch /data/restore-pending', then restart the machine; the entrypoint swaps backup.bak in before Vaultwarden starts."
}

# Restore a snapshot into a temporary directory and validate the important files
restore_test() {
    local snapshot="${1:-latest}" tmp_parent free_bytes needed_bytes table
    tmp_parent="${TMPDIR:-/tmp}"
    [ -n "$tmp_parent" ] && [ -d "$tmp_parent" ] || tmp_parent=/tmp
    RESTORE_TMP_DIR="$(mktemp -d "$tmp_parent/restic-restore.XXXXXX")"
    RESTORE_BOOT_LOG="$(mktemp "$tmp_parent/restic-boot.XXXXXX")"
    local target="$RESTORE_TMP_DIR" boot_log="$RESTORE_BOOT_LOG"
    trap cleanup_restore_tmp EXIT

    clear_stale_locks
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

    # The snapshot leaves the live db.* files out on purpose and carries the
    # consistent hot copy instead, so the drill has to put that copy where
    # Vaultwarden looks. Booting a data directory with no database proved
    # nothing: Vaultwarden creates a fresh one and answers /alive anyway.
    cp "$target/data/backup.bak" "$target/data/db.sqlite3"
    for table in __diesel_schema_migrations users; do
        if ! sqlite3 "$target/data/db.sqlite3" \
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${table}'" \
            | grep -q 1; then
            log echo -e "${R}The restored database is missing the ${table} table${X}"
            exit 2
        fi
    done
    # A marker in the restored file, so the boot below has to prove it opened
    # this database instead of quietly creating another one.
    sqlite3 "$target/data/db.sqlite3" \
        "CREATE TABLE IF NOT EXISTS drill_sentinel(v TEXT); DELETE FROM drill_sentinel; INSERT INTO drill_sentinel VALUES('restore-drill');"

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
        if [ "$(sqlite3 "$target/data/db.sqlite3" 'SELECT v FROM drill_sentinel' 2>/dev/null)" = "restore-drill" ]; then
            log echo -e "${G}The cold boot kept the restored database${X}"
        else
            log echo -e "${R}The cold boot did not keep the restored database${X}"
            exit 2
        fi
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
    clear_stale_locks
    # Wait for a running backup instead of failing: the monthly check used to
    # fire at the same minute as the hourly backup, and restic refuses to take
    # an exclusive lock without --retry-lock.
    run "Repository data verification" "$LONG_TIMEOUT" restic check \
        --read-data-subset="${VERIFY_SUBSET:-10%}" --retry-lock="${VERIFY_RETRY_LOCK:-10m}"
    heartbeat ok
}

# Alert when the newest successful backup is older than BACKUP_MAX_AGE. Email on
# failure already covers a backup that runs and breaks; this covers a backup that
# silently stops running while the scheduler is still alive. A scheduler that has
# stopped entirely still needs HEALTHCHECK_URL, which is an external service.
check_freshness() {
    local limit="${BACKUP_MAX_AGE:-7200}" now age uptime_s lock_state
    now="$(date -u +%s)"

    # A run that was killed mid-flight leaves the status at "running" forever.
    # Only report that when the lock is readable and free: an uninspectable lock
    # is unknown, and guessing "finished" would raise a false alert.
    if [ "$(sed -n 's/^state=//p' "$STATUS_FILE" 2>/dev/null | head -n 1)" = "running" ]; then
        backup_is_running
        lock_state=$?
        case "$lock_state" in
            0) ;;
            1) log echo -e "${R}The last backup started but never finished${X}"
               write_status failed "Backup did not finish"
               send_mail "Backup did not finish"
               heartbeat fail
               exit 2 ;;
            2) log echo -e "${Y}Cannot inspect the backup lock; leaving the running state untouched${X}" ;;
        esac
    fi

    if [ "$LAST_SUCCESS" = "0" ]; then
        # A fresh volume has no baseline yet, so only complain once the instance
        # has been up longer than the limit.
        uptime_s="$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
        if [ "${uptime_s:-0}" -lt "$limit" ]; then
            log echo -e "${Y}No backup recorded yet and this instance is ${uptime_s}s old${X}"
            return 0
        fi
    fi
    age=$((now - LAST_SUCCESS))
    if [ "$age" -le "$limit" ]; then
        log echo -e "${G}Last successful backup was ${age}s ago (limit ${limit}s)${X}"
        return 0
    fi
    log echo -e "${R}Last successful backup was ${age}s ago (limit ${limit}s)${X}"
    write_status failed "No successful backup for ${age}s"
    send_mail "Backup stale"
    heartbeat fail
    exit 2
}

# ── Entry Point ───────────────────────────────────────────────────────────────

require_positive_int RESTIC_LOG_MAX_BYTES "$MAX_LOG_BYTES"
require_positive_int RESTIC_LOG_DIR_MAX_BYTES "$MAX_LOG_DIR_BYTES"
require_positive_int RESTIC_QUICK_TIMEOUT "$QUICK_TIMEOUT"
require_positive_int RESTIC_LONG_TIMEOUT "$LONG_TIMEOUT"
require_positive_int BACKUP_MAX_AGE "${BACKUP_MAX_AGE:-7200}"

trim_logs
check_audit_trail

if [ -z "${RESTIC_PASSWORD:-}" ]; then
    [ "${1:-}" = "backup" ] && write_status failed "RESTIC_PASSWORD not set"
    echo "Error: RESTIC_PASSWORD not set"
    heartbeat fail
    exit 1
fi

case "${1:-}" in
    backup)          backup ;;
    check-freshness) check_freshness ;;
    restore)         restore "${2:-}" ;;
    restore-test)    restore_test "${2:-}" ;;
    snapshots)       clear_stale_locks; timeout -k 30 "$QUICK_TIMEOUT" restic snapshots ;;
    verify)          verify ;;
    *)               echo "Usage: $0 {backup|check-freshness|restore <id>|restore-test [id]|snapshots|verify}"; exit 1 ;;
esac
