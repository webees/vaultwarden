#!/bin/bash

# A snapshot never carries the live db.* files: the consistent database travels
# as backup.bak. Swapping it in has to happen while Vaultwarden is not running,
# so `restore` arms the swap with a marker and this applies it before the app
# opens the database on the next start.
#
# Every failure here keeps the existing database, keeps the marker so the
# operator can fix the file and restart, and lets the app start: exiting would
# crash-loop the machine on a restore that cannot be applied.
apply_pending_restore() {
    local new=/data/db.sqlite3.new backup=/data/backup.bak sidecar
    # This function runs as root before the application starts. A link in the
    # writable data volume must never make the restore input resolve outside it.
    if [ -L "$backup" ]; then
        echo "refusing symlinked /data/backup.bak; leaving the database alone" >&2
        return 0
    fi
    if [ ! -f "$backup" ]; then
        echo "restore-pending is set but /data/backup.bak is missing; leaving the database alone" >&2
        return 0
    fi
    # A hot copy that is not a database would replace a working one with
    # something Vaultwarden cannot open at all.
    if ! sqlite3 "$backup" 'PRAGMA integrity_check' 2>/dev/null | grep -qx ok; then
        echo "restore-pending is set but /data/backup.bak is not a readable database; leaving the database alone" >&2
        return 0
    fi
    # The old sidecars must be removable without following links. Reject
    # directories, FIFOs, sockets and devices before replacing the database so
    # a malformed sidecar cannot turn the post-swap cleanup into a failed boot.
    for sidecar in /data/db.sqlite3-wal /data/db.sqlite3-shm; do
        if [ ! -L "$sidecar" ] && [ ! -f "$sidecar" ] && [ -e "$sidecar" ]; then
            echo "restore-pending is set but ${sidecar} is not a regular file; leaving the database alone" >&2
            return 0
        fi
    done
    # Write the replacement next to the live file and rename it into place: the
    # old rm-then-cp left a window with no database at all, so a failure in
    # between (or a crash) let Vaultwarden start on a fresh empty one.
    # The scratch name is reserved by this restore path. A directory or other
    # stale object left by the application must not make the root entrypoint
    # abort before it can keep the live database and let the app start.
    if ! rm -rf -- "$new"; then
        echo "could not clear the reserved restore scratch path; leaving the database alone" >&2
        return 0
    fi
    if ! cp "$backup" "$new"; then
        echo "could not copy /data/backup.bak into place; leaving the database alone" >&2
        rm -f "$new"
        return 0
    fi
    # A failed chown belongs to the same class as a failed copy: the machine
    # keeps the database it has and starts. Left unguarded, `set -e` aborted the
    # entrypoint right here, so a restore that could not be applied crash-looped
    # the machine - the opposite of what this function promises.
    if ! chown vaultwarden:vaultwarden "$new"; then
        echo "could not take ownership of the restored database; leaving the database alone" >&2
        rm -f "$new"
        return 0
    fi
    # Install the replacement before touching the old sidecars. The rename is
    # atomic, so a failure here leaves the live database and the write-ahead log
    # that belongs to it exactly as they were. Deleting the log first threw away
    # the transactions that were only in it whenever the rename then failed,
    # which is the opposite of "leaving the database alone".
    if ! mv -f "$new" /data/db.sqlite3; then
        echo "could not replace /data/db.sqlite3; leaving the database alone" >&2
        rm -f "$new"
        return 0
    fi
    # The old write-ahead log belongs to the database that was just replaced and
    # must not be replayed on top of the new one. The preflight above allows only
    # regular files, symlinks or missing paths here, so rm removes a link itself
    # and never follows it. Nothing opens the database between the rename and
    # this line, and a crash in between leaves the marker set for a retry.
    rm -f /data/db.sqlite3-wal /data/db.sqlite3-shm
    rm -f /data/restore-pending
    echo "Applied the pending restore: /data/backup.bak is now the live database" >&2
}
