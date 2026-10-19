#!/bin/sh
# Runs inside the built image with the Overmind stack already started. Covers the
# behaviour that only exists at container runtime: privilege dropping, the SMTP
# config permissions, and the restic failure paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# List any restore-drill scratch file that survived a run.
leftovers() {
    found=""
    for path in /tmp/restic-restore.* /tmp/restic-boot.*; do
        if [ -e "$path" ]; then found="$found$path "; fi
    done
    printf '%s' "$found"
}

# BusyBox pgrep matches `-x` against the whole argv[0], so `/vaultwarden` never
# matches the name `vaultwarden`. Read the kernel's own comm field instead.
pid_of() {
    for dir in /proc/[0-9]*; do
        [ -r "$dir/comm" ] || continue
        if [ "$(cat "$dir/comm")" = "$1" ]; then
            printf '%s\n' "${dir#/proc/}"
            return 0
        fi
    done
    return 1
}

# ── the entrypoint dropped privileges ────────────────────────────────────────
vault_uid="$(id -u vaultwarden)"
same "tini is PID 1 so orphans get reaped" tini "$(cat /proc/1/comm)"
for proc in tini overmind caddy supercronic vaultwarden; do
    if ! pid="$(pid_of "$proc")"; then
        bad "$proc is not running"
        continue
    fi
    uid="$(awk '/^Uid:/ {print $2}' "/proc/$pid/status")"
    same "$proc runs as vaultwarden" "$vault_uid" "$uid"
done

same "/etc/msmtprc is 0600" 600 "$(stat -c %a /etc/msmtprc)"
same "/etc/msmtprc belongs to vaultwarden" vaultwarden "$(stat -c %U /etc/msmtprc)"

# Vaultwarden refuses to boot when SMTP_HOST is set without SMTP_FROM, while the
# backup script only needs SMTP_HOST and SMTP_TO. The entrypoint has to give the
# app the same sender default that the msmtp config uses, or setting up alerts
# takes the password manager down.
# The container may itself be started with SMTP_* set, so clear them first.
smtp_env() {
    env -u SMTP_HOST -u SMTP_TO -u SMTP_FROM -u SMTP_USERNAME -u SMTP_PASSWORD \
        -u SMTP_PORT -u SMTP_TIMEOUT "$@" /entrypoint.sh env 2>/dev/null
}
injected="$(smtp_env SMTP_HOST=smtp.example.com SMTP_TO=ops@example.com)"
if printf '%s\n' "$injected" | grep -qx 'SMTP_FROM=ops@example.com'; then
    ok "the entrypoint defaults SMTP_FROM to SMTP_TO"
else
    bad "SMTP_FROM is not defaulted, so SMTP_HOST+SMTP_TO alone breaks the app"
fi
injected="$(smtp_env SMTP_HOST=smtp.example.com SMTP_TO=ops@example.com SMTP_FROM=sender@example.com)"
same "an explicit SMTP_FROM is preserved" 1 \
    "$(printf '%s\n' "$injected" | grep -c '^SMTP_FROM=sender@example.com$')"
injected="$(smtp_env SMTP_TO=ops@example.com)"
same "SMTP_FROM stays unset when there is no SMTP_HOST" 0 \
    "$(printf '%s\n' "$injected" | grep -c '^SMTP_FROM=')"

# SMTP credentials are arbitrary secrets: $, backticks, and backslashes must
# reach msmtprc verbatim. A second round of shell expansion silently corrupts
# the password and executes whatever sits between the backticks.
# shellcheck disable=SC2016  # the metacharacters must stay literal for the test
smtp_secret='pa$word`id -u`back\slash'
smtp_env SMTP_HOST=smtp.example.com SMTP_TO=ops@example.com SMTP_USERNAME=user \
    SMTP_PASSWORD="$smtp_secret" >/dev/null
same "an SMTP password with shell metacharacters is written verbatim" \
    "${smtp_secret}" "$(sed -n 's/^password //p' /etc/msmtprc)"

# A newline in any SMTP value would inject extra msmtprc directives, so it has
# to be refused before the file is written.
smtp_env SMTP_HOST=smtp.example.com SMTP_TO=ops@example.com \
    SMTP_PASSWORD='two
lines' >/dev/null 2>&1
same "an SMTP value containing a newline is rejected" 1 "$?"

# An unauthenticated relay is valid. Writing `auth on` plus empty user/password
# lines makes msmtp fail at delivery time, which is too late for a backup alert.
smtp_env SMTP_HOST=smtp.example.com SMTP_TO=ops@example.com >/dev/null
same "unauthenticated SMTP disables AUTH" 1 \
    "$(grep -c '^auth off$' /etc/msmtprc)"
same "unauthenticated SMTP writes no empty user line" 0 \
    "$(grep -c '^user ' /etc/msmtprc)"
same "unauthenticated SMTP writes no empty password line" 0 \
    "$(grep -c '^password ' /etc/msmtprc)"

# msmtp opens its logfile as the unprivileged user that sends the alert. Pointed
# at the /dev/stderr of the root process that wrote the config, that path cannot
# be reopened by `vaultwarden`: every send printed "cannot log to /dev/stderr:
# cannot open: Permission denied" and the delivery line never reached any log.
# The relay is unreachable on purpose, so the probe exercises the logfile
# without delivering anything.
smtp_env SMTP_HOST=127.0.0.1 SMTP_PORT=1 SMTP_TO=ops@example.com >/dev/null
mail_probe="$(su-exec vaultwarden sh -c 'echo probe | mail -s probe ops@example.com' 2>&1)"
same "the alert mailer can open the logfile it is configured with" 0 \
    "$(printf '%s\n' "$mail_probe" | grep -c 'cannot log to')"

# A half-configured credential pair is a typo, not a valid relay mode.
smtp_env SMTP_HOST=smtp.example.com SMTP_TO=ops@example.com \
    SMTP_USERNAME=user >/dev/null 2>&1
same "an SMTP username without a password is rejected" 1 "$?"
smtp_env SMTP_HOST=smtp.example.com SMTP_TO=ops@example.com \
    SMTP_PASSWORD=secret >/dev/null 2>&1
same "an SMTP password without a username is rejected" 1 "$?"

