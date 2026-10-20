#!/bin/sh
# Runs inside the built image with the process stack already started. Covers the
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
for proc in tini caddy supercronic vaultwarden; do
    if ! pid="$(pid_of "$proc")"; then
        bad "$proc is not running"
        continue
    fi
    uid="$(awk '/^Uid:/ {print $2}' "/proc/$pid/status")"
    same "$proc runs as vaultwarden" "$vault_uid" "$uid"
done
for removed in tmux overmind; do
    if command -v "$removed" >/dev/null 2>&1; then
        bad "${removed} remains installed after the process-manager removal"
    else
        ok "${removed} is absent from the runtime image"
    fi
done
for removed in /Procfile /supervise.sh; do
    if [ -e "$removed" ]; then
        bad "${removed} remains in the runtime image"
    else
        ok "${removed} is absent from the runtime image"
    fi
done
if [ -x /services.sh ]; then
    ok "/services.sh owns the runtime process table"
else
    bad "/services.sh is missing or not executable"
fi

# Every regular file under the data volume is private application data. A mode
# of 0755 on the RSA key or 0644 on the database lets any other Linux identity
# in the container read the signing key or vault contents.
db_ready=0
for _ in $(seq 1 50); do
    if sqlite3 /data/db.sqlite3 'PRAGMA schema_version' >/dev/null 2>&1; then
        db_ready=1
        break
    fi
    sleep 0.2
done
if [ "$db_ready" = "1" ]; then
    ok "the live database is initialized before the mode test"
else
    bad "the live database did not become readable before the mode test"
fi
mkdir -p /data/attachments/selftest
printf 'private attachment\n' > /data/attachments/selftest/probe
printf 'hot copy\n' > /data/backup.bak
chmod 0755 /data /data/attachments /data/attachments/selftest
chmod 0644 /data/attachments/selftest/probe /data/db.sqlite3 /data/backup.bak
chmod 0755 /data/rsa_key.pem
outside=/tmp/selftest-mode-target
printf 'outside\n' > "$outside"
chmod 0644 "$outside"
ln -sfn "$outside" /data/selftest-mode-link
/entrypoint.sh true >/dev/null 2>&1
same "/data is private to its owner after the entrypoint" 700 "$(stat -c %a /data)"
same "the RSA private key is owner-only after the entrypoint" 600 "$(stat -c %a /data/rsa_key.pem)"
same "the live database is owner-only after the entrypoint" 600 "$(stat -c %a /data/db.sqlite3)"
same "the backup hot copy is owner-only after the entrypoint" 600 "$(stat -c %a /data/backup.bak)"
same "attachment files are owner-only after the entrypoint" 600 \
    "$(stat -c %a /data/attachments/selftest/probe)"
same "attachment directories are owner-only after the entrypoint" 700 \
    "$(stat -c %a /data/attachments/selftest)"
same "data hardening does not follow a symlink outside the volume" 644 \
    "$(stat -c %a "$outside")"
rm -f /data/selftest-mode-link /data/backup.bak "$outside"

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
  "smtp_host": "smtp.selftest.invalid",
  "smtp_port": 2525,
  "smtp_from": "sender.selftest.invalid",
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
same "the config.json warning names the overriding smtp_host" 1 \
    "$(printf '%s\n' "$entry_out" | grep -c 'smtp_host')"
same "the config.json warning names the overriding smtp_port" 1 \
    "$(printf '%s\n' "$entry_out" | grep -c 'smtp_port')"
same "the config.json warning names the overriding smtp_from" 1 \
    "$(printf '%s\n' "$entry_out" | grep -c 'smtp_from')"
same "the config.json warning names the overriding signups_allowed" 1 \
    "$(printf '%s\n' "$entry_out" | grep -c 'signups_allowed')"
same "the config.json warning does not print the secret value" 0 \
    "$(printf '%s\n' "$entry_out" | grep -c 'selftest-smtp-password')"
same "the config.json warning does not print the SMTP host value" 0 \
    "$(printf '%s\n' "$entry_out" | grep -c 'smtp.selftest.invalid')"
if [ -f "$config_backup" ]; then
    mv "$config_backup" /data/config.json
else
    rm -f /data/config.json
fi

# ── restic.sh ────────────────────────────────────────────────────────────────
echo "--- restic.sh"

