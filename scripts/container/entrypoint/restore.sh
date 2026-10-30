#!/bin/bash
# Container runtime pending-restore handling.

# A pending restore never removes the live database or crash-loops startup.
apply_pending_restore() {
    local new=/data/db.sqlite3.new backup=/data/backup.bak sidecar integrity
    if [ -L "$backup" ]; then
        echo "refusing symlinked /data/backup.bak; leaving the database alone" >&2
        return 0
    fi
    if [ ! -f "$backup" ]; then
        echo "restore-pending is set but /data/backup.bak is missing; leaving the database alone" >&2
        return 0
    fi
    if ! integrity="$(sqlite3 "$backup" 'PRAGMA integrity_check' 2>/dev/null)" \
        || [ "$integrity" != ok ]; then
        echo "restore-pending is set but /data/backup.bak is not a readable database; leaving the database alone" >&2
        return 0
    fi
    if [ -L /data/db.sqlite3 ] \
        || { [ -e /data/db.sqlite3 ] && [ ! -f /data/db.sqlite3 ]; }; then
        echo "restore-pending is set but /data/db.sqlite3 is not a regular file; leaving the database alone" >&2
        return 0
    fi
    for sidecar in /data/db.sqlite3-journal /data/db.sqlite3-wal /data/db.sqlite3-shm; do
        if [ ! -L "$sidecar" ] && [ ! -f "$sidecar" ] && [ -e "$sidecar" ]; then
            echo "restore-pending is set but ${sidecar} is not a regular file; leaving the database alone" >&2
            return 0
        fi
    done
    if ! rm -rf -- "$new"; then
        echo "could not clear the reserved restore scratch path; leaving the database alone" >&2
        return 0
    fi
    if ! cp "$backup" "$new"; then
        echo "could not copy /data/backup.bak into place; leaving the database alone" >&2
        rm -f "$new"
        return 0
    fi
    if ! chown vaultwarden:vaultwarden "$new"; then
        echo "could not take ownership of the restored database; leaving the database alone" >&2
        rm -f "$new"
        return 0
    fi
    if ! mv -f "$new" /data/db.sqlite3; then
        echo "could not replace /data/db.sqlite3; leaving the database alone" >&2
        rm -f "$new"
        return 0
    fi
    rm -f /data/db.sqlite3-journal /data/db.sqlite3-wal /data/db.sqlite3-shm
    rm -f /data/restore-pending
    echo "Applied the pending restore: /data/backup.bak is now the live database" >&2
}