# ── config.json secret overrides ─────────────────────────────────────────────
# Vaultwarden gives /data/config.json priority over the environment. A secret
# left there silently overrides the Fly secret of the same name, so the
# entrypoint has to keep the file owner-only and name the overriding keys
# without printing their values.
config_backup=/tmp/selftest-config.json
rm -f "$config_backup"
[ -f /data/config.json ] && cp /data/config.json "$config_backup"
cat > /data/config.json <<'JSON'
{
  "admin_token": "selftest-admin-token",
  "smtp_username": "selftest-smtp-user",
  "smtp_password": "selftest-smtp-password",
  "signups_allowed": true
}
JSON
chmod 644 /data/config.json
entry_out="$(/entrypoint.sh true 2>&1)"
same "config.json is 0600 after the entrypoint" 600 "$(stat -c %a /data/config.json)"
same "the config.json warning names the overriding admin_token" 1 \
    "$(printf '%s\n' "$entry_out" | grep -c 'admin_token')"
same "the config.json warning names the overriding smtp_password" 1 \
    "$(printf '%s\n' "$entry_out" | grep -c 'smtp_password')"
same "the config.json warning names the overriding signups_allowed" 1 \
    "$(printf '%s\n' "$entry_out" | grep -c 'signups_allowed')"
same "the config.json warning does not print the secret value" 0 \
    "$(printf '%s\n' "$entry_out" | grep -c 'selftest-smtp-password')"
if [ -f "$config_backup" ]; then
    mv "$config_backup" /data/config.json
else
    rm -f /data/config.json
fi

# ── restic.sh ────────────────────────────────────────────────────────────────
echo "--- restic.sh"
export RESTIC_PASSWORD=selftest
export RESTIC_REPOSITORY=/tmp/selftest-repo
mkdir -p "$RESTIC_REPOSITORY"
chown vaultwarden:vaultwarden "$RESTIC_REPOSITORY"
rm -rf /tmp/restic-restore.* /tmp/restic-boot.*

# A zero limit used to clear every log file and time out every restic command
# without saying why. Misconfiguration has to fail before it destroys anything.
for pair in RESTIC_LOG_MAX_BYTES=0 RESTIC_LOG_DIR_MAX_BYTES=0 \
    RESTIC_QUICK_TIMEOUT=0 RESTIC_LONG_TIMEOUT=0 BACKUP_MAX_AGE=0; do
    name="${pair%%=*}"
    value="${pair#*=}"
    env "$name=$value" /restic.sh snapshots >/tmp/selftest-limit.log 2>&1
    limit_rc=$?
    if [ "$limit_rc" -eq 2 ] && grep -q "${name} must be" /tmp/selftest-limit.log; then
        ok "${name}=${value} is rejected before any work"
    else
        bad "${name}=${value} was not rejected (rc=${limit_rc})"
    fi
done

if /restic.sh backup >/tmp/selftest-backup.log 2>&1; then
    ok "backup succeeds against a fresh repository"
else
    bad "backup failed"
    sed -n '1,20p' /tmp/selftest-backup.log >&2
fi

if /restic.sh snapshots 2>/dev/null | grep -q '/data'; then
    ok "snapshots lists the new snapshot"
else
    bad "snapshots did not list the new snapshot"
fi

# Every `timeout` in run() leaves a child behind. Without a reaping PID 1 those
# become permanent zombies, and a zombie PID keeps the restic lock that process
# left behind looking active, which blocks verify and the next backup.
zombies() { ps -eo stat,comm | awk '$1 ~ /Z/' | wc -l; }
zombie_before="$(zombies)"
/restic.sh snapshots >/dev/null 2>&1
sleep 1
zombie_after="$(zombies)"
if [ "$zombie_after" -le "$zombie_before" ]; then
    ok "no zombie accumulates across a restic command (${zombie_before} -> ${zombie_after})"
else
    bad "zombies grew from ${zombie_before} to ${zombie_after} after one restic command"
fi

# A second run must skip instead of fighting for the repository lock, and the
# skip must not overwrite the state the live run is maintaining: the loser never
# owns anything, so recording "running" here erases a healthy "ok" while the
# real backup is still working.
printf 'state=ok\nupdated_at=%s\nlast_success=%s\nmessage=concurrency-test\n' \
    "$(date -u +%s)" "$(date -u +%s)" > /data/backup-status.txt
chown vaultwarden:vaultwarden /data/backup-status.txt
exec 9>/data/restic-logs/backup.lock
if flock -n 9; then
    /restic.sh backup >/tmp/selftest-lock.log 2>&1
    same "a concurrent run exits 3 instead of blocking" 3 "$?"
    same "a skipped concurrent run leaves the recorded state alone" "ok" \
        "$(sed -n 's/^state=//p' /data/backup-status.txt)"
else
    bad "could not take the backup lock for the concurrency test"
fi
exec 9>&-

# freshness guard: a recent success is quiet, a stale one alerts
seed_status() { # last_success epoch
    printf 'state=ok\nupdated_at=%s\nlast_success=%s\nmessage=selftest\n' "$1" "$1" \
        > /data/backup-status.txt
    chown vaultwarden:vaultwarden /data/backup-status.txt
}
seed_status "$(date -u +%s)"
/restic.sh check-freshness >/tmp/selftest-fresh.log 2>&1
same "freshness guard accepts a recent backup" 0 "$?"
seed_status 1
BACKUP_MAX_AGE=60 /restic.sh check-freshness >/tmp/selftest-stale.log 2>&1
stale_rc=$?
if [ "$stale_rc" -ne 0 ]; then
    ok "freshness guard fails on a stale backup"
else
    bad "freshness guard accepted a stale backup"
fi
same "freshness guard explains the alert" 1 \
    "$(grep -c 'Last successful backup was' /tmp/selftest-stale.log)"
same "freshness guard records the stale state" "failed" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"

# A marker that cannot be trusted is not a fresh backup. A timestamp in the
# future was subtracted into a negative age that passed the freshness test
# ("was -86400s ago"), and a non-numeric one aborted the arithmetic with
# "unbound variable", so the guard either reported a healthy backup or died
# without alerting anyone.
seed_status "$(( $(date -u +%s) + 86400 ))"
/restic.sh check-freshness >/tmp/selftest-future.log 2>&1
future_rc=$?
same "freshness guard refuses a last_success in the future" 2 "$future_rc"
same "freshness guard explains the future timestamp" 1 \
    "$(grep -c 'in the future' /tmp/selftest-future.log)"
