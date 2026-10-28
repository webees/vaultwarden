#!/bin/bash

set -uo pipefail

COMMAND="${1:-}"
READ_ONLY_AUDIT=false
if [ "$COMMAND" = "audit" ]; then
    READ_ONLY_AUDIT=true
fi

# `fly ssh console` starts as root; keep every artifact owned by the service.
if [ "$(id -u)" = "0" ] && command -v su-exec >/dev/null 2>&1; then
    exec su-exec vaultwarden:vaultwarden "$0" "$@"
fi

umask 077

APP_NAME="${FLY_APP_NAME:-Vaultwarden}"
DATA="/data"
LOG_DIR="${RESTIC_LOG_DIR:-/data/restic-logs}"
LOG="$LOG_DIR/$(date +%Y%m%d_%H%M%S).log"
MAX_LOG_BYTES="${RESTIC_LOG_MAX_BYTES:-262144}"
MAX_LOG_DIR_BYTES="${RESTIC_LOG_DIR_MAX_BYTES:-10485760}"
QUICK_TIMEOUT="${RESTIC_QUICK_TIMEOUT:-60}"
LONG_TIMEOUT="${RESTIC_LONG_TIMEOUT:-1800}"
# Keep operator-provided limits within ranges safe for shell arithmetic and disk use.
LIMIT_LOG_BYTES=8388608
LIMIT_LOG_DIR_BYTES=67108864
LIMIT_QUICK_TIMEOUT=3600
LIMIT_LONG_TIMEOUT=86400
LIMIT_BACKUP_AGE=31536000
NOTIFY_ON_SUCCESS="${BACKUP_NOTIFY_ON_SUCCESS:-false}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
# Require a top-level `"ok":true` response.
TELEGRAM_OK_PREFIX='^[[:space:]]*\{[[:space:]]*"ok"[[:space:]]*:[[:space:]]*true([[:space:]]*,|[[:space:]]*\})'
STATUS_FILE="/data/backup-status.txt"
MAX_STATUS_BYTES=4096
# SQLite can exit 0 while printing an integrity error; accept only exactly `ok`.
# shellcheck disable=SC2016  # AWK fields expand inside the child, not here.
SQLITE_INTEGRITY_AWK='
NR == 1 && $0 == "ok" { valid = 1; next }
{ print; invalid = 1 }
END {
    if (NR == 0) print "PRAGMA integrity_check returned no result"
    if (NR != 1 || !valid || invalid) exit 1
}
'

is_regular_file() {
    [ ! -L "$1" ] && [ -f "$1" ]
}

# Read one byte past the cap and reject the whole marker if it is oversized.
read_status_body() {
    local snapshot LC_ALL=C
    is_regular_file "$STATUS_FILE" || return 4
    snapshot="$( { head -c "$((MAX_STATUS_BYTES + 1))" "$STATUS_FILE" 2>/dev/null \
        && printf '\001'; } )" || return 1
    snapshot="${snapshot%$'\001'}"
    [ "${#snapshot}" -le "$MAX_STATUS_BYTES" ] || return 3
    printf '%s' "$snapshot"
}

# Preserve marker read failures instead of treating every one as a fresh volume.
STATUS_STATE=""
STATUS_MARKER_ERROR=""
LAST_SUCCESS=0
if [ -e "$STATUS_FILE" ]; then
    if status_body="$(read_status_body)"; then
        STATUS_STATE="$(printf '%s\n' "$status_body" | sed -n 's/^state=//p' | head -n 1)"
        LAST_SUCCESS="$(printf '%s\n' "$status_body" | sed -n 's/^last_success=//p' | head -n 1)"
        case "${LAST_SUCCESS:-}" in
            '') STATUS_MARKER_ERROR=missing; LAST_SUCCESS=0 ;;
            *[!0-9]*) STATUS_MARKER_ERROR=invalid; LAST_SUCCESS=0 ;;
            *)
                # Reject overflow; force decimal parsing for leading zeroes.
                if [ "${#LAST_SUCCESS}" -gt 18 ]; then
                    STATUS_MARKER_ERROR=invalid
                    LAST_SUCCESS=0
                else
                    LAST_SUCCESS=$((10#$LAST_SUCCESS))
                fi
                ;;
        esac
    else
        read_rc=$?
        case "$read_rc" in
            3) STATUS_MARKER_ERROR=oversized ;;
            4) STATUS_MARKER_ERROR=not_regular ;;
            *) STATUS_MARKER_ERROR=unreadable ;;
        esac
    fi
fi
CURRENT_STEP=""

# Redact credentials and private infrastructure values from persistent output.
SENSITIVE_VALUES=()
add_sensitive_value() {
    local value="${1:-}" existing
    [ -n "$value" ] || return 0
    if [ "${#SENSITIVE_VALUES[@]}" -gt 0 ]; then
        for existing in "${SENSITIVE_VALUES[@]}"; do
            [ "$existing" = "$value" ] && return 0
        done
    fi
    SENSITIVE_VALUES+=("$value")
}
# NUL delimiting preserves newlines inside a configured value.
while IFS= read -r -d '' record; do
    case "$record" in
        *=*) ;;
        *) continue ;;
    esac
    name="${record%%=*}"
    value="${record#*=}"
    case "$name" in
        *_PASSWORD|*_TOKEN|*_SECRET|*_PRIVATE_KEY|*_API_KEY|\
        AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|\
        RESTIC_REPOSITORY|SMTP_HOST|SMTP_USERNAME|SMTP_FROM|SMTP_TO|\
        ORG_CREATION_USERS|TELEGRAM_CHAT_ID|HEALTHCHECK_URL|CADDY_DOMAINS|\
        DOMAIN|FLY_APP_NAME)
            add_sensitive_value "$value"
            ;;
    esac
done < <(env -0)

R="\x1b[31;01m" G="\x1b[32;01m" Y="\x1b[33;01m" B="\x1b[34;01m" X="\x1b[0m"

redact_raw() {
    local body="$1" value
    if [ "${#SENSITIVE_VALUES[@]}" -gt 0 ]; then
        for value in "${SENSITIVE_VALUES[@]}"; do
            body="${body//"$value"/<redacted>}"
        done
    fi
    # Keep eight-character snapshot IDs; hide longer Fly machine host IDs.
    printf '%s' "$body" | sed -E \
        '/^[[:space:]]*[0-9a-fA-F]{8}[[:space:]]/ s/([[:space:]])[0-9a-fA-F]{12,}([[:space:]]|$)/\1[redacted-fly-machine-host]\2/g'
}