# Freshness and disk guards do not read the repository, so a missing repository
# password must not disable the two jobs that detect a silent backup failure or
# a filling volume. Repository commands still require the password.
now="$(date -u +%s)"
printf 'state=ok\nupdated_at=%s\nlast_success=%s\nmessage=guard-without-password\n' \
    "$now" "$now" > /data/backup-status.txt
chown vaultwarden:vaultwarden /data/backup-status.txt
env -u RESTIC_PASSWORD /restic.sh check-freshness >/tmp/selftest-fresh-no-password.log 2>&1
same "freshness guard runs without the repository password" 0 "$?"
same "freshness guard still checks the marker without the password" 1 \
    "$(grep -c 'Last successful backup was' /tmp/selftest-fresh-no-password.log)"
env -u RESTIC_PASSWORD /restic.sh check-disk >/tmp/selftest-disk-no-password.log 2>&1
same "disk guard runs without the repository password" 0 "$?"
same "disk guard still checks usage without the password" 1 \
    "$(grep -c '/data is .*% full' /tmp/selftest-disk-no-password.log)"
env -u RESTIC_PASSWORD /restic.sh snapshots >/tmp/selftest-snapshots-no-password.log 2>&1
same "repository commands still require the password" 1 "$?"

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
seed_status_state() { # state last_success epoch message
    printf 'state=%s\nupdated_at=%s\nlast_success=%s\nmessage=%s\n' \
        "$1" "$2" "$2" "$3" \
        > /data/backup-status.txt
    chown vaultwarden:vaultwarden /data/backup-status.txt
}
seed_status() { # last_success epoch
    seed_status_state ok "$1" selftest
}
seed_status "$(date -u +%s)"
/restic.sh check-freshness >/tmp/selftest-fresh.log 2>&1
same "freshness guard accepts a recent backup" 0 "$?"

# A recent timestamp from the previous successful run must not hide the fact
# that the latest backup failed. Otherwise the external freshness probe reports
# success for up to BACKUP_MAX_AGE and the failure exists only in Telegram.
seed_status_state failed "$(date -u +%s)" injected-backup-failure
/restic.sh check-freshness >/tmp/selftest-failed-state.log 2>&1
failed_state_rc=$?
same "freshness guard rejects a recorded backup failure" 2 "$failed_state_rc"
same "freshness guard names the recorded failure state" 1 \
    "$(grep -c 'records state=failed' /tmp/selftest-failed-state.log)"
same "freshness guard preserves the original failure reason" 1 \
    "$(grep -c '^message=injected-backup-failure$' /data/backup-status.txt)"

seed_status_state paused "$(date -u +%s)" injected-invalid-state
/restic.sh check-freshness >/tmp/selftest-invalid-state.log 2>&1
invalid_state_rc=$?
same "freshness guard rejects an unknown state value" 2 "$invalid_state_rc"
same "freshness guard names the unusable recorded state" 1 \
    "$(grep -c 'unusable recorded state' /tmp/selftest-invalid-state.log)"
same "freshness guard preserves an unusable state marker" 1 \
    "$(grep -c '^message=injected-invalid-state$' /data/backup-status.txt)"

seed_status_state unknown "$(date -u +%s)" injected-inconsistent-state
/restic.sh check-freshness >/tmp/selftest-inconsistent-state.log 2>&1
inconsistent_state_rc=$?
same "freshness guard rejects unknown state beside a recorded success" 2 "$inconsistent_state_rc"
same "freshness guard explains the inconsistent state" 1 \
    "$(grep -c 'unknown state but a recorded success' /tmp/selftest-inconsistent-state.log)"

now="$(date -u +%s)"
seed_status "0${now}"
/restic.sh check-freshness >/tmp/selftest-leading-zero.log 2>&1
same "freshness guard reads a leading-zero timestamp as decimal" 0 "$?"
same "a leading-zero timestamp does not hit octal arithmetic" 0 \
    "$(grep -c 'value too great for base' /tmp/selftest-leading-zero.log)"
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

# All digits are not enough to make a timestamp trustworthy. Bash arithmetic
# wraps values above signed 64-bit, and 2^64 becomes zero. With a large
# BACKUP_MAX_AGE the resulting "age" looked fresh even though the marker could
# never be a real Unix timestamp.
seed_status 18446744073709551616
BACKUP_MAX_AGE=2000000000 /restic.sh check-freshness \
    >/tmp/selftest-overflow.log 2>&1
overflow_rc=$?
same "freshness guard refuses a last_success that overflows" 2 "$overflow_rc"
same "freshness guard names the overflowing timestamp" 1 \
    "$(grep -c 'unusable last_success' /tmp/selftest-overflow.log)"