same "freshness guard records the unusable timestamp" "failed" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"

printf 'state=ok\nupdated_at=0\nlast_success=not-a-number\nmessage=corrupt\n' \
    > /data/backup-status.txt
chown vaultwarden:vaultwarden /data/backup-status.txt
/restic.sh check-freshness >/tmp/selftest-corrupt.log 2>&1
corrupt_rc=$?
same "freshness guard refuses a corrupt last_success" 2 "$corrupt_rc"
same "a corrupt last_success is not an arithmetic crash" 0 \
    "$(grep -c 'unbound variable\|syntax error' /tmp/selftest-corrupt.log)"

# The log directory has its own cap, but the volume also holds attachments, the
# icon cache and the database. Once it fills, Vaultwarden's writes and the
# backup fail together, and a Fly volume can only be grown by migrating the
# data, so the hourly guard has to report the approach while there is room. The
# limit is the knob: one percent forces the alert without filling anything.
seed_status "$(date -u +%s)"
BACKUP_MAX_USAGE_PERCENT=1 /restic.sh check-disk >/tmp/selftest-disk-full.log 2>&1
same "a volume past the limit fails the check" 2 "$?"
same "the full volume is explained" 1 \
    "$(grep -c '% full' /tmp/selftest-disk-full.log)"
same "the full volume is recorded" "failed" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"
BACKUP_MAX_USAGE_PERCENT=100 /restic.sh check-disk \
    >/tmp/selftest-disk-ok.log 2>&1
same "a volume under the limit is quiet" 0 "$?"

# "Cannot read the usage" is not "the volume is fine". A guard that reads a
# failed df as a healthy volume stops guarding anything, silently.
df_stub_dir="$(mktemp -d)"
chmod 755 "$df_stub_dir"
printf '#!/bin/sh\nexit 1\n' > "$df_stub_dir/df"
chmod 755 "$df_stub_dir/df"
PATH="$df_stub_dir:$PATH" /restic.sh check-disk >/tmp/selftest-disk-unknown.log 2>&1
same "an unreadable volume reading fails the check" 2 "$?"
same "the unreadable reading is explained" 1 \
    "$(grep -c 'Cannot read the usage' /tmp/selftest-disk-unknown.log)"
rm -rf "$df_stub_dir"

BACKUP_MAX_USAGE_PERCENT=101 /restic.sh snapshots >/tmp/selftest-disk-bad.log 2>&1
bad_limit_rc=$?
same "a usage limit outside 1-100 fails the run" 2 "$bad_limit_rc"
same "a usage limit outside 1-100 is explained" 1 \
    "$(grep -c 'BACKUP_MAX_USAGE_PERCENT must be between' /tmp/selftest-disk-bad.log)"

# A run that is killed mid-flight leaves the status at "running" forever. That
# has to be reported once nothing holds the lock, and left alone while a real
# backup is still working.
seed_running() {
    printf 'state=running\nupdated_at=%s\nlast_success=%s\nmessage=Backup started\n' \
        "$(date -u +%s)" "$(date -u +%s)" > /data/backup-status.txt
    chown vaultwarden:vaultwarden /data/backup-status.txt
}
seed_running
/restic.sh check-freshness >/tmp/selftest-stuck.log 2>&1
same "check-freshness flags a backup that never finished" 2 "$?"
same "the stuck run is recorded as failed" "failed" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"

# The volume guard at :35 is not a backup run, and it runs before the freshness
# check at :45. Overwriting `state=running` there erased the marker the check
# reads, so a backup that started and never finished was reported as quiet and
# only surfaced much later through the stale-backup path.
seed_running
BACKUP_MAX_USAGE_PERCENT=1 /restic.sh check-disk >/tmp/selftest-disk-running.log 2>&1
same "the volume guard still fails a full volume" 2 "$?"
same "a full volume does not erase the in-flight marker" "running" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"
same "the full-volume alert is recorded next to the marker" 1 \
    "$(grep -c 'backup in flight' /data/backup-status.txt)"
/restic.sh check-freshness >/tmp/selftest-disk-running-fresh.log 2>&1
same "the freshness check still sees the unfinished backup" 2 "$?"
same "the unfinished backup is named after a volume alert" 1 \
    "$(grep -c 'never finished' /tmp/selftest-disk-running-fresh.log)"

seed_running
exec 9>/data/restic-logs/backup.lock
if flock -n 9; then
    /restic.sh check-freshness >/tmp/selftest-inflight.log 2>&1
    same "check-freshness leaves a backup that holds the lock alone" 0 "$?"
    same "the in-flight run keeps its running state" "running" \
        "$(sed -n 's/^state=//p' /data/backup-status.txt)"
else
    bad "could not take the backup lock for the in-flight test"
fi
exec 9>&-

# The lock itself can be uninspectable (volume full, directory read-only), and
# the check must not create it: a missing lock has to stay missing so "never
# backed up" remains distinguishable from "not running right now".
seed_running
rm -f /data/restic-logs/backup.lock
/restic.sh check-freshness >/tmp/selftest-nolock.log 2>&1
nolock_rc=$?
same "a missing lock is left missing by the freshness check" 0 \
    "$(find /data/restic-logs -maxdepth 1 -name 'backup.lock' | wc -l | tr -d ' ')"
same "a missing lock is not reported as a finished backup" 0 "$nolock_rc"

# "running" is then unknown, not "finished": reporting the latter would raise a
# false alert and overwrite a live backup's state.
seed_running
rm -f /data/restic-logs/backup.lock
chmod 500 /data/restic-logs
/restic.sh check-freshness >/tmp/selftest-unknown.log 2>&1
unknown_rc=$?
chmod 700 /data/restic-logs
: > /data/restic-logs/backup.lock
chown vaultwarden:vaultwarden /data/restic-logs/backup.lock
same "an uninspectable lock is not reported as a finished backup" 0 "$unknown_rc"
same "an uninspectable lock keeps the running state" "running" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"
same "an uninspectable lock is explained" 1 \
    "$(grep -c 'Cannot inspect the backup lock' /tmp/selftest-unknown.log)"