redact_file() {
    local body
    body="$(cat "$1")" || return 2
    redact_raw "$body"
}

log() {
    local body redacted
    body="$("$@" 2>&1)"
    redacted="$(redact_raw "$body")"
    if [ -n "$redacted" ]; then
        if [ "$READ_ONLY_AUDIT" = true ]; then
            printf '%s\n' "$redacted"
        else
            printf '%s\n' "$redacted" | tee -a "$LOG"
        fi
    fi
    return 0
}

log_result() {
    local status="${1:-0}"
    shift
    log "$@"
    return "$status"
}

write_status() {
    local state="$1" message="${2:-}" now tmp
    now="$(date -u +%s)"
    tmp="${STATUS_FILE}.tmp.$$"
    local body
    printf -v body 'state=%s\nupdated_at=%s\nlast_success=%s\nmessage=%s\n' \
        "$state" "$now" "$LAST_SUCCESS" "$message"
    # Prefer an atomic rename and fall back only when the path cannot be replaced.
    if ! [ -d "$STATUS_FILE" ] \
        && printf '%s' "$body" > "$tmp" \
        && mv "$tmp" "$STATUS_FILE"; then
        return 0
    fi
    rm -f "$tmp" || echo "Warning: cannot remove ${tmp}" >&2
    if printf '%s' "$body" > "$STATUS_FILE"; then
        return 0
    fi
    echo "Error: cannot write ${STATUS_FILE}; backup state was not recorded" >&2
    return 1
}

# Guards must not erase an in-flight backup marker.
write_guard_status() {
    local state="$1" message="$2" current current_body
    current=""
    if current_body="$(read_status_body)"; then
        current="$(printf '%s\n' "$current_body" | sed -n 's/^state=//p' | head -n 1)"
    fi
    if [ "$current" = "running" ]; then
        write_status running "${message} (backup in flight)"
    else
        write_status "$state" "$message"
    fi
}

heartbeat() {
    [ -z "${HEALTHCHECK_URL:-}" ] && return 0
    local suffix=""
    [ "${1:-ok}" = "fail" ] && suffix="/fail"
    curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}${suffix}" >/dev/null 2>&1 \
        || log echo -e "${Y}Heartbeat ping failed${X}"
}

die() { log echo -e "${R}$1${X}"; exit 2; }

# Accept only canonical bounded decimal integers.
require_bounded_int() {
    local name="$1" value="${2:-}" maximum="$3"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        echo "Error: ${name} must be between 1 and ${maximum}, got '${value}'" >&2
        exit 2
    }
    if [ "${#value}" -gt "${#maximum}" ] \
        || { [ "${#value}" -eq "${#maximum}" ] && [ "$value" -gt "$maximum" ]; }; then
        echo "Error: ${name} must be between 1 and ${maximum}, got '${value}'" >&2
        exit 2
    fi
}

# BusyBox timeout kills only the direct child. Run each tree in its own session,
# close the inherited backup lock, and kill the whole group afterwards.
stop_process_group() {
    local pid="$1" attempt=0
    kill -TERM -"$pid" 2>/dev/null || return 0
    while kill -0 -"$pid" 2>/dev/null; do
        if [ "$attempt" -ge 10 ]; then
            # Allow one second for cleanup before escalating to SIGKILL.
            kill -KILL -"$pid" 2>/dev/null || :
            break
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    return 0
}

timed() {
    local seconds="$1"
    shift
    (
        exec 9>&-
        setsid timeout -k 30 "$seconds" "$@" &
        timed_pid=$!
        wait "$timed_pid"
        timed_rc=$?
        stop_process_group "$timed_pid"
        exit "$timed_rc"
    )
}

clear_stale_locks() {
    run "Clear stale repository locks" "$QUICK_TIMEOUT" restic unlock
}

# 0=held, 1=free, 2=uninspectable. Do not conflate the last two states.
backup_is_running() {
    is_regular_file "$LOG_DIR/backup.lock" || return 2
    exec 8<"$LOG_DIR/backup.lock" 2>/dev/null || return 2
    if flock -n 8; then
        exec 8>&-
        return 1
    fi
    exec 8>&-
    return 0
}

send_mail() {
    [ -z "${SMTP_TO:-}" ] && return 0
    local out_file rc
    out_file="$(mktemp "${TMPDIR:-/tmp}/restic-mail.XXXXXX")"
    if [ -z "$out_file" ]; then
        log echo -e "${R}Alert email failed (cannot record transport output)${X}"
        return 1
    fi
    # Keep relay output off the shell heap and retain only a bounded tail.
    (
        exec 9>&-
        sed 's/\x1b\[[0-9;]*m//g' "$LOG" | timeout 45 mail \
            -a "Content-Type: text/plain; charset=UTF-8" \
            -s "[$APP_NAME] $1" "$SMTP_TO" 2>&1 \
            | tail -c "$MAX_LOG_BYTES" > "$out_file"
    )
    rc=$?
    if [ "$rc" -eq 0 ]; then
        log echo -e "${G}Alert email sent${X}"
    else
        log echo -e "${R}Alert email failed (exit ${rc})${X}"
        if [ -s "$out_file" ]; then
            log redact_file "$out_file"
        fi
    fi
    if ! rm -f "$out_file"; then
        log echo -e "${Y}Warning: cannot remove mailer output file${X}"
        return 1
    fi
    [ "$rc" -eq 0 ] && return 0
    return 1
}

