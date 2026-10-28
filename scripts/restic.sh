#!/bin/bash

set -uo pipefail

COMMAND="${1:-}"
if [ "$(id -u)" = 0 ] && command -v su-exec >/dev/null 2>&1; then
    exec su-exec vaultwarden:vaultwarden "$0" "$@"
fi

umask 077
APP_NAME="${FLY_APP_NAME:-Vaultwarden}"
DATA=/data
LOG_DIR="${RESTIC_LOG_DIR:-/data/restic-logs}"
LOG="$LOG_DIR/$(date +%Y%m%d_%H%M%S).log"
STATUS_FILE=/data/backup-status.txt
MAX_STATUS_BYTES=4096
MAX_LOG_BYTES="${RESTIC_LOG_MAX_BYTES:-262144}"
MAX_LOG_DIR_BYTES="${RESTIC_LOG_DIR_MAX_BYTES:-10485760}"
QUICK_TIMEOUT="${RESTIC_QUICK_TIMEOUT:-60}"
LONG_TIMEOUT="${RESTIC_LONG_TIMEOUT:-1800}"
LIMIT_LOG_BYTES=8388608
LIMIT_LOG_DIR_BYTES=67108864
LIMIT_QUICK_TIMEOUT=3600
LIMIT_LONG_TIMEOUT=86400
LIMIT_BACKUP_AGE=31536000
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_OK='^[[:space:]]*\{[[:space:]]*"ok"[[:space:]]*:[[:space:]]*true([[:space:]]*,|[[:space:]]*\})'
# shellcheck disable=SC2016
SQLITE_OK='
NR == 1 && $0 == "ok" { valid = 1; next }
{ print; invalid = 1 }
END {
    if (NR == 0) print "PRAGMA integrity_check returned no result"
    if (NR != 1 || !valid || invalid) exit 1
}
'

is_regular_file() { [ ! -L "$1" ] && [ -f "$1" ]; }

read_status_body() {
    local body LC_ALL=C
    is_regular_file "$STATUS_FILE" || return 4
    body="$( { head -c "$((MAX_STATUS_BYTES + 1))" "$STATUS_FILE" 2>/dev/null && printf '\001'; } )" || return 1
    body="${body%$'\001'}"
    [ "${#body}" -le "$MAX_STATUS_BYTES" ] || return 3
    printf '%s' "$body"
}

STATUS_STATE=""
STATUS_MARKER_ERROR=""
LAST_SUCCESS=0
if [ -e "$STATUS_FILE" ]; then
    if body="$(read_status_body)"; then
        STATUS_STATE="$(printf '%s\n' "$body" | sed -n 's/^state=//p' | head -n 1)"
        LAST_SUCCESS="$(printf '%s\n' "$body" | sed -n 's/^last_success=//p' | head -n 1)"
        if [ -z "$LAST_SUCCESS" ]; then
            STATUS_MARKER_ERROR=missing
        elif [[ ! "$LAST_SUCCESS" =~ ^[0-9]+$ ]] || [ "${#LAST_SUCCESS}" -gt 18 ]; then
            STATUS_MARKER_ERROR=invalid
            LAST_SUCCESS=0
        else
            LAST_SUCCESS=$((10#$LAST_SUCCESS))
        fi
    else
        case "$?" in
            3) STATUS_MARKER_ERROR=oversized ;;
            4) STATUS_MARKER_ERROR=not_regular ;;
            *) STATUS_MARKER_ERROR=unreadable ;;
        esac
    fi
fi
CURRENT_STEP=""

SENSITIVE_VALUES=()
while IFS= read -r -d '' record; do
    case "$record" in *=*) ;; *) continue ;; esac
    name="${record%%=*}"
    value="${record#*=}"
    case "$name" in
        *_PASSWORD|*_TOKEN|*_SECRET|*_PRIVATE_KEY|*_API_KEY|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|RESTIC_REPOSITORY|SMTP_HOST|SMTP_USERNAME|SMTP_FROM|SMTP_TO|ORG_CREATION_USERS|TELEGRAM_CHAT_ID|HEALTHCHECK_URL|CADDY_DOMAINS|DOMAIN|FLY_APP_NAME)
            [ -n "$value" ] && SENSITIVE_VALUES+=("$value")
            ;;
    esac