same "an overflowing timestamp is recorded as failed" "failed" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"

# An existing marker that cannot be read is not a fresh volume. The guard used
# to lower its unreadable value through an ignored pipeline, then either accept
# it as a young instance or replace it with last_success=0 while reporting a
# stale backup. Reading failure and no recorded data must stay distinguishable.
seed_status "$(date -u +%s)"
chown root:root /data/backup-status.txt
chmod 000 /data/backup-status.txt
unreadable_before="$(cksum < /data/backup-status.txt)"
BACKUP_MAX_AGE=1 /restic.sh check-freshness >/tmp/selftest-unreadable.log 2>&1
unreadable_rc=$?
same "freshness guard fails when the status file cannot be read" 2 "$unreadable_rc"
same "freshness guard names the unreadable status file" 1 \
    "$(grep -c 'Cannot read /data/backup-status.txt' /tmp/selftest-unreadable.log)"
same "an unreadable status file is not reported as no data" 0 \
    "$(grep -c 'No backup recorded yet' /tmp/selftest-unreadable.log)"
same "an unreadable status file is left untouched for diagnosis" "$unreadable_before" \
    "$(cksum < /data/backup-status.txt)"
chown vaultwarden:vaultwarden /data/backup-status.txt
chmod 600 /data/backup-status.txt

# A readable file without a last_success field is malformed, not equivalent to
# a missing file on a brand-new volume.
printf 'state=ok\nupdated_at=0\nmessage=missing-last-success\n' \
    > /data/backup-status.txt
chown vaultwarden:vaultwarden /data/backup-status.txt
missing_marker_before="$(cksum < /data/backup-status.txt)"
BACKUP_MAX_AGE=1 /restic.sh check-freshness >/tmp/selftest-missing-marker.log 2>&1
missing_marker_rc=$?
same "freshness guard fails when last_success is missing" 2 "$missing_marker_rc"
same "freshness guard names the missing last_success field" 1 \
    "$(grep -c 'does not contain last_success' /tmp/selftest-missing-marker.log)"
same "a missing last_success is not reported as no data" 0 \
    "$(grep -c 'No backup recorded yet' /tmp/selftest-missing-marker.log)"
same "a malformed marker is left untouched for diagnosis" "$missing_marker_before" \
    "$(cksum < /data/backup-status.txt)"

# The status marker is a small, generated file. Reading it without a cap makes
# a corrupt or hostile volume able to turn every hourly freshness check into an
# unbounded memory allocation. Reject the marker instead of parsing a prefix as
# if the complete file were valid.
seed_status "$(date -u +%s)"
padding=$((4096 - $(wc -c < /data/backup-status.txt)))
awk -v count="$padding" 'BEGIN {for (i = 0; i < count; i++) printf "x"}' \
    >> /data/backup-status.txt
BACKUP_MAX_AGE=1 /restic.sh check-freshness >/tmp/selftest-marker-at-limit.log 2>&1
same "freshness guard accepts a marker exactly at 4096 bytes" 0 "$?"
same "a marker at the size limit is still checked normally" 1 \
    "$(grep -c 'Last successful backup was' /tmp/selftest-marker-at-limit.log)"

printf 'x' >> /data/backup-status.txt
oversized_marker_before="$(cksum < /data/backup-status.txt)"
BACKUP_MAX_AGE=1 /restic.sh check-freshness >/tmp/selftest-oversized-marker.log 2>&1
oversized_marker_rc=$?
same "freshness guard rejects an oversized status marker" 2 "$oversized_marker_rc"
same "freshness guard names the status marker size limit" 1 \
    "$(grep -c 'exceeds 4096 bytes' /tmp/selftest-oversized-marker.log)"
same "an oversized marker is not accepted as fresh" 0 \
    "$(grep -c 'Last successful backup was' /tmp/selftest-oversized-marker.log)"
same "an oversized marker is left untouched for diagnosis" "$oversized_marker_before" \
    "$(cksum < /data/backup-status.txt)"

# Opening a FIFO blocks until a writer appears. A runtime replacement of the
# marker must fail closed immediately instead of wedging the only hourly
# freshness check with no supercronic timeout above it.
rm -f /data/backup-status.txt
mkfifo /data/backup-status.txt
chown vaultwarden:vaultwarden /data/backup-status.txt
timeout 5 /restic.sh check-freshness >/tmp/selftest-special-marker.log 2>&1
special_marker_rc=$?
same "freshness guard rejects a non-regular status marker" 2 "$special_marker_rc"
same "freshness guard names the non-regular status marker" 1 \
    "$(grep -c 'is not a regular file; backup freshness is unknown' \
        /tmp/selftest-special-marker.log)"
