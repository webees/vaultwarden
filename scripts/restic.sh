#!/bin/sh

# catch the error in case first pipe command fails (but second succeeds)
set -o pipefail

# turn on traces, useful while debugging but commented out by default
# set -o xtrace

EMAIL_SUBJECT_PREFIX="[Restic]"
LOG="/var/log/restic/$(date +\%Y\%m\%d\%H\%M\%S).log"

mkdir -p /var/log/restic/

if [ -n "$SMTP_TO" ]; then
cat << EOF > /etc/msmtprc
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log

account default
host $SMTP_HOST
port $SMTP_PORT
from $SMTP_FROM
user $SMTP_USERNAME
password $SMTP_PASSWORD
EOF
fi

# e-mail notification
function email() {
  if [ -n "$SMTP_TO" ]; then
      sed -e 's/\x1b\[[0-9;]*m//g' "${LOG}" | mail -s "${EMAIL_SUBJECT_PREFIX} ${1}" ${SMTP_TO}
  fi
}

function log() {
    "$@" 2>&1 | tee -a "$LOG"
}

# ###############################################################################
# colorized echo helpers                                                        #
# taken from: https://github.com/atomantic/dotfiles/blob/master/lib_sh/echos.sh #
# ###############################################################################

ESC_SEQ="\x1b["
COL_RED=$ESC_SEQ"31;01m"
COL_BLUE=$ESC_SEQ"34;01m"
COL_GREEN=$ESC_SEQ"32;01m"
COL_YELLOW=$ESC_SEQ"33;01m"
COL_RESET=$ESC_SEQ"39;49;00m"

function ok() {
    log echo -e "$COL_GREEN[OK]$COL_RESET $1"
}

function running() {
    log echo -en "$COL_BLUE ⇒ $COL_RESET $1..."
}

function warn() {
    log echo -e "$COL_YELLOW[WARNING]$COL_RESET $1"
}

function error() {
    log echo -e "$COL_RED[ERROR]$COL_RESET $1"
    log echo -e "$2"
}

function email_and_exit_on_error() {
    output=$(eval $1 2>&1)
    if [ $? -ne 0 ]; then
        error "$2" "$output"
        email "$2"
        exit 2
    fi
}

# ##############
# backup steps #
# ##############

restic unlock
restic cat config

if [ $? -ne 0 ]; then
    warn "Restic repo not ready"
    running "Restic init"
    email_and_exit_on_error "restic init" "Repo init failed"
    ok
fi

running "Backup SQLite"
email_and_exit_on_error "sqlite3 /data/db.sqlite3 '.backup /data/backup.bak'" "SQLite backup failed"
ok

running "SQLite Check"
email_and_exit_on_error "sqlite3 /data/backup.bak 'PRAGMA integrity_check'" "SQLite check failed"
ok

running "Restic Backup"
email_and_exit_on_error "restic backup --verbose --exclude='db.*' /data" "Restic backup failed"
ok

running "Restic Check"
email_and_exit_on_error "restic check" "Restic check failed"
ok

running "Restic Forget"
email_and_exit_on_error "restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --keep-yearly 3 --prune" "Restic forget failed"
ok

find /var/log/restic/ -name "*.log" -type f -mmin +600 -delete
