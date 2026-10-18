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
smtp_env() { env -u SMTP_HOST -u SMTP_TO -u SMTP_FROM "$@" /entrypoint.sh env 2>/dev/null; }
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
SMTP_PASSWORD=***REMOVED***
same "an SMTP password with shell metacharacters is written verbatim" \
    "${smtp_secret}" "$(sed -n 's/^password //p' /etc/msmtprc)"

# A newline in any SMTP value would inject extra msmtprc directives, so it has
# to be refused before the file is written.
smtp_env SMTP_HOST=smtp.example.com SMTP_TO=ops@example.com \
SMTP_PASSWORD=***REMOVED***
lines' >/dev/null 2>&1
same "an SMTP value containing a newline is rejected" 1 "$?"

# ── restic.sh ────────────────────────────────────────────────────────────────
echo "--- restic.sh"
export RESTIC_PASSWORD=selftest
export RESTIC_REPOSITORY=/tmp/selftest-repo
mkdir -p "$RESTIC_REPOSITORY"
chown vaultwarden:vaultwarden "$RESTIC_REPOSITORY"
rm -rf /tmp/restic-restore.* /tmp/restic-boot.*

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

# An alert has to record whether it was actually delivered: the mailer's stderr
# is not part of the run log, so "no email arrived" is otherwise undiagnosable.
seed_status 1
SMTP_TO=ops@example.com BACKUP_MAX_AGE=60 /restic.sh check-freshness \
    >/tmp/selftest-mailfail.log 2>&1
same "an undeliverable alert is recorded in the log" 1 \
    "$(grep -c 'Alert email failed' /tmp/selftest-mailfail.log)"

mail_stub=/tmp/selftest-mailok
mkdir -p "$mail_stub"
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$mail_stub/mail"
chmod +x "$mail_stub/mail"
seed_status 1
PATH="$mail_stub:$PATH" SMTP_TO=ops@example.com BACKUP_MAX_AGE=60 \
    /restic.sh check-freshness >/tmp/selftest-mailok.log 2>&1
same "a delivered alert is recorded in the log" 1 \
    "$(grep -c 'Alert email sent' /tmp/selftest-mailok.log)"
rm -rf "$mail_stub"

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

# A backend that never answers must be killed by the command timeout and
# recorded as a failure, instead of holding the lock until the next run.
stub_dir=/tmp/selftest-stub
mkdir -p "$stub_dir"
printf '#!/bin/sh\nsleep 300\n' > "$stub_dir/restic"
chmod +x "$stub_dir/restic"
seed_status "$(date -u +%s)"
hang_start="$(date -u +%s)"
PATH="$stub_dir:$PATH" RESTIC_QUICK_TIMEOUT=1 RESTIC_LONG_TIMEOUT=1 \
RESTIC_REPOSITORY=***REMOVED***
hang_status=$?
hang_elapsed=$(( $(date -u +%s) - hang_start ))
same "a hung backend exits 2" 2 "$hang_status"
if [ "$hang_elapsed" -lt 30 ]; then
    ok "the command timeout killed the hung backend in ${hang_elapsed}s"
else
    bad "the hung backend was not killed (${hang_elapsed}s)"
fi
same "a hung backend is recorded as failed" "failed" \
    "$(sed -n 's/^state=//p' /data/backup-status.txt)"
rm -rf "$stub_dir"

# The run above left stub children alive. They must not have inherited the
# backup lock: one that outlives the run would block every later backup, and
# those exits are treated as an intentional concurrent run, so nobody alerts.
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

# the guard is only useful if the scheduler actually calls it
if grep -q 'check-freshness' /crontab; then
    ok "the freshness guard is scheduled in /crontab"
else
    bad "the freshness guard is not scheduled in /crontab"
fi

/restic.sh restore-test >/tmp/selftest-drill.log 2>&1
same "restore drill succeeds" 0 "$?"
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

# restore overwrites /data on purpose, so it runs last and the container is
# thrown away afterwards.
/restic.sh restore latest >/tmp/selftest-restore.log 2>&1
same "restore writes the snapshot back" 0 "$?"
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