if [ -p /data/backup-status.txt ]; then
    ok "a non-regular marker is left untouched for diagnosis"
else
    bad "a non-regular marker was modified instead of rejected"
fi
rm -f /data/backup-status.txt
seed_status "$(date -u +%s)"

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

# A FIFO lock blocks a plain read-only open until a writer appears. The
# freshness guard must reject the path type immediately and preserve it as
# evidence instead of hanging the only hourly check above this marker.
seed_running
rm -f /data/restic-logs/backup.lock
mkfifo /data/restic-logs/backup.lock
chown vaultwarden:vaultwarden /data/restic-logs/backup.lock
timeout 5 /restic.sh check-freshness >/tmp/selftest-special-lock.log 2>&1
special_lock_rc=$?
same "a non-regular backup lock is rejected without blocking" 2 "$special_lock_rc"
same "a non-regular backup lock is reported as uninspectable" 1 \
    "$(grep -c 'Cannot inspect the backup lock' /tmp/selftest-special-lock.log)"
if [ -p /data/restic-logs/backup.lock ]; then
    ok "a non-regular backup lock is left untouched for diagnosis"
else
    bad "a non-regular backup lock was modified instead of rejected"
fi
rm -f /data/restic-logs/backup.lock
: > /data/restic-logs/backup.lock
chown vaultwarden:vaultwarden /data/restic-logs/backup.lock

# The lock itself can be uninspectable (missing, volume full, directory
# read-only). The check must not create it, but it also cannot treat that as a
# healthy run: a stale running marker with no inspectable lock needs an alert.
unknown_curl_dir=/tmp/selftest-unknown-curl
unknown_tg_calls=/tmp/selftest-unknown-tg.calls
unknown_hb_calls=/tmp/selftest-unknown-hb.calls
rm -rf "$unknown_curl_dir"
mkdir -p "$unknown_curl_dir"
: > "$unknown_tg_calls"
: > "$unknown_hb_calls"
chmod 666 "$unknown_tg_calls" "$unknown_hb_calls"
printf '#!/bin/sh\ncase "$*" in\n  *api.telegram.org*) printf "telegram\\n" >> "%s"; printf "{\\"ok\\":true}\\n200\\n" ;;\n  *health.invalid*) printf "fail\\n" >> "%s" ;;\n  *) exit 1 ;;\nesac\n' \
    "$unknown_tg_calls" "$unknown_hb_calls" > "$unknown_curl_dir/curl"
chmod 755 "$unknown_curl_dir/curl"

seed_running
rm -f /data/restic-logs/backup.lock
PATH="$unknown_curl_dir:$PATH" HEALTHCHECK_URL=http://health.invalid/ping \
    TELEGRAM_BOT_TOKEN='123456:selftest' TELEGRAM_CHAT_ID='@selftest_channel' \
    /restic.sh check-freshness >/tmp/selftest-nolock.log 2>&1
nolock_rc=$?
same "a missing lock is left missing by the freshness check" 0 \
    "$(find /data/restic-logs -maxdepth 1 -name 'backup.lock' | wc -l | tr -d ' ')"
same "a missing lock fails closed" 2 "$nolock_rc"
same "a missing lock preserves the running state" "running" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"
same "a missing lock sends one Telegram alert" 1 "$(wc -l < "$unknown_tg_calls" | tr -d ' ')"
same "a missing lock sends one failure heartbeat" 1 "$(wc -l < "$unknown_hb_calls" | tr -d ' ')"

# An unreadable lock is unknown, not healthy. Keep the in-flight state as
# evidence, but fail the hourly guard and alert through both configured paths.
: > "$unknown_tg_calls"
: > "$unknown_hb_calls"
seed_running
rm -f /data/restic-logs/backup.lock
chmod 500 /data/restic-logs
PATH="$unknown_curl_dir:$PATH" HEALTHCHECK_URL=http://health.invalid/ping \
    TELEGRAM_BOT_TOKEN='123456:selftest' TELEGRAM_CHAT_ID='@selftest_channel' \
    /restic.sh check-freshness >/tmp/selftest-unknown.log 2>&1