send_telegram() {
    [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && return 0
    local text="$1" out rc status body status_file tail_rc
    status_file="$(mktemp "${TMPDIR:-/tmp}/restic-telegram-status.XXXXXX")"
    if [ -z "$status_file" ]; then
        log echo -e "${R}Telegram notification failed (cannot record transport status)${X}"
        return 1
    fi
    if ! exec 3>"$status_file"; then
        rm -f "$status_file" \
            || log echo -e "${Y}Warning: cannot remove Telegram status file${X}"
        log echo -e "${R}Telegram notification failed (cannot record transport status)${X}"
        return 1
    fi
    # Read the API error body; --fail would discard it. Actual success is checked below.
    out="$(
        {
            curl -sS -m 10 --retry 2 \
                -w '\n%{http_code}' \
                --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
                --data-urlencode "text=[$APP_NAME] ${text}" \
                --data-urlencode "disable_web_page_preview=true" \
                "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" 2>&1
            printf '%s\n' "$?" >&3
        } | tail -c "$MAX_LOG_BYTES"
    )"
    tail_rc=$?
    exec 3>&-
    if [ "$tail_rc" -ne 0 ] || ! rc="$(cat "$status_file")"; then
        rm -f "$status_file" \
            || log echo -e "${Y}Warning: cannot remove Telegram status file${X}"
        log echo -e "${R}Telegram notification failed (cannot record response)${X}"
        return 1
    fi
    if ! rm -f "$status_file"; then
        log echo -e "${Y}Warning: cannot remove Telegram status file${X}"
        return 1
    fi
    # curl appends HTTP status after the body; keep it separate.
    status="${out##*$'\n'}"
    body="${out%$'\n'*}"
    if [ "$rc" -eq 0 ] && [ "$status" = "200" ] \
        && [[ "$body" =~ $TELEGRAM_OK_PREFIX ]]; then
        log echo -e "${G}Telegram notification sent${X}"
        return 0
    fi
    # Distinguish transport failures from API rejections.
    if [ "$rc" -ne 0 ]; then
        log echo -e "${R}Telegram notification failed (curl exit ${rc})${X}"
    elif [ -n "$status" ] && [ "$status" != "000" ]; then
        log echo -e "${R}Telegram notification failed (HTTP ${status})${X}"
    else
        log echo -e "${R}Telegram notification failed (no HTTP response)${X}"
    fi
    # API and proxy errors can echo either credential.
    body="${body//$TELEGRAM_BOT_TOKEN/<redacted>}"
    [ -n "$TELEGRAM_CHAT_ID" ] && body="${body//$TELEGRAM_CHAT_ID/<redacted>}"
    [ -n "$body" ] && log printf '%s\n' "$body"
    return 1
}

# Rare incidents use both channels; hourly jobs use Telegram only.
notify_rare() {
    local subject="$1" mail_rc=0 telegram_rc=0
    send_mail "$subject" || mail_rc=$?
    send_telegram "$subject" || telegram_rc=$?
    [ "$mail_rc" -eq 0 ] && [ "$telegram_rc" -eq 0 ]
}

notify_test() {
    local failed=""
    [ -n "${SMTP_TO:-}" ] || failed="SMTP_TO is not configured"
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        failed="${failed:+${failed}; }TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must both be configured"
    fi
    if [ -n "$failed" ]; then
        log echo -e "${R}Notification test cannot run: ${failed}${X}"
        return 2
    fi
    if notify_rare "Notification test"; then
        log echo -e "${G}Notification test passed${X}"
        return 0
    fi
    log echo -e "${R}Notification test failed${X}"
    return 1
}

check_audit_trail() {
    if ! ( : >> "$LOG" ) 2>/dev/null; then
        echo "Warning: cannot write ${LOG}; this run leaves no persistent log" >&2
    fi
    if ! is_regular_file "$STATUS_FILE"; then
        echo "Warning: ${STATUS_FILE} is not a regular file; backup state will not be recorded" >&2
    elif ! ( : >> "$STATUS_FILE" ) 2>/dev/null; then
        echo "Warning: cannot write ${STATUS_FILE}; backup state will not be recorded" >&2
    fi
}

# These paths outlive restore_test so its EXIT trap can clean them up.
RESTORE_TMP_DIR=""
RESTORE_BOOT_LOG=""
RESTORE_BOOT_PIPE=""
RESTORE_BOOT_READER=""

finish_restore_boot_log() {
    local attempt=0
    [ -n "$RESTORE_BOOT_READER" ] || return 0
    # Stop waiting if a descendant keeps the pipe open.
    while kill -0 "$RESTORE_BOOT_READER" 2>/dev/null; do
        if [ "$attempt" -ge 50 ]; then
            kill "$RESTORE_BOOT_READER" 2>/dev/null || :
            break
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    wait "$RESTORE_BOOT_READER" 2>/dev/null || :
    RESTORE_BOOT_READER=""
}

cleanup_restore_tmp() {
    finish_restore_boot_log
    [ -n "$RESTORE_TMP_DIR" ] && rm -rf "$RESTORE_TMP_DIR"
    [ -n "$RESTORE_BOOT_LOG" ] && rm -f "$RESTORE_BOOT_LOG"
    [ -n "$RESTORE_BOOT_PIPE" ] && rm -f "$RESTORE_BOOT_PIPE"
    # The trap can run again at process exit; make the second pass a no-op.
    RESTORE_TMP_DIR=""
    RESTORE_BOOT_LOG=""
    RESTORE_BOOT_PIPE=""
    RESTORE_BOOT_READER=""
    return 0
}

# Capture only a bounded tail and always pass it through redaction.
run_command() {
    local show_success="$1" label="$2" timeout_seconds="$3" out_file raw_file rc
    shift 3
    CURRENT_STEP="$label"
    out_file="$(mktemp "${TMPDIR:-/tmp}/restic-run.XXXXXX")" \
        || die "Unable to create temporary output file"
    raw_file="$(mktemp "${TMPDIR:-/tmp}/restic-raw.XXXXXX")" \
        || { rm -f "$out_file"; die "Unable to create temporary output file"; }
    printf '%s' "$(redact_raw "${B}${label}${X} ")" | tee -a "$LOG"
    # Bound the pipe, not files written by the command: recovery must remain able
    # to produce a database or attachment larger than the diagnostic cap.
    local raw_limit=$((MAX_LOG_BYTES * 8))
    rc=0
    (
        # Do not leak the backup lock into either side of the pipeline.
        exec 9>&-
        timed "$timeout_seconds" "$@" 2>&1 | tail -c "$raw_limit" > "$raw_file"
    ) || rc=$?
    if ! tail -c "$MAX_LOG_BYTES" "$raw_file" > "$out_file"; then
        rm -f "$raw_file" "$out_file" || :
        die "Unable to read the bounded command output"
    fi
    rm -f "$raw_file" || log echo -e "${Y}Warning: cannot remove temporary command output${X}"
    if [ "$rc" -eq 0 ]; then
        log echo -e "${G}✓${X}"
        if [ "$show_success" = true ] && [ -s "$out_file" ]; then
            log_result 0 cat "$out_file"
        fi
        rm -f "$out_file" || log echo -e "${Y}Warning: cannot remove temporary command output${X}"
        return 0
    fi
    log echo -e "${R}✗${X}"
    if [ -s "$out_file" ]; then
        log echo "[output capped at ${MAX_LOG_BYTES} bytes]"
        log redact_file "$out_file"
    fi
    rm -f "$out_file" || log echo -e "${Y}Warning: cannot remove temporary command output${X}"
    exit 2
}