# The alert channels follow how often a job can repeat its warning. A job on
# `@hourly` would repeat an email up to 24 times a day, so the hourly jobs stay
# on Telegram and only the monthly integrity check keeps the incident email.
# Stub the mailer so any invocation is recorded, then pin both halves.
mail_dir=/tmp/selftest-mailer
mail_log=/tmp/selftest-mailer.log
rm -rf "$mail_dir"
mkdir -p "$mail_dir"
: > "$mail_log"
chmod 666 "$mail_log"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\ncat >/dev/null\nexit 0\n' \
    "$mail_log" > "$mail_dir/mail"
chmod 755 "$mail_dir/mail"
mail_calls() { wc -l < "$mail_log" | tr -d ' '; }

seed_status 1
PATH="$mail_dir:$PATH" SMTP_TO=ops@example.com BACKUP_MAX_AGE=60 \
    /restic.sh check-freshness >/tmp/selftest-hourly-mail.log 2>&1
same "a stale-backup alert never reaches the mailer" 0 "$(mail_calls)"
same "a stale-backup alert records no email attempt" 0 \
    "$(grep -c 'Alert email' /tmp/selftest-hourly-mail.log)"

# The backup runs on the same hourly schedule, so neither its success nor its
# failure may email. The success notification stays opt-in and Telegram only.
: > "$mail_log"
PATH="$mail_dir:$PATH" SMTP_TO=ops@example.com BACKUP_NOTIFY_ON_SUCCESS=true \
    /restic.sh backup >/tmp/selftest-backup-ok.log 2>&1
same "a successful backup never reaches the mailer" 0 "$(mail_calls)"
same "an opt-in success notification records no email attempt" 0 \
    "$(grep -c 'Alert email' /tmp/selftest-backup-ok.log)"

# A wrong password fails the run without letting `backup` initialise anything,
# which a missing repository would: `restic init` would quietly create it.
: > "$mail_log"
PATH="$mail_dir:$PATH" RESTIC_PASSWORD=the-wrong-password SMTP_TO=ops@example.com \
    /restic.sh backup >/tmp/selftest-backup-fail.log 2>&1
backup_fail_rc=$?
if [ "$backup_fail_rc" -ne 0 ]; then
    ok "a failing backup exits non-zero"
else
    bad "the failing-backup case did not fail; its assertions would be vacuous"
fi
same "a failing backup never reaches the mailer" 0 "$(mail_calls)"
same "a failing backup records no email attempt" 0 \
    "$(grep -c 'Alert email' /tmp/selftest-backup-fail.log)"
same "the alert recipient is not written to the run log" 0 \
    "$(grep -c 'ops@example.com' /tmp/selftest-backup-fail.log)"
rm -rf "$mail_dir"
BACKUP_NOTIFY_ON_SUCCESS=maybe /restic.sh snapshots \
    >/tmp/selftest-notify-invalid.log 2>&1
same "an invalid success-notification flag is rejected" 2 "$?"

# Telegram is a second notification channel. The token and chat id are secrets:
# they may appear in the API request but never in the persistent run log.
tg_dir=/tmp/selftest-telegram
tg_calls="$tg_dir/calls"
rm -rf "$tg_dir"
mkdir -p "$tg_dir"
chmod 777 "$tg_dir"
: > "$tg_calls"
chmod 666 "$tg_calls"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nprintf "%%s\\n" "{\\"ok\\":true}"\nexit 0\n' \
    "$tg_calls" > "$tg_dir/curl"
chmod 755 "$tg_dir/curl"
PATH="$tg_dir:$PATH" TELEGRAM_BOT_TOKEN='123456:selftest' \
    TELEGRAM_CHAT_ID='@selftest_channel' BACKUP_NOTIFY_ON_SUCCESS=true \
    /restic.sh backup >/tmp/selftest-tg-success.log 2>&1
same "a successful backup sends one Telegram message" 1 \
    "$(grep -c 'sendMessage' "$tg_calls")"
same "the Telegram message carries the success text" 1 \
    "$(grep -c 'Backup succeeded' "$tg_calls")"
same "the Telegram notification is recorded" 1 \
    "$(grep -c 'Telegram notification sent' /tmp/selftest-tg-success.log)"
same "the Telegram token is not written to the run log" 0 \
    "$(grep -c '123456:selftest' /tmp/selftest-tg-success.log)"
same "the Telegram chat id is not written to the run log" 0 \
    "$(grep -c '@selftest_channel' /tmp/selftest-tg-success.log)"

: > "$tg_calls"
seed_status 1
PATH="$tg_dir:$PATH" TELEGRAM_BOT_TOKEN='123456:selftest' \
    TELEGRAM_CHAT_ID='@selftest_channel' BACKUP_MAX_AGE=60 \
    /restic.sh check-freshness >/tmp/selftest-tg-fail.log 2>&1
same "a failed run sends one Telegram message" 1 \
    "$(grep -c 'Backup stale' "$tg_calls")"

# A rejected notification used to leave only an exit code behind, so a wrong
# token and an unreachable API looked identical in the run log. Record the API's
# own answer instead, redacted: it names the problem, and a proxy error page can
# echo the request URL that carries the token.
#
# The stub models real curl, which is the part the previous stub got wrong: with
# `--fail` curl exits non-zero and prints no response body on an HTTP error, so
# the reason the API gave was being thrown away. The assertions below fail until
# the request stops asking curl to hide it.
# shellcheck disable=SC2016  # the stub's own $@/$arg must stay literal
printf '#!/bin/sh\nfail=\nformat=\nwhile [ "$#" -gt 0 ]; do case "$1" in -f|--fail|-*f*) fail=1 ;; -w) shift; format="$1" ;; -w*) format="${1#-w}" ;; esac; shift; done\nif [ -n "$fail" ]; then echo "curl: (22) The requested URL returned error: 401" >&2; exit 22; fi\nprintf "%%s" "{\\"ok\\":false,\\"error_code\\":401,\\"description\\":\\"Unauthorized 123456:selftest\\"}"\nif [ -n "$format" ]; then printf "%%b" "$format" | sed "s/%%{http_code}/401/g"; fi\n' \
    > "$tg_dir/curl"