unknown_rc=$?
chmod 700 /data/restic-logs
: > /data/restic-logs/backup.lock
chown vaultwarden:vaultwarden /data/restic-logs/backup.lock
same "an uninspectable lock fails closed" 2 "$unknown_rc"
same "an uninspectable lock keeps the running state" "running" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"
same "an uninspectable lock is explained" 1 \
    "$(grep -c 'Cannot inspect the backup lock' /tmp/selftest-unknown.log)"
same "an uninspectable lock sends one Telegram alert" 1 \
    "$(wc -l < "$unknown_tg_calls" | tr -d ' ')"
same "an uninspectable lock sends one failure heartbeat" 1 \
    "$(wc -l < "$unknown_hb_calls" | tr -d ' ')"

# An unknown lock must not be resolved by the older success timestamp. The
# active backup may simply have started after the last completed one, so a
# stale timestamp must not overwrite state=running with a false failure.
printf 'state=running\nupdated_at=%s\nlast_success=1\nmessage=Backup started\n' \
    "$(date -u +%s)" > /data/backup-status.txt
chown vaultwarden:vaultwarden /data/backup-status.txt
rm -f /data/restic-logs/backup.lock
chmod 500 /data/restic-logs
PATH="$unknown_curl_dir:$PATH" HEALTHCHECK_URL=http://health.invalid/ping \
    TELEGRAM_BOT_TOKEN='123456:selftest' TELEGRAM_CHAT_ID='@selftest_channel' \
    BACKUP_MAX_AGE=1 /restic.sh check-freshness >/tmp/selftest-unknown-stale.log 2>&1
unknown_stale_rc=$?
chmod 700 /data/restic-logs
: > /data/restic-logs/backup.lock
chown vaultwarden:vaultwarden /data/restic-logs/backup.lock
same "an uninspectable lock does not become a stale-backup success" 2 "$unknown_stale_rc"
same "an uninspectable lock preserves running despite an old success" "running" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"

# The alert channels follow how often a job can repeat its warning. An hourly
# job would repeat an email up to 24 times a day, so the hourly jobs stay on
# Telegram and only the monthly integrity check keeps the incident email.
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
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nprintf "%%s\\n" "{\\"ok\\":true}"\nprintf "%%s\\n" "200"\nexit 0\n' \
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

# A missing repository password stops before backup() installs its failure trap.
# The status file alone is not an alert: record the failed state and tell the
# operator immediately over the configured high-frequency channel.
: > "$tg_calls"
env -u RESTIC_PASSWORD PATH="$tg_dir:$PATH" TELEGRAM_BOT_TOKEN='123456:selftest' \
    TELEGRAM_CHAT_ID='@selftest_channel' /restic.sh backup \
    >/tmp/selftest-tg-missing-restic-password.log 2>&1
missing_password_rc=$?
same "a missing Restic password exits non-zero" 1 "$missing_password_rc"
same "a missing Restic password sends one Telegram message" 1 \
    "$(grep -c 'RESTIC_PASSWORD not set' "$tg_calls")"
same "a missing Restic password records the failed backup state" "failed" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"

: > "$tg_calls"
seed_status 1
PATH="$tg_dir:$PATH" TELEGRAM_BOT_TOKEN='123456:selftest' \
    TELEGRAM_CHAT_ID='@selftest_channel' BACKUP_MAX_AGE=60 \
    /restic.sh check-freshness >/tmp/selftest-tg-fail.log 2>&1
same "a failed run sends one Telegram message" 1 \
    "$(grep -c 'Backup stale' "$tg_calls")"

# HTTP success and API success are separate facts. A proxy or misbehaving
# endpoint can return a non-2xx status with an `"ok": true` body; treating that
# as delivered hides the alert failure that this channel exists to report.
printf '#!/bin/sh\nprintf "%%s\\n" "{\\"ok\\":true}"\nprintf "%%s\\n" "500"\nexit 0\n' \
    > "$tg_dir/curl"
chmod 755 "$tg_dir/curl"
PATH="$tg_dir:$PATH" TELEGRAM_BOT_TOKEN='123456:selftest' \
    TELEGRAM_CHAT_ID='@selftest_channel' BACKUP_NOTIFY_ON_SUCCESS=true \
    /restic.sh backup >/tmp/selftest-tg-http500.log 2>&1
same "a Telegram notification requires HTTP 200" 1 \
    "$(grep -c 'Telegram notification failed (HTTP 500)' /tmp/selftest-tg-http500.log)"
