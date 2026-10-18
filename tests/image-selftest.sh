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
for proc in overmind caddy supercronic vaultwarden; do
    if ! pid="$(pid_of "$proc")"; then
        bad "$proc is not running"
        continue
    fi
    uid="$(awk '/^Uid:/ {print $2}' "/proc/$pid/status")"
    same "$proc runs as vaultwarden" "$vault_uid" "$uid"
done

same "/etc/msmtprc is 0600" 600 "$(stat -c %a /etc/msmtprc)"
same "/etc/msmtprc belongs to vaultwarden" vaultwarden "$(stat -c %U /etc/msmtprc)"

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

# A second run must skip instead of fighting for the repository lock.
exec 9>/data/restic-logs/backup.lock
if flock -n 9; then
    /restic.sh backup >/tmp/selftest-lock.log 2>&1
    same "a concurrent run exits 3 instead of blocking" 3 "$?"
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

# the monthly integrity check reads a slice back out of the repository
VERIFY_SUBSET=1% /restic.sh verify >/tmp/selftest-verify.log 2>&1
same "verify reads a data slice back" 0 "$?"

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

echo
report "image self tests"