chmod 755 "$tg_dir/curl"
seed_status "$(date -u +%s)"
PATH="$tg_dir:$PATH" TELEGRAM_BOT_TOKEN='123456:selftest' \
    TELEGRAM_CHAT_ID='@selftest_channel' BACKUP_NOTIFY_ON_SUCCESS=true \
    /restic.sh backup >/tmp/selftest-tg-reject.log 2>&1
same "a rejected Telegram notification is recorded as failed" 1 \
    "$(grep -c 'Telegram notification failed' /tmp/selftest-tg-reject.log)"
same "a rejected notification records the API answer" 1 \
    "$(grep -c 'Unauthorized' /tmp/selftest-tg-reject.log)"
same "a rejected notification redacts the token" 0 \
    "$(grep -c '123456:selftest' /tmp/selftest-tg-reject.log)"
same "a rejected notification keeps the redaction marker" 1 \
    "$(grep -c '<redacted>' /tmp/selftest-tg-reject.log)"
same "a rejected notification records the HTTP status" 1 \
    "$(grep -c 'Telegram notification failed (HTTP 401)' /tmp/selftest-tg-reject.log)"
same "a rejected notification does not report a successful curl exit" 0 \
    "$(grep -c 'Telegram notification failed (exit 0)' /tmp/selftest-tg-reject.log)"

TELEGRAM_BOT_TOKEN='123456:selftest' /restic.sh snapshots \
    >/tmp/selftest-tg-half.log 2>&1
same "a Telegram token without a chat id is rejected" 2 "$?"
rm -rf "$tg_dir"

# The dead-man's-switch ping is the only channel that survives a scheduler which
# stopped firing entirely, so the URL it hits has to match what the run actually
# did: a failure that pings the success URL silently disarms the whole alarm.
# A stub curl records the arguments instead of talking to the network.
hb_dir=/tmp/selftest-heartbeat
hb_calls="$hb_dir/calls"
rm -rf "$hb_dir"
mkdir -p "$hb_dir"
chmod 777 "$hb_dir"
: > "$hb_calls"
chmod 666 "$hb_calls"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$hb_calls" > "$hb_dir/curl"
chmod 755 "$hb_dir/curl"
hb_count() { wc -l < "$hb_calls" | tr -d ' '; }

# No URL configured: the helper must not reach the network at all.
seed_status 1
PATH="$hb_dir:$PATH" BACKUP_MAX_AGE=60 /restic.sh check-freshness \
    >/tmp/selftest-hb-unset.log 2>&1
hb_unset_rc=$?
same "an unset HEALTHCHECK_URL sends no ping" 0 "$(hb_count)"
same "an unset HEALTHCHECK_URL keeps the run's own exit status" 2 "$hb_unset_rc"

# A run that fails has to ping the failure URL, not the success one.
seed_status 1
PATH="$hb_dir:$PATH" HEALTHCHECK_URL=http://hb.invalid/ping BACKUP_MAX_AGE=60 \
    /restic.sh check-freshness >/tmp/selftest-hb-fail.log 2>&1
same "a failed run pings the failure URL once" 1 \
    "$(grep -c ' http://hb.invalid/ping/fail$' "$hb_calls")"

# A run that succeeds has to ping the base URL, without the failure suffix.
: > "$hb_calls"
PATH="$hb_dir:$PATH" HEALTHCHECK_URL=http://hb.invalid/ping /restic.sh backup \
    >/tmp/selftest-hb-ok.log 2>&1
same "a successful run pings the base URL once" 1 \
    "$(grep -c ' http://hb.invalid/ping$' "$hb_calls")"
same "a successful run does not ping the failure URL" 0 \
    "$(grep -c '/fail$' "$hb_calls")"
same "the ping carries a bounded timeout and retries" 1 \
    "$(grep -c -- '-m 10 --retry 3' "$hb_calls")"

# The ping is best effort: an unreachable switch must be recorded without
# replacing the run's own exit status.
printf '#!/bin/sh\nexit 7\n' > "$hb_dir/curl"
chmod 755 "$hb_dir/curl"
seed_status 1
PATH="$hb_dir:$PATH" HEALTHCHECK_URL=http://hb.invalid/ping BACKUP_MAX_AGE=60 \
    /restic.sh check-freshness >/tmp/selftest-hb-down.log 2>&1
hb_down_rc=$?
same "an undeliverable ping is recorded in the run log" 1 \
    "$(grep -c 'Heartbeat ping failed' /tmp/selftest-hb-down.log)"
same "an undeliverable ping keeps the run's own exit status" 2 "$hb_down_rc"
rm -rf "$hb_dir"

# A run that cannot write its own audit trail must say so.
chmod 500 /data/restic-logs
chmod 400 /data/backup-status.txt
sleep 1   # a fresh log name, so appending needs the directory itself
audit_out="$(/restic.sh snapshots 2>&1)"
same "an unwritable log directory is reported" 1 \
    "$(printf '%s\n' "$audit_out" | grep -c 'leaves no persistent log')"
same "an unwritable status file is reported" 1 \
    "$(printf '%s\n' "$audit_out" | grep -c 'backup state will not be recorded')"
chmod 700 /data/restic-logs
chmod 664 /data/backup-status.txt
chown vaultwarden:vaultwarden /data/restic-logs /data/backup-status.txt

# The directory cap is the guard against filling the volume with logs. BusyBox
# find supports no GNU printf predicate, so an implementation that relies on one
# reports zero bytes and never trims: this seeds 3 MiB of logs and requires the
# cap to hold.
seed_status "$(date -u +%s)"
for i in $(seq 1 12); do
    dd if=/dev/zero of="/data/restic-logs/selftest-cap-$i.log" bs=1024 count=256 2>/dev/null
done
cap_before="$(du -sk /data/restic-logs | awk '{print $1 * 1024}')"
RESTIC_LOG_DIR_MAX_BYTES=1048576 /restic.sh snapshots >/tmp/selftest-cap.log 2>&1
cap_after="$(du -sk /data/restic-logs | awk '{print $1 * 1024}')"
if [ "$cap_after" -le 1572864 ]; then
    ok "the log directory is trimmed to the cap (${cap_before} -> ${cap_after} bytes)"