same "a non-2xx response with ok=true is not reported as sent" 0 \
    "$(grep -c 'Telegram notification sent' /tmp/selftest-tg-http500.log)"

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

# An error page or proxy response can be much larger than the entire run log.
# Capture only a bounded tail, keeping the appended HTTP status and the API
# explanation while preventing one response from multiplying the log size or
# exhausting memory. The credentials at the tail prove redaction still runs
# after truncation.
tg_log_dir="$tg_dir/logs"
mkdir -p "$tg_log_dir"
chmod 777 "$tg_log_dir"
# shellcheck disable=SC2016  # the pattern must reach sed with its $ intact
tg_huge_log_limit="$(sed -n 's/^MAX_LOG_BYTES="\${RESTIC_LOG_MAX_BYTES:-\([0-9][0-9]*\)}".*$/\1/p' /restic.sh)"
case "$tg_huge_log_limit" in
    ''|*[!0-9]*)
        bad "could not read the log limit for the oversized Telegram response test"
        tg_huge_log_limit=262144
        ;;
esac
printf '#!/bin/sh\ndd if=/dev/zero bs=1024 count=1024 2>/dev/null | tr "\\000" x\nprintf "\\nrejected 123456:selftest @selftest_channel\\n401\\n"\n' \
    > "$tg_dir/curl"
chmod 755 "$tg_dir/curl"
seed_status 1
PATH="$tg_dir:$PATH" TELEGRAM_BOT_TOKEN='123456:selftest' \
    TELEGRAM_CHAT_ID='@selftest_channel' BACKUP_MAX_AGE=60 \
    RESTIC_LOG_DIR="$tg_log_dir" /restic.sh check-freshness \
    >/tmp/selftest-tg-huge.log 2>&1
tg_huge_rc=$?
tg_huge_run_log="$(find "$tg_log_dir" -maxdepth 1 -name '*.log' -type f -print -quit)"
same "an oversized Telegram response does not change the run status" 2 "$tg_huge_rc"
if [ -n "$tg_huge_run_log" ]; then
    tg_huge_log_bytes="$(wc -c < "$tg_huge_run_log")"
    if [ "$tg_huge_log_bytes" -le $(( tg_huge_log_limit + 4096 )) ]; then
        ok "an oversized Telegram response keeps the run log bounded (${tg_huge_log_bytes} bytes)"
    else
        bad "an oversized Telegram response grew the run log to ${tg_huge_log_bytes} bytes"
    fi
    same "an oversized Telegram response still records the HTTP status" 1 \
        "$(grep -c 'Telegram notification failed (HTTP 401)' "$tg_huge_run_log")"
    same "an oversized Telegram response still redacts the token" 0 \
        "$(grep -c '123456:selftest' "$tg_huge_run_log")"
    same "an oversized Telegram response still redacts the chat id" 0 \
        "$(grep -c '@selftest_channel' "$tg_huge_run_log")"
else
    bad "the oversized Telegram response test did not create a run log"
fi

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

# Repository commands can echo the configured endpoint or credentials in a
# transport error. The snapshots path used to bypass the bounded capture in
# run(), so a backend could both fill the container log and expose every
# secret it chose to repeat.
leak_stub_dir=/tmp/selftest-leak-stub
mkdir -p "$leak_stub_dir"
cat > "$leak_stub_dir/restic" <<'EOF'
#!/bin/sh
case "$*" in
    unlock) exit 0 ;;
    snapshots*)
        dd if=/dev/zero bs=1024 count=64 2>/dev/null | tr '\000' x
        printf '\nrepository=%s\npassword=%s\naws-access=%s\naws-secret=%s\nsmtp-password=%s\nsmtp-recipient=%s\ndomain=%s\n' \
            "$RESTIC_REPOSITORY" "$RESTIC_PASSWORD" "$AWS_ACCESS_KEY_ID" \
            "$AWS_SECRET_ACCESS_KEY" "$SMTP_PASSWORD" "$SMTP_TO" "$DOMAIN"
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$leak_stub_dir/restic"
leak_output=/tmp/selftest-secret-output.log
PATH="$leak_stub_dir:$PATH" RESTIC_LOG_MAX_BYTES=4096 \
    RESTIC_REPOSITORY=selftest-repository-secret \
    RESTIC_PASSWORD=selftest-restic-password \
    AWS_ACCESS_KEY_ID=selftest-aws-access \
    AWS_SECRET_ACCESS_KEY=selftest-aws-secret \
    SMTP_PASSWORD=selftest-smtp-password \
    SMTP_TO=selftest-recipient@invalid \
    DOMAIN=selftest-domain.invalid \
    /restic.sh snapshots > "$leak_output" 2>&1