done < <(env -0)

redact() {
    local body="$1" value
    for value in "${SENSITIVE_VALUES[@]}"; do body="${body//"$value"/<redacted>}"; done
    printf '%s' "$body" | sed -E '/^[[:space:]]*[0-9a-fA-F]{8}[[:space:]]/ s/([[:space:]])[0-9a-fA-F]{12,}([[:space:]]|$)/\1[redacted-fly-machine-host]\2/g'
}

log() {
    local body redacted
    body="$("$@" 2>&1)"
    redacted="$(redact "$body")"
    [ -z "$redacted" ] || printf '%s\n' "$redacted" | tee -a "$LOG"
}

write_status() {
    local state="$1" message="${2:-}" body tmp="${STATUS_FILE}.tmp.$$"
    printf -v body 'state=%s\nupdated_at=%s\nlast_success=%s\nmessage=%s\n' "$state" "$(date -u +%s)" "$LAST_SUCCESS" "$message"
    if ! [ -d "$STATUS_FILE" ] && printf '%s' "$body" > "$tmp" && mv "$tmp" "$STATUS_FILE"; then
        return 0
    fi
    rm -f "$tmp" || echo "Warning: cannot remove ${tmp}" >&2
    if printf '%s' "$body" > "$STATUS_FILE"; then return 0; fi
    echo "Error: cannot write ${STATUS_FILE}; backup state was not recorded" >&2
    return 1
}

write_guard_status() {
    local state="$1" message="$2" current="" body
    if body="$(read_status_body)"; then
        current="$(printf '%s\n' "$body" | sed -n 's/^state=//p' | head -n 1)"
    fi
    if [ "$current" = running ]; then
        write_status running "${message} (backup in flight)"
    else
        write_status "$state" "$message"
    fi
}

heartbeat() {
    [ -z "${HEALTHCHECK_URL:-}" ] && return 0
    local suffix=""
    [ "${1:-ok}" = fail ] && suffix=/fail
    curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}${suffix}" >/dev/null 2>&1 || log echo "Heartbeat ping failed"
}

die() { log echo "$1"; exit 2; }
alert_failure() { send_telegram "$1" || :; heartbeat fail; exit 2; }

guard_failure() {
    local state_message="$1" alert="$2" preserve="${3:-true}"
    if [ "$preserve" = true ]; then write_guard_status failed "$state_message" || :; else write_status failed "$state_message" || :; fi
    alert_failure "$alert"
}

require_bounded_int() {
    local name="$1" value="${2:-}" maximum="$3"
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]] || [ "${#value}" -gt "${#maximum}" ] \
        || { [ "${#value}" -eq "${#maximum}" ] && [ "$value" -gt "$maximum" ]; }; then
        echo "Error: ${name} must be between 1 and ${maximum}, got '${value}'" >&2
        exit 2
    fi
}

stop_process_group() {
    local pid="$1" attempt=0
    kill -TERM -"$pid" 2>/dev/null || return 0
    while kill -0 -"$pid" 2>/dev/null; do
        if [ "$attempt" -ge 10 ]; then kill -KILL -"$pid" 2>/dev/null || :; break; fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
}

timed() {
    local seconds="$1" pid rc
    shift
    (
        exec 9>&-
        setsid timeout -k 30 "$seconds" "$@" & pid=$!
        wait "$pid"; rc=$?
        stop_process_group "$pid"
        exit "$rc"
    )
}

clear_stale_locks() { run "Clear stale repository locks" "$QUICK_TIMEOUT" restic unlock; }

backup_is_running() {
    is_regular_file "$LOG_DIR/backup.lock" || return 2
    exec 8<"$LOG_DIR/backup.lock" 2>/dev/null || return 2
    if flock -n 8; then exec 8>&-; return 1; fi
    exec 8>&-
    return 0
}