else
    bad "the log directory kept ${cap_after} bytes although the cap is 1048576"
fi
rm -f /data/restic-logs/selftest-cap-*.log

# The cap is only a guard if a breach is reported. A frozen log directory makes
# every delete fail, and the script used to keep going without saying anything,
# so the volume could fill while each run still recorded a success.
dd if=/dev/zero of=/data/restic-logs/selftest-frozen.log bs=1024 count=64 2>/dev/null
chown vaultwarden:vaultwarden /data/restic-logs/selftest-frozen.log
chmod 500 /data/restic-logs
frozen_out="$(RESTIC_LOG_DIR_MAX_BYTES=1024 /restic.sh snapshots 2>&1)"
same "a log directory that cannot be trimmed is reported" 1 \
    "$(printf '%s\n' "$frozen_out" | grep -c 'could not be trimmed')"
chmod 700 /data/restic-logs
rm -f /data/restic-logs/selftest-frozen.log

# A backup that succeeded must still complete when the trim fails, but the
# failure cannot be swallowed: the recorded state has to carry it so an
# operator watching the backup sees the volume risk without a failed run.
dd if=/dev/zero of=/data/restic-logs/selftest-frozen.log bs=1024 count=64 2>/dev/null
chown vaultwarden:vaultwarden /data/restic-logs/selftest-frozen.log
chmod 500 /data/restic-logs
RESTIC_LOG_DIR_MAX_BYTES=1024 /restic.sh backup \
    >/tmp/selftest-frozen-backup.log 2>&1
frozen_backup_rc=$?
chmod 700 /data/restic-logs
rm -f /data/restic-logs/selftest-frozen.log
same "a backup with an untrimmable log directory still completes" 0 "$frozen_backup_rc"
same "the successful backup records the log trim failure" 1 \
    "$(grep -c 'log trim failed' /data/backup-status.txt)"

# "Cannot read the log directory" is not "the log directory is empty". The size
# probe used to print its fallback on top of awk's own zero, and the cap
# comparison then rejected the two-line value as a non-integer: an unreadable
# directory reached the alert channel as a false "trim failed" on a run that had
# nothing to trim.
mkdir -p /data/selftest-blocked
chmod 000 /data/selftest-blocked
blocked_out="$(RESTIC_LOG_DIR=/data/selftest-blocked /restic.sh snapshots 2>&1)"
chmod 700 /data/selftest-blocked
rmdir /data/selftest-blocked
same "an unreadable log directory is reported as unreadable" 1 \
    "$(printf '%s\n' "$blocked_out" | grep -c 'cannot read')"
same "an unreadable log directory is not measured as an empty one" 0 \
    "$(printf '%s\n' "$blocked_out" | grep -c 'integer expected')"

# A backend that never answers must be killed by the command timeout and
# recorded as a failure, instead of holding the lock until the next run.
stub_dir=/tmp/selftest-stub
mkdir -p "$stub_dir"
printf '#!/bin/sh\nsleep 300\n' > "$stub_dir/restic"
chmod +x "$stub_dir/restic"
seed_status "$(date -u +%s)"
hang_start="$(date -u +%s)"
PATH="$stub_dir:$PATH" RESTIC_QUICK_TIMEOUT=1 RESTIC_LONG_TIMEOUT=1 \
    RESTIC_REPOSITORY=/tmp/selftest-hang /restic.sh backup >/tmp/selftest-hang.log 2>&1
hang_status=$?
hang_elapsed=$(( $(date -u +%s) - hang_start ))
same "a hung backend exits 2" 2 "$hang_status"
if [ "$hang_elapsed" -lt 30 ]; then
    ok "the command timeout killed the hung backend in ${hang_elapsed}s"
else
    bad "the hung backend was not killed (${hang_elapsed}s)"
fi
# The captured stream is drained through a pipe, and a pipe only closes once
# every writer is gone. A helper the timed-out command left behind therefore
# held the run open past the timeout and kept the backup lock with it, so the
# timeout has to reach the whole process tree and not just the direct child.
# `snapshots` is the probe because it is not piped: a surviving helper shows up
# straight away instead of only once it finally exits on its own, which would
# let this pass for the wrong reason.
PATH="$stub_dir:$PATH" RESTIC_QUICK_TIMEOUT=1 RESTIC_LONG_TIMEOUT=1 \
    RESTIC_REPOSITORY=/tmp/selftest-hang /restic.sh snapshots \
    >/tmp/selftest-helper.log 2>&1
same "the timeout signals the helpers a command leaves behind" 0 \
    "$(pgrep -f 'sleep 300' | grep -c .)"
same "a hung backend is recorded as failed" "failed" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"
rm -rf "$stub_dir"

# Nothing the timed-out run spawned may hold the backup lock: a child that
# outlives the run would block every later backup, and those exits are treated
# as an intentional concurrent run, so nobody alerts.
if flock -n /data/restic-logs/backup.lock -c true 2>/dev/null; then
    ok "the killed run did not leak the backup lock to its children"
else
    bad "a child of the killed run still holds the backup lock"
fi

# A run killed mid-flight leaves its lock in the repository. backup() already
# cleared stale locks, but the other entry points did not: an interrupted run
# then blocked verify/snapshots with "repository is already locked".
head -c 8388608 /dev/urandom > /tmp/selftest-lock-seed.bin
# Run as vaultwarden, like /restic.sh does: a lock owned by another user is not
# what happens in production and only tests file permissions.
su-exec vaultwarden:vaultwarden restic backup --stdin --stdin-filename lock-seed \
    < /tmp/selftest-lock-seed.bin >/tmp/selftest-lockseed.log 2>&1 &
seed_pid=$!
for _ in $(seq 1 100); do
    [ -n "$(find /tmp/selftest-repo/locks -type f 2>/dev/null)" ] && break
    sleep 0.1
done
kill -9 "$seed_pid" 2>/dev/null || true
wait "$seed_pid" 2>/dev/null || true
rm -f /tmp/selftest-lock-seed.bin
sleep 1
seed_locks="$(find /tmp/selftest-repo/locks -type f 2>/dev/null | wc -l)"
if [ "$seed_locks" -ge 1 ]; then
    ok "a killed run leaves a stale lock behind (${seed_locks})"