leak_rc=$?
same "a successful repository query stays successful after output filtering" 0 "$leak_rc"
same "repository query output is bounded" 1 \
    "$([ "$(wc -c < "$leak_output")" -le 8192 ] && echo 1 || echo 0)"
same "repository query output is visibly redacted" 1 \
    "$(grep -q '<redacted>' "$leak_output" && echo 1 || echo 0)"
for leaked in selftest-repository-secret selftest-restic-password \
    selftest-aws-access selftest-aws-secret selftest-smtp-password \
    selftest-domain.invalid; do
    same "repository query output does not expose ${leaked}" 0 \
        "$(grep -Fc "$leaked" "$leak_output")"
done
multiline_password='selftest-password-first
selftest-password-second'
PATH="$leak_stub_dir:$PATH" RESTIC_LOG_MAX_BYTES=4096 \
    RESTIC_REPOSITORY=selftest-repository-secret \
    RESTIC_PASSWORD="$multiline_password" \
    /restic.sh snapshots > "$leak_output" 2>&1
same "a repository query with a multi-line password stays successful" 0 "$?"
same "repository output does not expose the first password line" 0 \
    "$(grep -Fc 'selftest-password-first' "$leak_output")"
same "repository output does not expose the second password line" 0 \
    "$(grep -Fc 'selftest-password-second' "$leak_output")"
rm -rf "$leak_stub_dir"
rm -f "$leak_output"

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

# Cleanup of a stale lock is a gate, not best effort. If `restic unlock` cannot
# establish a known lock state, the requested repository command must stop and
# say why instead of treating the unknown state as if cleanup had succeeded.
unlock_stub_dir="$(mktemp -d)"
unlock_calls=/tmp/selftest-unlock.calls
: > "$unlock_calls"
chmod 755 "$unlock_stub_dir"
chmod 666 "$unlock_calls"
unlock_real_restic="$(command -v restic)"
# shellcheck disable=SC2016  # generated stub, not shell expansion
{
    printf '#!/bin/sh\n'
    printf 'case "$1" in\n'
    printf '  unlock) printf "unlock\\n" >> "%s"; echo "injected unlock failure" >&2; exit 1 ;;\n' \
        "$unlock_calls"
    printf '  snapshots) printf "snapshots\\n" >> "%s"; exit 0 ;;\n' "$unlock_calls"
    printf '  *) exec "%s" "$@" ;;\n' "$unlock_real_restic"
    printf 'esac\n'
} > "$unlock_stub_dir/restic"
chmod 755 "$unlock_stub_dir/restic"

PATH="$unlock_stub_dir:$PATH" /restic.sh snapshots \
    >/tmp/selftest-unlock-fail.log 2>&1
unlock_status=$?
same "snapshots fails when stale-lock cleanup fails" 2 "$unlock_status"
same "the failed stale-lock cleanup is named" 1 \
    "$(grep -c 'Clear stale repository locks' /tmp/selftest-unlock-fail.log)"
same "the backend's unlock error is retained" 1 \
    "$(grep -c 'injected unlock failure' /tmp/selftest-unlock-fail.log)"
same "no repository command runs after a failed stale-lock cleanup" "unlock" \
    "$(cat "$unlock_calls")"
rm -rf "$unlock_stub_dir"
rm -f "$unlock_calls"

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

# A process already answering on the drill's port must not make a failed
# Vaultwarden boot look healthy. The sentinel is written before the boot starts,
# so accepting any unrelated HTTP 200 falsely reported a successful drill.
port_dir="$(mktemp -d /tmp/restic-port.XXXXXX)"
printf 'OK\n' > "$port_dir/alive"
printf '{\n\tauto_https off\n\tadmin off\n}\n:18081 {\n\troot * %s\n\tfile_server\n}\n' \
    "$port_dir" > "$port_dir/Caddyfile"
caddy run --config "$port_dir/Caddyfile" >"$port_dir/caddy.log" 2>&1 &
port_pid=$!
port_ready=0
for _ in $(seq 1 30); do
    if wget -qO- http://127.0.0.1:18081/alive >/dev/null 2>&1; then
        port_ready=1
        break
    fi
    sleep 0.1