send_mail() {
    [ -z "${SMTP_TO:-}" ] && return 0
    local out rc
    out="$(set -o pipefail; timeout 45 mail -a "Content-Type: text/plain; charset=UTF-8" -s "[$APP_NAME] $1" "$SMTP_TO" < "$LOG" 2>&1 | tail -c "$MAX_LOG_BYTES")"
    rc=$?
    if [ "$rc" -eq 0 ]; then log echo "Alert email sent"; return 0; fi
    log echo "Alert email failed (exit ${rc})"; [ -z "$out" ] || log redact "$out"
    return 1
}

send_telegram() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 0
    local text="$1" out rc status body
    out="$({
        curl -sS -m 10 --retry 2 -w '\nHTTP_STATUS=%{http_code}' --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=[$APP_NAME] ${text}" --data-urlencode disable_web_page_preview=true \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" 2>&1
        printf '\nCURL_RC=%s\n' "$?"
    } | tail -c "$MAX_LOG_BYTES")"
    rc="${out##*CURL_RC=}"; rc="${rc%%$'\n'*}"; out="${out%$'\n'CURL_RC=*}"; out="${out%$'\n'}"
    status="$(printf '%s\n' "$out" | sed -n 's/^HTTP_STATUS=//p' | tail -n 1)"
    body="$(printf '%s\n' "$out" | sed '/^HTTP_STATUS=/d')"
    body="${body//"$TELEGRAM_BOT_TOKEN"/<redacted>}"
    [ -z "$TELEGRAM_CHAT_ID" ] || body="${body//"$TELEGRAM_CHAT_ID"/<redacted>}"
    if [ "$rc" -eq 0 ] && [ "$status" = 200 ] && [[ "$body" =~ $TELEGRAM_OK ]]; then log echo "Telegram notification sent"; return 0; fi
    if [ "$rc" -ne 0 ]; then log echo "Telegram notification failed (curl exit ${rc})"
    elif [[ "$status" =~ ^[0-9]+$ ]] && [ "$status" != 000 ]; then log echo "Telegram notification failed (HTTP ${status})"
    else log echo "Telegram notification failed (no HTTP response)"; fi
    [ -z "$body" ] || log printf '%s\n' "$body"
    return 1
}

notify_rare() { local a=0 b=0; send_mail "$1" || a=$?; send_telegram "$1" || b=$?; [ "$a" -eq 0 ] && [ "$b" -eq 0 ]; }

notify_test() {
    local failed=""
    [ -n "${SMTP_TO:-}" ] || failed="SMTP_TO is not configured"
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        failed="${failed:+${failed}; }TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must both be configured"
    fi
    [ -z "$failed" ] || { log echo "Notification test cannot run: ${failed}"; return 2; }
    if notify_rare "Notification test"; then log echo "Notification test passed"; return 0; fi
    log echo "Notification test failed"
    return 1
}

check_audit_trail() {
    ( : >> "$LOG" ) 2>/dev/null || echo "Warning: cannot write ${LOG}; this run leaves no persistent log" >&2
    if ! is_regular_file "$STATUS_FILE"; then
        echo "Warning: ${STATUS_FILE} is not a regular file; backup state will not be recorded" >&2
    elif ! ( : >> "$STATUS_FILE" ) 2>/dev/null; then
        echo "Warning: cannot write ${STATUS_FILE}; backup state will not be recorded" >&2
    fi
}

RESTORE_TMP_DIR=""
RESTORE_BOOT_LOG=""
RESTORE_BOOT_PIPE=""
RESTORE_BOOT_READER=""

finish_restore_boot_log() {
    local attempt=0
    [ -n "$RESTORE_BOOT_READER" ] || return 0
    while kill -0 "$RESTORE_BOOT_READER" 2>/dev/null; do
        if [ "$attempt" -ge 50 ]; then kill "$RESTORE_BOOT_READER" 2>/dev/null || :; break; fi
        sleep 0.1; attempt=$((attempt + 1))
    done
    wait "$RESTORE_BOOT_READER" 2>/dev/null || :
    RESTORE_BOOT_READER=""
}

cleanup_restore_tmp() {
    finish_restore_boot_log
    [ -z "$RESTORE_TMP_DIR" ] || rm -rf "$RESTORE_TMP_DIR"
    [ -z "$RESTORE_BOOT_LOG" ] || rm -f "$RESTORE_BOOT_LOG"
    RESTORE_TMP_DIR="" RESTORE_BOOT_LOG="" RESTORE_BOOT_PIPE="" RESTORE_BOOT_READER=""
}