run() { run_command false "$@"; }

run_visible() { run_command true "$@"; }

sqlite_integrity_check() {
    local label="$1" database="$2"
    # shellcheck disable=SC2016  # Positional parameters belong to bash -c.
    run "$label" "$QUICK_TIMEOUT" bash -c '
        set -o pipefail
        sqlite3 "$1" "PRAGMA integrity_check" | awk "$2"
    ' sqlite "$database" "$SQLITE_INTEGRITY_AWK"
}

log_dir_size() {
    local sizes
    # A failed read is not an empty directory.
    sizes="$(find "$LOG_DIR" -maxdepth 1 -type f ! -name backup.lock \
        -exec stat -c '%s' {} + 2>/dev/null)" || return 2
    printf '%s\n' "$sizes" | awk '{total += $1} END {print total + 0}'
}

trim_logs() {
    local file size tmp total failed=0
    if ! find "$LOG_DIR" -maxdepth 1 -type f \
        \( -name '*.log' -o -name '*.log.tmp.*' \) \
        -mmin +600 ! -path "$LOG" -delete; then
        echo "Warning: could not remove expired logs from ${LOG_DIR}" >&2
        failed=1
    fi
    for file in "$LOG_DIR"/*.log; do
        [ -f "$file" ] || continue
        if ! size="$(wc -c < "$file")"; then
            echo "Warning: cannot enforce the per-file log cap for ${file}" >&2
            failed=1
            continue
        fi
        if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
            tmp="${file}.tmp.$$"
            if tail -c "$MAX_LOG_BYTES" "$file" > "$tmp"; then
                if ! mv "$tmp" "$file"; then
                    echo "Warning: cannot replace oversized log ${file}" >&2
                    rm -f "$tmp"
                    failed=1
                fi
            else
                echo "Warning: cannot enforce the per-file log cap for ${file}" >&2
                rm -f "$tmp"
                failed=1
            fi
        fi
    done
    if ! total="$(log_dir_size)"; then
        echo "Warning: cannot read ${LOG_DIR}; the log directory cap was not checked" >&2
        return 1
    fi
    if [ "$total" -gt "$MAX_LOG_DIR_BYTES" ]; then
        while IFS= read -r file; do
            [ -e "$file" ] || continue
            [ "$file" = "$LOG" ] && continue
            if ! size="$(stat -c '%s' "$file")"; then
                echo "Warning: cannot size log ${file} while trimming ${LOG_DIR}" >&2
                failed=1
                continue
            fi
            if rm -f "$file"; then
                total=$(( total - size ))
                [ "$total" -le "$MAX_LOG_DIR_BYTES" ] && break
            else
                echo "Warning: cannot remove log ${file} while trimming ${LOG_DIR}" >&2
                failed=1
            fi
        # Include interrupted rewrites, but never remove unrelated files.
        done < <(find "$LOG_DIR" -maxdepth 1 -type f \
            \( -name '*.log' -o -name '*.log.tmp.*' \) ! -path "$LOG" \
            -exec stat -c '%Y %n' {} + 2>/dev/null \
            | sort -n | cut -d' ' -f2-)
    fi
    if [ "$total" -gt "$MAX_LOG_DIR_BYTES" ]; then
        echo "Warning: log directory holds ${total} bytes, above the ${MAX_LOG_DIR_BYTES} byte cap and could not be trimmed" >&2
        return 1
    fi
    if [ "$failed" -ne 0 ]; then
        echo "Warning: log maintenance could not enforce every retention or file-size limit in ${LOG_DIR}" >&2
        return 1
    fi
    return 0
}

backup() {
    trap 'rc=$?; if [ "${rc:-0}" -ne 0 ] && [ "${rc:-0}" -ne 3 ]; then
        write_status failed "Task failed: ${CURRENT_STEP:-backup} (exit ${rc})"
        send_telegram "Task Failed: ${CURRENT_STEP:-backup}"
        heartbeat fail
    fi' EXIT

    # Cannot-create and already-held are different failures: only the latter is a skip.
    if ! exec 9>"$LOG_DIR/backup.lock"; then
        echo "Cannot create ${LOG_DIR}/backup.lock" >&2
        CURRENT_STEP="Cannot create backup lock"
        exit 2
    fi
    if ! flock -n 9; then
        log echo -e "${Y}Another backup is already running, skipping this run${X}"
        exit 3
    fi

    # Publish `running` only after acquiring the lock.
    if ! write_status running "Backup started"; then
        echo "Cannot record backup start state" >&2
        CURRENT_STEP="Cannot record backup start state"
        exit 2
    fi

    # Initialize only on restic exit 10; other failures need their real diagnosis.
    timed "$QUICK_TIMEOUT" restic cat config >/dev/null 2>&1 && rc=0 || rc=$?
    case "${rc:-1}" in
        0)  ;;
        10) log echo -e "${Y}Repository not initialized, initializing...${X}"
            run "Repo init" "$QUICK_TIMEOUT" restic init ;;
        *)  run "Repository access" "$QUICK_TIMEOUT" restic cat config ;;
    esac
    clear_stale_locks

    run "SQLite backup" "$QUICK_TIMEOUT" sqlite3 "$DATA/db.sqlite3" ".backup $DATA/backup.bak"
    sqlite_integrity_check "SQLite check" "$DATA/backup.bak"

    # Anchor exclusions at /data; a bare name would also exclude user attachments.
    local backup_excludes=(
        --exclude="$DATA/db.sqlite3"
        --exclude="$DATA/db.sqlite3-journal"
        --exclude="$DATA/db.sqlite3-shm"
        --exclude="$DATA/db.sqlite3-wal"
        --exclude="$DATA/icon_cache"
        --exclude="$DATA/backup-status.txt"
    )
    case "$LOG_DIR" in
        "$DATA"/*) backup_excludes+=(--exclude="$LOG_DIR") ;;
    esac
    run "Data backup" "$LONG_TIMEOUT" restic backup --verbose \
        "${backup_excludes[@]}" "$DATA"
    run "Health check" "$LONG_TIMEOUT" restic check
    run "Snapshot prune" "$LONG_TIMEOUT" restic forget \
        --keep-hourly 24 --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --keep-yearly 3 --prune

    local trim_message=""
    trim_logs || trim_message=" (log trim failed)"

    LAST_SUCCESS="$(date -u +%s)"
    if ! write_status ok "Backup complete${trim_message}"; then
        echo "Cannot record backup completion state" >&2
        CURRENT_STEP="Cannot record backup completion state"
        exit 2
    fi
    log echo -e "${G}Backup process complete ✨${X}"
    # Keep hourly noise on Telegram; email is reserved for rare checks.
    if [ -n "$trim_message" ]; then
        heartbeat fail
        send_telegram "Backup succeeded with warnings" || :
    else
        heartbeat ok
        if [ "$NOTIFY_ON_SUCCESS" = "true" ]; then
            send_telegram "Backup succeeded" || :
        fi
    fi
}

restore() {
    [ -z "${1:-}" ] && { echo "Usage: $0 restore <snapshot-id>"; exit 1; }
    if [ "${RESTORE_CONFIRM:-}" != "yes" ]; then
        echo "Refusing to overwrite /data without RESTORE_CONFIRM=yes" >&2
        echo "Run 'restore-test' to verify a snapshot first, or confirm the in-place restore on purpose." >&2
        exit 2
    fi
    clear_stale_locks
    run "Restore snapshot $1" "$LONG_TIMEOUT" restic restore --target / -- "$1"
    # The snapshot contains backup.bak, not the live database.
    log echo -e "${Y}The live db.* files are not in the snapshot; the consistent copy is /data/backup.bak.${X}"
    log echo "To finish: 'touch /data/restore-pending', then restart the machine; the entrypoint swaps backup.bak in before Vaultwarden starts."
}

restore_test() {
    local snapshot="${1:-latest}" tmp_parent free_bytes free_kb needed_bytes table stats_json
    tmp_parent="${TMPDIR:-/tmp}"
    [ -n "$tmp_parent" ] && [ -d "$tmp_parent" ] || tmp_parent=/tmp
    # Cleanup and every failure signal share one trap.
    trap 'rc=$?
        cleanup_restore_tmp
        if [ "${rc:-0}" -ne 0 ]; then
            write_guard_status failed "Restore drill failed (exit ${rc})"
            notify_rare "Restore drill failed"
            heartbeat fail
        fi' EXIT

    # The trap is armed before either scratch path is created.
    RESTORE_TMP_DIR="$(mktemp -d "$tmp_parent/restic-restore.XXXXXX")" \
        || die "Unable to create restore scratch directory"
    RESTORE_BOOT_LOG="$(mktemp "$tmp_parent/restic-boot.XXXXXX")" \
        || die "Unable to create restore scratch file"
    RESTORE_BOOT_PIPE="$RESTORE_TMP_DIR/restore-boot.fifo"
    if ! mkfifo "$RESTORE_BOOT_PIPE"; then
        die "Unable to create restore boot-log pipe"
    fi
    # Bound crash output so a failed boot cannot fill /tmp.
    tail -c "$MAX_LOG_BYTES" < "$RESTORE_BOOT_PIPE" > "$RESTORE_BOOT_LOG" &
    RESTORE_BOOT_READER=$!
    local target="$RESTORE_TMP_DIR" boot_log="$RESTORE_BOOT_LOG"

    clear_stale_locks
    # A failed or partial size response must stop the drill.
    if ! stats_json="$(
        timed "$QUICK_TIMEOUT" restic stats --json -- "$snapshot" 2>&1 \
            | tail -c "$MAX_LOG_BYTES"
    )"; then
        log echo -e "${R}Unable to size snapshot ${snapshot}${X}"
        [ -n "$stats_json" ] && log redact_raw "$stats_json"
        exit 2
    fi
    needed_bytes="$(printf '%s\n' "$stats_json" \
        | sed -n 's/.*"total_size": *\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    case "$needed_bytes" in
        ''|*[!0-9]*)
            log echo -e "${R}Unable to size snapshot ${snapshot}${X}"
            [ -n "$stats_json" ] && log redact_raw "$stats_json"
            exit 2
            ;;
    esac
    case "$needed_bytes" in
        0|[1-9]|[1-9][0-9]*) ;;
        *)
            log echo -e "${R}Unable to use snapshot ${snapshot}: unusable snapshot size${X}"
            exit 2
            ;;
    esac
    if [ "${#needed_bytes}" -gt 16 ]; then
        log echo -e "${R}Unable to use snapshot ${snapshot}: unusable snapshot size${X}"
        exit 2
    fi
    # A failed df is unknown, not a full disk.
    if ! free_kb="$(df -Pk "$tmp_parent" | awk 'NR == 2 {print $4}')"; then
        log echo -e "${R}Unable to read free space for the restore drill${X}"
        exit 2
    fi
    case "$free_kb" in
        ''|*[!0-9]*)
            log echo -e "${R}Unable to read free space for the restore drill${X}"
            exit 2
            ;;
    esac
    if [ "${#free_kb}" -gt 15 ]; then
        log echo -e "${R}Unable to read free space for the restore drill${X}"
        exit 2
    fi
    free_bytes=$((free_kb * 1024))
    needed_bytes=$((needed_bytes + needed_bytes / 5 + 67108864))
    if [ "$free_bytes" -lt "$needed_bytes" ]; then
        log echo -e "${R}Not enough free space for the restore drill${X}"
        log echo "available=${free_bytes} required=${needed_bytes}"
        exit 2
    fi

    run "Restore drill" "$LONG_TIMEOUT" restic restore --target "$target" -- "$snapshot"
    if [ ! -f "$target/data/backup.bak" ] || [ ! -f "$target/data/rsa_key.pem" ]; then
        log echo -e "${R}Restore drill is missing expected files${X}"
        exit 2
    fi
    sqlite_integrity_check "Restore SQLite check" "$target/data/backup.bak"
    if ! sqlite3 "$target/data/backup.bak" ".tables" 2>/dev/null | grep -q .; then
        log echo -e "${R}Restored database has no tables${X}"
        exit 2
    fi

    # Boot from the restored hot copy so Vaultwarden cannot create a fresh database.
    cp "$target/data/backup.bak" "$target/data/db.sqlite3"
    for table in __diesel_schema_migrations users; do
        if ! sqlite3 "$target/data/db.sqlite3" \
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${table}'" \
            | grep -q 1; then
            log echo -e "${R}The restored database is missing the ${table} table${X}"
            exit 2
        fi
    done
    # Prove the boot opened the restored database.
    sqlite3 "$target/data/db.sqlite3" \
        "CREATE TABLE IF NOT EXISTS drill_sentinel(v TEXT); DELETE FROM drill_sentinel; INSERT INTO drill_sentinel VALUES('restore-drill');"
    if ! printf '{"signups_allowed": false}\n' > "$target/restore-drill-config.json"; then
        log echo -e "${R}Unable to write the restore drill config${X}"
        exit 2
    fi

    log echo -e "${B}Restore cold boot${X} "
    if (
        cd "$target"
        boot_pid=""
        trap '[ -n "${boot_pid:-}" ] && kill "$boot_pid" 2>/dev/null || :' EXIT
        DATA_FOLDER="$target/data" WEB_VAULT_ENABLED=false \
            ROCKET_ADDRESS=127.0.0.1 ROCKET_PORT=18081 \
            CONFIG_FILE="$target/restore-drill-config.json" \
            /vaultwarden > "$RESTORE_BOOT_PIPE" 2>&1 &
        boot_pid=$!
        boot_alive() {
            [ -r "/proc/$boot_pid/stat" ] \
                && [ "$(awk '{print $3}' "/proc/$boot_pid/stat")" != "Z" ]
        }
        boot_ok=0
        for _ in $(seq 1 60); do
            boot_alive || break
            if wget -qO- http://127.0.0.1:18081/alive >/dev/null 2>&1 \
                && sleep 1 \
                && boot_alive; then
                    boot_ok=1
                    break
            fi
            sleep 0.5
        done
        kill "$boot_pid" 2>/dev/null || true
        wait "$boot_pid" 2>/dev/null || true
        boot_pid=""
        [ "$boot_ok" = "1" ]
    ); then
        finish_restore_boot_log
        log echo -e "${G}✓${X}"
        if [ "$(sqlite3 "$target/data/db.sqlite3" 'SELECT v FROM drill_sentinel' 2>/dev/null)" = "restore-drill" ]; then
            log echo -e "${G}The cold boot kept the restored database${X}"
        else
            log echo -e "${R}The cold boot did not keep the restored database${X}"
            exit 2
        fi
    else
        finish_restore_boot_log
        log echo -e "${R}✗${X}"
        log redact_file "$boot_log"
        exit 2
    fi
    log echo -e "${G}Restore drill complete${X}"
    heartbeat ok
}

verify() {
    trap 'rc=$?; if [ "${rc:-0}" -ne 0 ]; then
        write_guard_status failed "Repository verification failed (exit ${rc})"
        notify_rare "Repository verification failed"
        heartbeat fail
    fi' EXIT
    clear_stale_locks
    # Wait for an active backup instead of failing on its exclusive lock.
    run "Repository data verification" "$LONG_TIMEOUT" restic check \
        --read-data-subset="${VERIFY_SUBSET:-10%}" --retry-lock="${VERIFY_RETRY_LOCK:-10m}"
    heartbeat ok
}

check_freshness() {
    local limit="${BACKUP_MAX_AGE:-7200}" now age uptime_s lock_state active_backup=false
    now="$(date -u +%s)"

    # A free, inspectable lock proves a running marker is stale; unknown fails closed.
    if [ "$STATUS_STATE" = "running" ]; then
        backup_is_running
        lock_state=$?
        case "$lock_state" in
            0) active_backup=true ;;
            1) log echo -e "${R}The last backup started but never finished${X}"
               write_status failed "Backup did not finish"
               send_telegram "Backup did not finish"
               heartbeat fail
               exit 2 ;;
            2)
                log echo -e "${R}Cannot inspect the backup lock; backup freshness is unknown${X}"
                # Preserve state=running as evidence while reporting the guard failure.
                write_guard_status failed "Cannot inspect the backup lock"
                send_telegram "Cannot inspect the backup lock"
                heartbeat fail
                exit 2
                ;;
        esac
    fi

    # An unreadable marker is unknown, not a fresh volume.
    if [ "$STATUS_MARKER_ERROR" = "unreadable" ]; then
        log echo -e "${R}Cannot read ${STATUS_FILE}; backup freshness is unknown${X}"
        send_telegram "Backup marker is unreadable"
        heartbeat fail
        exit 2
    fi
    if [ "$STATUS_MARKER_ERROR" = "missing" ]; then
        log echo -e "${R}${STATUS_FILE} does not contain last_success${X}"
        send_telegram "Backup marker is missing last_success"
        heartbeat fail
        exit 2
    fi
    if [ "$STATUS_MARKER_ERROR" = "oversized" ]; then
        log echo -e "${R}${STATUS_FILE} exceeds ${MAX_STATUS_BYTES} bytes; backup freshness is unknown${X}"
        send_telegram "Backup marker is oversized"
        heartbeat fail
        exit 2
    fi
    if [ "$STATUS_MARKER_ERROR" = "not_regular" ]; then
        log echo -e "${R}${STATUS_FILE} is not a regular file; backup freshness is unknown${X}"
        send_telegram "Backup marker is not a regular file"
        heartbeat fail
        exit 2
    fi
    if [ "$STATUS_MARKER_ERROR" = "invalid" ]; then
        log echo -e "${R}${STATUS_FILE} has an unusable last_success value${X}"
        write_guard_status failed "last_success in ${STATUS_FILE} is not a number"
        send_telegram "Backup marker is unusable"
        heartbeat fail
        exit 2
    fi

    # A prior success cannot mask a current failure; only a new volume may be unknown.
    case "$STATUS_STATE" in
        ok|running) ;;
        failed)
            log echo -e "${R}${STATUS_FILE} records state=failed; the latest operation failed and last_success is not sufficient evidence${X}"
            send_telegram "Backup state is failed"
            heartbeat fail
            exit 2
            ;;
        unknown)
            if [ "$LAST_SUCCESS" != "0" ]; then
                log echo -e "${R}${STATUS_FILE} has an unknown state but a recorded success${X}"
                send_telegram "Backup marker state is inconsistent"
                heartbeat fail
                exit 2
            fi
            ;;
        *)
            log echo -e "${R}${STATUS_FILE} has an unusable recorded state${X}"
            send_telegram "Backup marker state is unusable"
            heartbeat fail
            exit 2
            ;;
    esac

    # The previous success may predate a live run; let that run finish.
    if [ "$active_backup" = true ]; then
        log echo -e "${Y}Backup is still running; skipping the last-success age check${X}"
        return 0
    fi

    if [ "$LAST_SUCCESS" = "0" ]; then
        # Allow a new volume time to take its first backup; an unreadable uptime is unknown.
        if ! uptime_s="$(cut -d. -f1 /proc/uptime)"; then
            uptime_s=""
        fi
        case "$uptime_s" in
            ''|*[!0-9]*)
                log echo -e "${R}Cannot determine the instance age${X}"
                write_guard_status failed "Cannot determine the instance age"
                send_telegram "Cannot determine the instance age"
                heartbeat fail
                exit 2
                ;;
        esac
        if [ "$uptime_s" -lt "$limit" ]; then
            log echo -e "${Y}No backup recorded yet and this instance is ${uptime_s}s old${X}"
            return 0
        fi
    fi
    age=$((now - LAST_SUCCESS))
    # A future timestamp indicates clock or marker corruption, never freshness.
    if [ "$age" -lt 0 ]; then
        log echo -e "${R}Last successful backup is stamped in the future (${age}s); the clock or ${STATUS_FILE} cannot be trusted${X}"
        write_guard_status failed "last_success is in the future (${age}s)"
        send_telegram "Backup marker is in the future"
        heartbeat fail
        exit 2
    fi
    if [ "$age" -le "$limit" ]; then
        log echo -e "${G}Last successful backup was ${age}s ago (limit ${limit}s)${X}"
        return 0
    fi
    log echo -e "${R}Last successful backup was ${age}s ago (limit ${limit}s)${X}"
    write_status failed "No successful backup for ${age}s"
    send_telegram "Backup stale"
    heartbeat fail
    exit 2
}

check_disk() {
    local limit="${BACKUP_MAX_USAGE_PERCENT:-85}" used_percent
    used_percent="$(df -P "$DATA" 2>/dev/null | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
    # An unreadable usage value is unknown, not healthy.
    case "$used_percent" in
        ''|*[!0-9]*)
            log echo -e "${R}Cannot read the usage of ${DATA}${X}"
            write_guard_status failed "Cannot read the usage of ${DATA}"
            send_telegram "Cannot read the usage of ${DATA}"
            heartbeat fail
            exit 2
            ;;
    esac
    if [ "$used_percent" -lt "$limit" ]; then
        log echo -e "${G}${DATA} is ${used_percent}% full (limit ${limit}%)${X}"
        return 0
    fi
    log echo -e "${R}${DATA} is ${used_percent}% full (limit ${limit}%)${X}"
    write_guard_status failed "Data volume is ${used_percent}% full"
    send_telegram "Data volume is ${used_percent}% full"
    heartbeat fail
    exit 2
}

audit() {
    local failed=0 file_count log_bytes bad_files dir_meta status_meta check_status
    local used_percent available_kb marker_state now age detail lock_state

    record_audit() {
        local result="$1" label="$2" detail="$3"
        if [ "$result" -eq 0 ]; then
            log echo -e "${G}✓ ${label}: ${detail}${X}"
        else
            failed=$((failed + 1))
            log echo -e "${R}✗ ${label}: ${detail}${X}"
        fi
    }

    if [ -L "$LOG_DIR" ] || [ ! -d "$LOG_DIR" ]; then
        record_audit 1 "log directory" "not a real directory"
    else
        if dir_meta="$(stat -c '%U %a' "$LOG_DIR" 2>/dev/null)"; then
            if [ "$dir_meta" = "vaultwarden 700" ]; then
                check_status=0
            else
                check_status=1
            fi
            record_audit "$check_status" "log directory" "owner/mode=${dir_meta}"
        else
            record_audit 1 "log directory" "metadata unreadable"
        fi

        if log_bytes="$(log_dir_size)"; then
            if [ "$log_bytes" -le "$MAX_LOG_DIR_BYTES" ]; then
                check_status=0
            else
                check_status=1
            fi
            record_audit "$check_status" "log bytes" "${log_bytes}/${MAX_LOG_DIR_BYTES}"
        else
            record_audit 1 "log bytes" "unreadable"
        fi

        if file_count="$(find "$LOG_DIR" -maxdepth 1 -type f ! -name backup.lock -print | wc -l)"; then
            record_audit 0 "log files" "$file_count"
        else
            record_audit 1 "log files" "unreadable"
        fi

        if bad_files="$(find "$LOG_DIR" -maxdepth 1 -type f \
            -exec stat -c '%U %a' {} + 2>/dev/null \
            | awk '$1 != "vaultwarden" || $2 != "600" {count++} END {print count + 0}')"; then
            if [ "$bad_files" -eq 0 ]; then
                check_status=0
            else
                check_status=1
            fi
            record_audit "$check_status" "log ownership" "noncompliant=${bad_files}"
        else
            record_audit 1 "log ownership" "metadata unreadable"
        fi

        if [ -e "$LOG_DIR/backup.lock" ] && ! is_regular_file "$LOG_DIR/backup.lock"; then
            record_audit 1 "backup lock" "not a regular file"
        else
            record_audit 0 "backup lock" "regular-or-absent"
        fi
    fi

    if ! is_regular_file "$STATUS_FILE"; then
        record_audit 1 "status marker" "not a regular file"
    elif status_meta="$(stat -c '%U %a' "$STATUS_FILE" 2>/dev/null)"; then
        if [ "$status_meta" = "vaultwarden 600" ]; then
            check_status=0
        else
            check_status=1
        fi
        record_audit "$check_status" "status marker" "owner/mode=${status_meta}"
    else
        record_audit 1 "status marker" "metadata unreadable"
    fi

    marker_state="$STATUS_STATE"
    case "$STATUS_MARKER_ERROR:$marker_state" in
        :ok) record_audit 0 "status state" "$marker_state" ;;
        :running)
            # A `running` marker is healthy only while its lock is held.
            backup_is_running
            lock_state=$?
            case "$lock_state" in
                0) record_audit 0 "status state" "running (lock held)" ;;
                1) record_audit 1 "status state" "running without a lock holder" ;;
                *) record_audit 1 "status state" "running with an uninspectable lock" ;;
            esac
            ;;
        ':failed' ) record_audit 1 "status state" "failed" ;;
        ':unknown' ) record_audit 1 "status state" "unknown" ;;
        :*) record_audit 1 "status state" "unusable" ;;
        *) record_audit 1 "status state" "unreadable" ;;
    esac

    now="$(date -u +%s)"
    if [ "$STATUS_MARKER_ERROR" != "" ] || [ "$LAST_SUCCESS" -eq 0 ]; then
        record_audit 1 "backup age" "no usable success timestamp"
    else
        age=$((now - LAST_SUCCESS))
        if [ "$age" -lt 0 ]; then
            record_audit 1 "backup age" "timestamp is in the future"
        else
            if [ "$age" -le "${BACKUP_MAX_AGE:-7200}" ]; then
                check_status=0
            else
                check_status=1
            fi
            record_audit "$check_status" "backup age" "${age}s/${BACKUP_MAX_AGE:-7200}s"
        fi
    fi

    if detail="$(df -Pk "$DATA" 2>/dev/null | awk 'NR == 2 {gsub(/%/, "", $5); print $5, $4}')"; then
        used_percent="${detail%% *}"
        available_kb="${detail#* }"
        case "${used_percent}${available_kb}" in
            ''|*[!0-9]*) record_audit 1 "volume space" "unreadable" ;;
            *)
                if [ "$used_percent" -lt "${BACKUP_MAX_USAGE_PERCENT:-85}" ]; then
                    check_status=0
                else
                    check_status=1
                fi
                record_audit "$check_status" "volume space" \
                    "used=${used_percent}% available=${available_kb}KiB"
                ;;
        esac
    else
        record_audit 1 "volume space" "unreadable"
    fi

    if [ "$failed" -ne 0 ]; then
        log echo -e "${R}Production audit failed (${failed} checks)${X}"
        exit 2
    fi
    log echo -e "${G}Production audit passed${X}"
}

require_bounded_int RESTIC_LOG_MAX_BYTES "$MAX_LOG_BYTES" "$LIMIT_LOG_BYTES"
require_bounded_int RESTIC_LOG_DIR_MAX_BYTES "$MAX_LOG_DIR_BYTES" "$LIMIT_LOG_DIR_BYTES"
require_bounded_int RESTIC_QUICK_TIMEOUT "$QUICK_TIMEOUT" "$LIMIT_QUICK_TIMEOUT"
require_bounded_int RESTIC_LONG_TIMEOUT "$LONG_TIMEOUT" "$LIMIT_LONG_TIMEOUT"
require_bounded_int BACKUP_MAX_AGE "${BACKUP_MAX_AGE:-7200}" "$LIMIT_BACKUP_AGE"
require_bounded_int BACKUP_MAX_USAGE_PERCENT "${BACKUP_MAX_USAGE_PERCENT:-85}" 100
if [ "$MAX_LOG_BYTES" -gt "$MAX_LOG_DIR_BYTES" ]; then
    echo "Error: RESTIC_LOG_MAX_BYTES must not exceed RESTIC_LOG_DIR_MAX_BYTES, got '${MAX_LOG_BYTES}' greater than '${MAX_LOG_DIR_BYTES}'" >&2
    exit 2
fi
case "$NOTIFY_ON_SUCCESS" in
    true|false) ;;
    *)
        echo "Error: BACKUP_NOTIFY_ON_SUCCESS must be true or false, got '${NOTIFY_ON_SUCCESS}'" >&2
        exit 2
        ;;
esac
if [ -n "$TELEGRAM_BOT_TOKEN" ] || [ -n "$TELEGRAM_CHAT_ID" ]; then
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "Error: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set together" >&2
        exit 2
    fi
    case "$TELEGRAM_BOT_TOKEN" in
        [0-9]*:[A-Za-z0-9_-]*) ;;
        *)
            echo "Error: TELEGRAM_BOT_TOKEN has an invalid format" >&2
            exit 2
            ;;
    esac
    case "$TELEGRAM_CHAT_ID" in
        -[0-9]*|[0-9]*|@[A-Za-z0-9_]*) ;;
        *)
            echo "Error: TELEGRAM_CHAT_ID has an invalid format" >&2
            exit 2
            ;;
    esac
fi

if [ "$READ_ONLY_AUDIT" != true ]; then
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    trim_logs
    check_audit_trail
fi

if [ -z "${RESTIC_PASSWORD:-}" ]; then
    case "$COMMAND" in
        audit|check-freshness|check-disk|notify-test|'')
            # Readiness guards do not need repository credentials.
            ;;
        backup)
            write_status failed "RESTIC_PASSWORD not set"
            send_telegram "RESTIC_PASSWORD not set"
            echo "Error: RESTIC_PASSWORD not set" >&2
            heartbeat fail
            exit 1
            ;;
        restore|restore-test|snapshots|verify)
            echo "Error: RESTIC_PASSWORD not set" >&2
            heartbeat fail
            exit 1
            ;;
    esac
fi

case "$COMMAND" in
    backup)          backup ;;
    audit)           audit ;;
    check-freshness) check_freshness ;;
    check-disk)      check_disk ;;
    notify-test)     notify_test ;;
    restore)         restore "${2:-}" ;;
    restore-test)    restore_test "${2:-}" ;;
    snapshots)       clear_stale_locks; run_visible "Snapshot list" "$QUICK_TIMEOUT" restic snapshots ;;
    verify)          verify ;;
    *)               echo "Usage: $0 {backup|audit|check-freshness|check-disk|notify-test|restore <id>|restore-test [id]|snapshots|verify}"; exit 1 ;;
esac