else
    bad "could not reproduce a stale lock"
fi

# the monthly integrity check reads a slice back out of the repository
VERIFY_SUBSET=1% /restic.sh verify >/tmp/selftest-verify.log 2>&1
same "verify clears the stale lock and reads a data slice" 0 "$?"

# The monthly check is the only job that looks for repository damage, so a
# failure has to reach the operator. It is also the one job rare enough to keep
# the incident email, so this is where the mailer must still be reached.
seed_status "$(date -u +%s)"
RESTIC_REPOSITORY=/tmp/selftest-missing SMTP_TO=ops@example.com /restic.sh verify \
    >/tmp/selftest-verifyfail.log 2>&1
same "a failed verification exits 2" 2 "$?"
same "a failed verification alerts the operator" 1 \
    "$(grep -c 'Alert email' /tmp/selftest-verifyfail.log)"
same "a failed verification records the state" "failed" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"
same "a failed verification names the failing step" 1 \
    "$(grep -c 'Repository verification failed' /data/backup-status.txt)"
seed_status "$(date -u +%s)"

# a guard is only useful if the scheduler actually calls it
for guard in check-freshness check-disk; do
    if grep -q "/restic.sh ${guard}\$" /crontab; then
        ok "the ${guard} guard is scheduled in /crontab"
    else
        bad "the ${guard} guard is not scheduled in /crontab"
    fi
done

# run() caps the stream it captures at 8x RESTIC_LOG_MAX_BYTES. That cap must
# reach the captured output and nothing else: `ulimit -f` covered every file the
# wrapped command wrote, so once the SQLite hot copy outgrew it the copy died
# with SIGXFSZ and every hourly backup failed on a database that had simply
# grown, while `restic restore` answered "file too large" for any attachment
# above the same size and could not bring the instance back at all.
#
# The probe is three times the documented cap on purpose: a file-size limit
# reads in 1024-byte blocks under bash, so a probe sized to the cap alone would
# still pass against the broken doubling.
# shellcheck disable=SC2016  # the pattern must reach sed with its $ intact
default_log_bytes="$(sed -n 's/^MAX_LOG_BYTES="\${RESTIC_LOG_MAX_BYTES:-\([0-9][0-9]*\)}".*$/\1/p' /restic.sh)"
case "$default_log_bytes" in
    ''|*[!0-9]*)
        bad "could not read the default RESTIC_LOG_MAX_BYTES out of /restic.sh"
        default_log_bytes=262144
        ;;
esac
stream_cap=$(( default_log_bytes * 8 ))
probe_rows=$(( stream_cap * 3 / 1048576 + 1 ))
su-exec vaultwarden:vaultwarden sqlite3 /data/db.sqlite3 \
    'CREATE TABLE IF NOT EXISTS cap_probe(v BLOB); DELETE FROM cap_probe;'
probe_row=0
while [ "$probe_row" -lt "$probe_rows" ]; do
    su-exec vaultwarden:vaultwarden sqlite3 /data/db.sqlite3 \
        'INSERT INTO cap_probe VALUES(zeroblob(1048576));'
    probe_row=$(( probe_row + 1 ))
done
probe_bytes="$(stat -c %s /data/db.sqlite3)"
if [ "$probe_bytes" -le "$stream_cap" ]; then
    bad "the cap probe left the database at ${probe_bytes} bytes, not above ${stream_cap}"
elif /restic.sh backup >/tmp/selftest-cap-copy.log 2>&1; then
    ok "a database above the ${stream_cap}-byte output cap still backs up (${probe_bytes} bytes)"
else
    bad "a database above the ${stream_cap}-byte output cap broke the backup"
    sed -n '1,20p' /tmp/selftest-cap-copy.log >&2
fi
hot_bytes="$(stat -c %s /data/backup.bak 2>/dev/null || echo 0)"
if [ "$hot_bytes" -gt "$stream_cap" ]; then
    ok "the drill below carries a ${hot_bytes}-byte hot copy, above the cap"
else
    bad "the drill below carries only ${hot_bytes} bytes and would not exercise the cap"
fi

/restic.sh restore-test >/tmp/selftest-drill.log 2>&1
same "restore drill succeeds" 0 "$?"
# The snapshot carries the consistent hot copy instead of the live db.* files,
# so the drill only proves anything if it puts that copy where Vaultwarden looks
# and shows the booted instance kept it. Without the report below, the drill
# passed while booting an empty data directory.
same "the drill boots the restored database" 1 \
    "$(grep -c 'kept the restored database' /tmp/selftest-drill.log)"
same "restore drill leaves nothing in /tmp" "" "$(leftovers)"

RESTIC_REPOSITORY=/tmp/selftest-missing /restic.sh restore-test \
    >/tmp/selftest-drill-fail.log 2>&1
drill_status=$?
if [ "$drill_status" -ne 0 ]; then
    ok "restore drill reports an unreachable repository"
else
    bad "restore drill claimed success against a missing repository"
fi
same "restore drill leaves nothing in /tmp after a failure" "" \
    "$(leftovers)"

# Snapshot sizing has three outcomes: a real size, a successful response with
# no size field, and a failed read. Treating the last two as "zero bytes" made
# the drill decide it had enough space without knowing the snapshot size.
real_restic="$(command -v restic)"
stats_stub_dir="$(mktemp -d)"
chmod 755 "$stats_stub_dir"
# shellcheck disable=SC2016  # generated stub, not shell expansion
{
    printf '#!/bin/sh\n'
    printf 'case "$1" in\n'
    printf '  stats)\n'
    printf '    case "${STATS_MODE:-fail}" in\n'
    printf '      empty) printf "%%s\\n" "{\\\"foo\\\":1}"; exit 0 ;;\n'
    printf '      *) echo "stats backend unavailable" >&2; exit 1 ;;\n'
    printf '    esac ;;\n'
    printf '  *) exec "%s" "$@" ;;\n' "$real_restic"
    printf 'esac\n'
} > "$stats_stub_dir/restic"
chmod 755 "$stats_stub_dir/restic"

PATH="$stats_stub_dir:$PATH" STATS_MODE=fail /restic.sh restore-test \
    >/tmp/selftest-stats-fail.log 2>&1