done
if [ "$port_ready" = "1" ]; then
    /restic.sh restore-test >/tmp/selftest-port-collision.log 2>&1
    port_collision_rc=$?
    same "restore drill rejects an unrelated listener on its boot port" 2 "$port_collision_rc"
    same "restore drill reports the failed boot instead of a false pass" 0 \
        "$(grep -c 'kept the restored database' /tmp/selftest-port-collision.log)"
else
    bad "could not start the restore-drill port collision fixture"
fi
kill "$port_pid" 2>/dev/null || true
wait "$port_pid" 2>/dev/null || true
rm -rf "$port_dir"

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
    printf '      empty) printf \047%%s\\n\047 \047{"foo":1}\047; exit 0 ;;\n'
    printf '      leaky) printf \047repository=%%s\\n\047 "$RESTIC_REPOSITORY"; printf \047%%s\\n\047 \047{"foo":1}\047; exit 0 ;;\n'
    printf '      oversized) dd if=/dev/zero bs=1024 count=64 2>/dev/null | tr "\\000" x; printf "\\nrepository=%%s\\n" "$RESTIC_REPOSITORY"; printf \047%%s\\n\047 \047{"foo":1}\047; exit 0 ;;\n'
    printf '      huge) printf \047%%s\\n\047 \047{"total_size":18446744073709551616}\047; exit 0 ;;\n'
    printf '      *) echo "stats backend unavailable" >&2; exit 1 ;;\n'
    printf '    esac ;;\n'
    printf '  restore) printf started > /tmp/selftest-huge-restore-started; exit 0 ;;\n'
    printf '  *) exec "%s" "$@" ;;\n' "$real_restic"
    printf 'esac\n'
} > "$stats_stub_dir/restic"
chmod 755 "$stats_stub_dir/restic"
oversized_fixture_bytes="$(STATS_MODE=oversized "$stats_stub_dir/restic" stats 2>/dev/null | wc -c)"
same "the oversized stats fixture exceeds the configured cap" 1 \
    "$([ "$oversized_fixture_bytes" -gt 4096 ] && echo 1 || echo 0)"

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

PATH="$stats_stub_dir:$PATH" RESTIC_LOG_MAX_BYTES=4096 \
    RESTIC_REPOSITORY=selftest-repository-secret STATS_MODE=leaky \
    /restic.sh restore-test >/tmp/selftest-stats-leaky.log 2>&1
same "restore drill refuses a malformed stats response" 2 "$?"
same "malformed stats output is redacted" 0 \
    "$(grep -Fc 'selftest-repository-secret' /tmp/selftest-stats-leaky.log)"

PATH="$stats_stub_dir:$PATH" RESTIC_LOG_MAX_BYTES=4096 \
    RESTIC_REPOSITORY=selftest-repository-secret STATS_MODE=oversized \
    /restic.sh restore-test >/tmp/selftest-stats-oversized.log 2>&1
same "restore drill refuses an oversized stats response" 2 "$?"
same "oversized stats output is bounded" 1 \
    "$([ "$(wc -c < /tmp/selftest-stats-oversized.log)" -le 8192 ] && echo 1 || echo 0)"
same "oversized stats output is redacted" 0 \
    "$(grep -Fc 'selftest-repository-secret' /tmp/selftest-stats-oversized.log)"

rm -f /tmp/selftest-huge-restore-started
PATH="$stats_stub_dir:$PATH" STATS_MODE=huge /restic.sh restore-test \
    >/tmp/selftest-stats-huge.log 2>&1
same "restore drill refuses an overflowing snapshot size" 2 "$?"
same "an overflowing snapshot size is named" 1 \
    "$(grep -c 'unusable snapshot size' /tmp/selftest-stats-huge.log)"
same "an overflowing snapshot size never starts a restore" 0 \
    "$([ -e /tmp/selftest-huge-restore-started ] && echo 1 || echo 0)"

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
printf '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted on\\nx 1 1 9999999999999999 100%% /\\n"\n' \
    > "$df_stub_dir/df"
chmod 755 "$df_stub_dir/df"
PATH="$df_stub_dir:$PATH" /restic.sh restore-test \
    >/tmp/selftest-drill-df-overflow.log 2>&1
same "restore drill refuses an overflowing free-space reading" 2 "$?"
same "an overflowing free-space reading is reported as unreadable" 1 \
    "$(grep -c 'Unable to read free space' /tmp/selftest-drill-df-overflow.log)"
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