allocate_restore_workspace() {
    local parent="${TMPDIR:-/tmp}"
    [ -n "$parent" ] && [ -d "$parent" ] || parent=/tmp
    RESTORE_TMP_DIR="$(mktemp -d "$parent/restic-restore.XXXXXX")" || die "Unable to create restore scratch directory"
    RESTORE_BOOT_LOG="$(mktemp "$parent/restic-boot.XXXXXX")" || die "Unable to create restore scratch file"
    RESTORE_BOOT_PIPE="$RESTORE_TMP_DIR/restore-boot.fifo"
    mkfifo "$RESTORE_BOOT_PIPE" || die "Unable to create restore boot-log pipe"
    tail -c "$MAX_LOG_BYTES" < "$RESTORE_BOOT_PIPE" > "$RESTORE_BOOT_LOG" & RESTORE_BOOT_READER=$!
}

require_restore_space() {
    local snapshot="$1" parent="${TMPDIR:-/tmp}" stats needed free
    [ -n "$parent" ] && [ -d "$parent" ] || parent=/tmp
    clear_stale_locks
    if ! stats="$(timed "$QUICK_TIMEOUT" restic stats --json -- "$snapshot" 2>&1 | tail -c "$MAX_LOG_BYTES")"; then
        log echo "Unable to size snapshot ${snapshot}"; [ -z "$stats" ] || log redact "$stats"; exit 2
    fi
    needed="$(printf '%s\n' "$stats" | sed -n 's/.*"total_size": *\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    if [[ ! "$needed" =~ ^(0|[1-9][0-9]*)$ ]] || [ "${#needed}" -gt 16 ]; then
        log echo "Unable to size snapshot ${snapshot}"; [ -z "$stats" ] || log redact "$stats"; exit 2
    fi
    if ! free="$(df -Pk "$parent" | awk 'NR == 2 {print $4}')" || [[ ! "$free" =~ ^[0-9]{1,15}$ ]]; then
        die "Unable to read free space for the restore drill"
    fi
    free=$((free * 1024)); needed=$((needed + needed / 5 + 67108864))
    if [ "$free" -lt "$needed" ]; then log echo "Not enough free space for the restore drill"; log echo "available=${free} required=${needed}"; exit 2; fi
}

run_command() {
    local show_success="$1" label="$2" timeout_seconds="$3" out_file rc
    shift 3
    CURRENT_STEP="$label"
    out_file="$(mktemp "${TMPDIR:-/tmp}/restic-run.XXXXXX")" || die "Unable to create temporary output file"
    printf '%s ' "$(redact "$label")" | tee -a "$LOG"
    ( exec 9>&-; set -o pipefail; timed "$timeout_seconds" "$@" 2>&1 | tail -c "$MAX_LOG_BYTES" > "$out_file" ) || rc=$?
    if [ "${rc:-0}" -eq 0 ]; then
        log echo OK
        [ "$show_success" != true ] || [ ! -s "$out_file" ] || log cat "$out_file"
        rm -f "$out_file" || log echo "Warning: cannot remove temporary command output"
        return 0
    fi
    log echo FAIL
    [ ! -s "$out_file" ] || { log echo "[output capped at ${MAX_LOG_BYTES} bytes]"; log redact "$(< "$out_file")"; }
    rm -f "$out_file" || log echo "Warning: cannot remove temporary command output"
    exit 2
}

run() { run_command false "$@"; }

sqlite_integrity_check() {
    # shellcheck disable=SC2016
    run "$1" "$QUICK_TIMEOUT" bash -c 'set -o pipefail; sqlite3 "$1" "PRAGMA integrity_check" | awk "$2"' sqlite "$2" "$SQLITE_OK"
}

log_dir_size() {
    local sizes
    sizes="$(find "$LOG_DIR" -maxdepth 1 -type f ! -name backup.lock -exec stat -c '%s' {} + 2>/dev/null)" || return 1
    printf '%s\n' "$sizes" | awk '{total += $1} END {print total + 0}'
}

trim_logs() {
    local file size tmp total oldest failed=0
    find "$LOG_DIR" -maxdepth 1 -type f \( -name '*.log' -o -name '*.log.tmp.*' \) -mmin +600 ! -path "$LOG" -delete \
        || { echo "Warning: could not remove expired logs from ${LOG_DIR}" >&2; failed=1; }
    for file in "$LOG_DIR"/*.log; do
        [ -f "$file" ] || continue
        if ! size="$(wc -c < "$file")"; then echo "Warning: cannot enforce the per-file log cap for ${file}" >&2; failed=1; continue; fi
        if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
            tmp="${file}.tmp.$$"
            if tail -c "$MAX_LOG_BYTES" "$file" > "$tmp" && mv "$tmp" "$file"; then :
            else echo "Warning: cannot enforce the per-file log cap for ${file}" >&2; rm -f "$tmp"; failed=1; fi
        fi
    done
    if ! total="$(log_dir_size)"; then echo "Warning: cannot read ${LOG_DIR}; the log directory cap was not checked" >&2; return 1; fi
    while [ "$total" -gt "$MAX_LOG_DIR_BYTES" ]; do
        oldest="$(find "$LOG_DIR" -maxdepth 1 -type f \( -name '*.log' -o -name '*.log.tmp.*' \) ! -path "$LOG" -exec stat -c '%Y %n' {} + 2>/dev/null | sort -n | head -n 1 | cut -d' ' -f2-)"
        if [ -z "$oldest" ] || ! rm -f "$oldest" || ! total="$(log_dir_size)"; then
            echo "Warning: cannot trim ${LOG_DIR} to its byte cap" >&2; failed=1; break
        fi
    done
    if [ "$total" -gt "$MAX_LOG_DIR_BYTES" ]; then echo "Warning: log directory holds ${total} bytes, above the ${MAX_LOG_DIR_BYTES} byte cap and could not be trimmed" >&2; return 1; fi
    if [ "$failed" -ne 0 ]; then echo "Warning: log maintenance could not enforce every retention or file-size limit in ${LOG_DIR}" >&2; return 1; fi
}

backup() {
    trap 'rc=$?; if [ "${rc:-0}" -ne 0 ] && [ "${rc:-0}" -ne 3 ]; then write_status failed "Task failed: ${CURRENT_STEP:-backup} (exit ${rc})" || :; send_telegram "Task Failed: ${CURRENT_STEP:-backup}" || :; heartbeat fail; fi' EXIT
    if ! exec 9>"$LOG_DIR/backup.lock"; then echo "Cannot create ${LOG_DIR}/backup.lock" >&2; CURRENT_STEP="Cannot create backup lock"; exit 2; fi
    if ! flock -n 9; then log echo "Another backup is already running, skipping this run"; exit 3; fi
    if ! write_status running "Backup started"; then echo "Cannot record backup start state" >&2; CURRENT_STEP="Cannot record backup start state"; exit 2; fi
    timed "$QUICK_TIMEOUT" restic cat config >/dev/null 2>&1 && rc=0 || rc=$?
    case "${rc:-1}" in
        0) ;;
        10) log echo "Repository not initialized, initializing..."; run "Repo init" "$QUICK_TIMEOUT" restic init ;;
        *) run "Repository access" "$QUICK_TIMEOUT" restic cat config ;;
    esac
    clear_stale_locks
    run "SQLite backup" "$QUICK_TIMEOUT" sqlite3 "$DATA/db.sqlite3" ".backup $DATA/backup.bak"
    sqlite_integrity_check "SQLite check" "$DATA/backup.bak"
    local excludes=(--exclude="$DATA/db.sqlite3" --exclude="$DATA/db.sqlite3-journal" --exclude="$DATA/db.sqlite3-shm" --exclude="$DATA/db.sqlite3-wal" --exclude="$DATA/icon_cache" --exclude="$DATA/backup-status.txt")
    case "$LOG_DIR" in "$DATA"/*) excludes+=(--exclude="$LOG_DIR") ;; esac
    run "Data backup" "$LONG_TIMEOUT" restic backup --verbose "${excludes[@]}" "$DATA"
    run "Health check" "$LONG_TIMEOUT" restic check
    run "Snapshot prune" "$LONG_TIMEOUT" restic forget --keep-hourly 24 --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --keep-yearly 3 --prune
    local warning=""
    trim_logs || warning=" (log trim failed)"
    LAST_SUCCESS="$(date -u +%s)"
    if ! write_status ok "Backup complete${warning}"; then echo "Cannot record backup completion state" >&2; CURRENT_STEP="Cannot record backup completion state"; exit 2; fi
    log echo "Backup process complete"
    if [ -n "$warning" ]; then heartbeat fail; send_telegram "Backup succeeded with warnings" || :; else heartbeat ok; fi
}

restore() {
    [ -n "${1:-}" ] || { echo "Usage: $0 restore <snapshot-id>"; exit 1; }
    [ "${RESTORE_CONFIRM:-}" = yes ] || { echo "Refusing to overwrite /data without RESTORE_CONFIRM=yes" >&2; echo "Run 'restore-test' to verify a snapshot first, or confirm the in-place restore on purpose." >&2; exit 2; }
    clear_stale_locks
    run "Restore snapshot $1" "$LONG_TIMEOUT" restic restore --target / -- "$1"
    log echo "The live db.* files are not in the snapshot; the consistent copy is /data/backup.bak."
    log echo "To finish: 'touch /data/restore-pending', then restart the machine; the entrypoint swaps backup.bak in before Vaultwarden starts."
}

restore_test() {
    local snapshot="${1:-latest}" target boot_log table
    trap 'rc=$?; cleanup_restore_tmp; if [ "${rc:-0}" -ne 0 ]; then write_guard_status failed "Restore drill failed (exit ${rc})" || :; notify_rare "Restore drill failed" || :; heartbeat fail; fi' EXIT
    allocate_restore_workspace
    target="$RESTORE_TMP_DIR" boot_log="$RESTORE_BOOT_LOG"
    require_restore_space "$snapshot"
    run "Restore drill" "$LONG_TIMEOUT" restic restore --target "$target" -- "$snapshot"
    if ! [ -f "$target/data/backup.bak" ] || ! [ -f "$target/data/rsa_key.pem" ]; then
        log echo "Restore drill is missing expected files"
        exit 2
    fi
    sqlite_integrity_check "Restore SQLite check" "$target/data/backup.bak"
    sqlite3 "$target/data/backup.bak" .tables 2>/dev/null | grep -q . || { log echo "Restored database has no tables"; exit 2; }
    cp "$target/data/backup.bak" "$target/data/db.sqlite3"
    for table in __diesel_schema_migrations users; do
        sqlite3 "$target/data/db.sqlite3" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${table}'" | grep -q 1 \
            || { log echo "The restored database is missing the ${table} table"; exit 2; }
    done
    sqlite3 "$target/data/db.sqlite3" "CREATE TABLE IF NOT EXISTS drill_sentinel(v TEXT); DELETE FROM drill_sentinel; INSERT INTO drill_sentinel VALUES('restore-drill');"
    printf '{"signups_allowed": false}\n' > "$target/restore-drill-config.json" || { log echo "Unable to write the restore drill config"; exit 2; }
    log echo "Restore cold boot"
    if (
        cd "$target"; boot_pid=""
        trap '[ -n "${boot_pid:-}" ] && kill "$boot_pid" 2>/dev/null || :' EXIT
        DATA_FOLDER="$target/data" WEB_VAULT_ENABLED=false ROCKET_ADDRESS=127.0.0.1 ROCKET_PORT=18081 CONFIG_FILE="$target/restore-drill-config.json" /vaultwarden > "$RESTORE_BOOT_PIPE" 2>&1 & boot_pid=$!
        boot_alive() { [ -r "/proc/$boot_pid/stat" ] && [ "$(awk '{print $3}' "/proc/$boot_pid/stat")" != Z ]; }
        boot_ok=0
        for _ in $(seq 1 60); do
            boot_alive || break
            if wget -qO- http://127.0.0.1:18081/alive >/dev/null 2>&1 && sleep 1 && boot_alive; then boot_ok=1; break; fi
            sleep 0.5
        done
        kill "$boot_pid" 2>/dev/null || :; wait "$boot_pid" 2>/dev/null || :; boot_pid=""
        [ "$boot_ok" = 1 ]
    ); then
        finish_restore_boot_log
        log echo OK
        [ "$(sqlite3 "$target/data/db.sqlite3" 'SELECT v FROM drill_sentinel' 2>/dev/null)" = restore-drill ] || { log echo "The cold boot did not keep the restored database"; exit 2; }
        log echo "The cold boot kept the restored database"
    else
        finish_restore_boot_log; log echo FAIL; log redact "$(< "$boot_log")"; exit 2
    fi
    log echo "Restore drill complete"
    heartbeat ok
}

verify() {
    trap 'rc=$?; if [ "${rc:-0}" -ne 0 ]; then write_guard_status failed "Repository verification failed (exit ${rc})" || :; notify_rare "Repository verification failed" || :; heartbeat fail; fi' EXIT
    clear_stale_locks
    run "Repository data verification" "$LONG_TIMEOUT" restic check --read-data-subset="${VERIFY_SUBSET:-10%}" --retry-lock="${VERIFY_RETRY_LOCK:-10m}"
    heartbeat ok
}

check_freshness() {
    local limit="${BACKUP_MAX_AGE:-7200}" now age uptime active=false
    now="$(date -u +%s)"
    if [ "$STATUS_STATE" = running ]; then
        backup_is_running
        case "$?" in
            0) active=true ;;
            1) log echo "The last backup started but never finished"; guard_failure "Backup did not finish" "Backup did not finish" false ;;
            2) log echo "Cannot inspect the backup lock; backup freshness is unknown"; guard_failure "Cannot inspect the backup lock" "Cannot inspect the backup lock" ;;
        esac
    fi
    case "$STATUS_MARKER_ERROR" in
        unreadable) log echo "Cannot read ${STATUS_FILE}; backup freshness is unknown"; alert_failure "Backup marker is unreadable" ;;
        missing) log echo "${STATUS_FILE} does not contain last_success"; alert_failure "Backup marker is missing last_success" ;;
        oversized) log echo "${STATUS_FILE} exceeds ${MAX_STATUS_BYTES} bytes; backup freshness is unknown"; alert_failure "Backup marker is oversized" ;;
        not_regular) log echo "${STATUS_FILE} is not a regular file; backup freshness is unknown"; alert_failure "Backup marker is not a regular file" ;;
        invalid) log echo "${STATUS_FILE} has an unusable last_success value"; guard_failure "last_success in ${STATUS_FILE} is not a number" "Backup marker is unusable" ;;
    esac
    case "$STATUS_STATE" in
        ok|running) ;;
        failed) log echo "${STATUS_FILE} records state=failed; the latest operation failed and last_success is not sufficient evidence"; alert_failure "Backup state is failed" ;;
        unknown) [ "$LAST_SUCCESS" = 0 ] || { log echo "${STATUS_FILE} has an unknown state but a recorded success"; alert_failure "Backup marker state is inconsistent"; } ;;
        *) log echo "${STATUS_FILE} has an unusable recorded state"; alert_failure "Backup marker state is unusable" ;;
    esac
    [ "$active" = false ] || { log echo "Backup is still running; skipping the last-success age check"; return 0; }
    if [ "$LAST_SUCCESS" = 0 ]; then
        uptime="$(cut -d. -f1 /proc/uptime 2>/dev/null)" || uptime=""
        case "$uptime" in ''|*[!0-9]*) log echo "Cannot determine the instance age"; guard_failure "Cannot determine the instance age" "Cannot determine the instance age" ;; esac
        [ "$uptime" -ge "$limit" ] || { log echo "No backup recorded yet and this instance is ${uptime}s old"; return 0; }
    fi
    age=$((now - LAST_SUCCESS))
    [ "$age" -ge 0 ] || { log echo "Last successful backup is stamped in the future (${age}s); the clock or ${STATUS_FILE} cannot be trusted"; guard_failure "last_success is in the future (${age}s)" "Backup marker is in the future"; }
    [ "$age" -gt "$limit" ] || { log echo "Last successful backup was ${age}s ago (limit ${limit}s)"; return 0; }
    log echo "Last successful backup was ${age}s ago (limit ${limit}s)"
    guard_failure "No successful backup for ${age}s" "Backup stale" false
}

check_disk() {
    local limit="${BACKUP_MAX_USAGE_PERCENT:-85}" used
    used="$(df -P "$DATA" 2>/dev/null | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
    case "$used" in ''|*[!0-9]*) log echo "Cannot read the usage of ${DATA}"; guard_failure "Cannot read the usage of ${DATA}" "Cannot read the usage of ${DATA}" ;; esac
    [ "$used" -lt "$limit" ] || { log echo "${DATA} is ${used}% full (limit ${limit}%)"; guard_failure "Data volume is ${used}% full" "Data volume is ${used}% full"; }
    log echo "${DATA} is ${used}% full (limit ${limit}%)"
}

require_bounded_int RESTIC_LOG_MAX_BYTES "$MAX_LOG_BYTES" "$LIMIT_LOG_BYTES"
require_bounded_int RESTIC_LOG_DIR_MAX_BYTES "$MAX_LOG_DIR_BYTES" "$LIMIT_LOG_DIR_BYTES"
require_bounded_int RESTIC_QUICK_TIMEOUT "$QUICK_TIMEOUT" "$LIMIT_QUICK_TIMEOUT"
require_bounded_int RESTIC_LONG_TIMEOUT "$LONG_TIMEOUT" "$LIMIT_LONG_TIMEOUT"
require_bounded_int BACKUP_MAX_AGE "${BACKUP_MAX_AGE:-7200}" "$LIMIT_BACKUP_AGE"
require_bounded_int BACKUP_MAX_USAGE_PERCENT "${BACKUP_MAX_USAGE_PERCENT:-85}" 100
[ "$MAX_LOG_BYTES" -le "$MAX_LOG_DIR_BYTES" ] || { echo "Error: RESTIC_LOG_MAX_BYTES must not exceed RESTIC_LOG_DIR_MAX_BYTES, got '${MAX_LOG_BYTES}' greater than '${MAX_LOG_DIR_BYTES}'" >&2; exit 2; }
if [ -n "$TELEGRAM_BOT_TOKEN" ] || [ -n "$TELEGRAM_CHAT_ID" ]; then
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "Error: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set together" >&2
        exit 2
    fi
    [[ "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { echo "Error: TELEGRAM_BOT_TOKEN has an invalid format" >&2; exit 2; }
    [[ "$TELEGRAM_CHAT_ID" =~ ^(@[A-Za-z0-9_]+|-?[0-9]+)$ ]] || { echo "Error: TELEGRAM_CHAT_ID has an invalid format" >&2; exit 2; }
fi

mkdir -p "$LOG_DIR" 2>/dev/null || :
trim_logs
check_audit_trail

if [ -z "${RESTIC_PASSWORD:-}" ]; then
    case "$COMMAND" in
        check-freshness|check-disk|notify-test|'') ;;
        backup) write_status failed "RESTIC_PASSWORD not set" || :; send_telegram "RESTIC_PASSWORD not set" || :; echo "Error: RESTIC_PASSWORD not set" >&2; heartbeat fail; exit 1 ;;
        restore|restore-test|snapshots|verify) echo "Error: RESTIC_PASSWORD not set" >&2; heartbeat fail; exit 1 ;;
    esac
fi

case "$COMMAND" in
    backup) backup ;;
    check-freshness) check_freshness ;;
    check-disk) check_disk ;;
    notify-test) notify_test ;;
    restore) restore "${2:-}" ;;
    restore-test) restore_test "${2:-}" ;;
    snapshots) clear_stale_locks; run_command true "Snapshot list" "$QUICK_TIMEOUT" restic snapshots ;;
    verify) verify ;;
    *) echo "Usage: $0 {backup|check-freshness|check-disk|notify-test|restore <id>|restore-test [id]|snapshots|verify}"; exit 1 ;;
esac