same "restore drill refuses to continue when snapshot sizing fails" 2 "$?"
same "restore drill reports the snapshot sizing failure" 1 \
    "$(grep -c 'Unable to size snapshot' /tmp/selftest-stats-fail.log)"

PATH="$stats_stub_dir:$PATH" STATS_MODE=empty /restic.sh restore-test \
    >/tmp/selftest-stats-empty.log 2>&1
same "restore drill refuses a response without total_size" 2 "$?"
same "restore drill reports the missing snapshot size" 1 \
    "$(grep -c 'Unable to size snapshot' /tmp/selftest-stats-empty.log)"

# The README promises the dead-man's-switch ping covers the restore drill and
# uses the /fail URL when the run fails. The drill had no failure ping at all,
# so a broken drill left the switch armed as if nothing had run.
#
# The ping is optional, so it cannot be the only channel: with HEALTHCHECK_URL
# unset a failed drill reached nobody at all, while the monthly verify next to
# it emails and notifies Telegram. A drill that fails is the one warning that
# the snapshots cannot be restored, so assert the rare channel and the recorded
# state, not just the ping.
hb_drill_dir="$(mktemp -d)"
chmod 777 "$hb_drill_dir"
hb_drill_calls="$hb_drill_dir/calls"
: > "$hb_drill_calls"
chmod 666 "$hb_drill_calls"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' \
    "$hb_drill_calls" > "$hb_drill_dir/curl"
chmod 755 "$hb_drill_dir/curl"
# Seed a known state: the assertion below has to see this run's failure, not a
# leftover from an earlier case that happens to contain the same word.
printf 'state=ok\nupdated_at=0\nlast_success=0\nmessage=seeded\n' > /data/backup-status.txt
chown vaultwarden:vaultwarden /data/backup-status.txt
PATH="$hb_drill_dir:$stats_stub_dir:$PATH" HEALTHCHECK_URL=http://hb.invalid/ping \
    TELEGRAM_BOT_TOKEN='123456:selftest' TELEGRAM_CHAT_ID='@selftest_channel' \
    STATS_MODE=fail /restic.sh restore-test >/tmp/selftest-drill-heartbeat.log 2>&1
same "a failed restore drill pings the failure URL" 1 \
    "$(grep -c ' http://hb.invalid/ping/fail$' "$hb_drill_calls")"
same "a failed restore drill does not ping the success URL" 0 \
    "$(grep -c ' http://hb.invalid/ping$' "$hb_drill_calls")"
same "a failed restore drill reaches the rare alert channel" 1 \
    "$(grep -c 'api.telegram.org' "$hb_drill_calls")"
same "a failed restore drill records the failed state" 1 \
    "$(grep -c '^state=failed' /data/backup-status.txt)"
rm -rf "$hb_drill_dir"
rm -rf "$stats_stub_dir"

# A failed df is not a full disk. The drill must stop with the real cause
# instead of reporting a made-up zero-byte reading as a capacity failure.
df_stub_dir="$(mktemp -d)"
chmod 755 "$df_stub_dir"
printf '#!/bin/sh\nexit 1\n' > "$df_stub_dir/df"
chmod 755 "$df_stub_dir/df"
PATH="$df_stub_dir:$PATH" /restic.sh restore-test \
    >/tmp/selftest-drill-df.log 2>&1
same "restore drill refuses when free space cannot be read" 2 "$?"
same "restore drill reports the free-space read failure" 1 \
    "$(grep -c 'Unable to read free space' /tmp/selftest-drill-df.log)"
same "restore drill does not misreport an unreadable free-space check as a full disk" 0 \
    "$(grep -c 'Not enough free space' /tmp/selftest-drill-df.log)"
rm -rf "$df_stub_dir"

# restore overwrites /data on purpose, so it runs last and the container is
# thrown away afterwards. It is also the only command that can destroy a live
# instance, so the destructive path sits behind an explicit confirmation.
/restic.sh restore latest >/tmp/selftest-restore-guard.log 2>&1
same "restore refuses to run without confirmation" 2 "$?"
same "the refused restore explains the confirmation" 1 \
    "$(grep -c 'RESTORE_CONFIRM=yes' /tmp/selftest-restore-guard.log)"
same "the refused restore never starts restic" 0 \
    "$(grep -c 'Restore snapshot' /tmp/selftest-restore-guard.log)"

RESTORE_CONFIRM=yes /restic.sh restore latest >/tmp/selftest-restore.log 2>&1
same "a confirmed restore writes the snapshot back" 0 "$?"
if [ -f /data/rsa_key.pem ]; then
    ok "restore wrote /data/rsa_key.pem back"
else
    bad "restore did not write /data/rsa_key.pem back"
fi

# The monthly verify used to share a minute with the hourly backup, and restic
# refuses an exclusive lock by default, so the check failed instantly with
# "repo already locked" instead of verifying anything. This runs last because
# the gate backup adds a snapshot, and `latest` must stay the data snapshot for
# the drill above.
rm -f /tmp/selftest-gate
mkfifo /tmp/selftest-gate
chmod 666 /tmp/selftest-gate
( exec 3>/tmp/selftest-gate; sleep 5 ) &
gate_producer=$!
su-exec vaultwarden:vaultwarden restic backup --stdin --stdin-filename verify-gate \
    < /tmp/selftest-gate >/tmp/selftest-gate.log 2>&1 &
gate_backup=$!
for _ in $(seq 1 100); do
    [ -n "$(find /tmp/selftest-repo/locks -type f 2>/dev/null)" ] && break
    sleep 0.1
done
gate_start="$(date -u +%s)"
VERIFY_RETRY_LOCK=60s VERIFY_SUBSET=1% /restic.sh verify >/tmp/selftest-retry.log 2>&1
gate_rc=$?
gate_elapsed=$(( $(date -u +%s) - gate_start ))
same "verify waits for a running backup instead of failing" 0 "$gate_rc"
if [ "$gate_elapsed" -ge 3 ]; then
    ok "verify waited ${gate_elapsed}s for the backup lock"
else
    bad "verify returned in ${gate_elapsed}s without waiting for the lock"
fi
wait "$gate_backup" 2>/dev/null || true
wait "$gate_producer" 2>/dev/null || true
rm -f /tmp/selftest-gate

echo
report "image self tests"
