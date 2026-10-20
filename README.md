# 🔐 Vaultwarden (Fly.io Edition)

[![Fly.io](https://img.shields.io/badge/Fly.io-Deploy-purple?style=for-the-badge&logo=flydotio)](https://fly.io)
[![Docker](https://img.shields.io/badge/Docker-ghcr.io-blue?style=for-the-badge&logo=docker)](https://ghcr.io/webees/vaultwarden)
[![Vaultwarden](https://img.shields.io/badge/Vaultwarden-Latest-green?style=for-the-badge)](https://github.com/dani-garcia/vaultwarden)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)](LICENSE)

> Production-ready Vaultwarden on Fly.io with Caddy reverse proxy, static process supervision, and automated Restic backups to Cloudflare R2.

## ✨ Features

| Component | Description |
| :--- | :--- |
| **Vaultwarden** | Self-hosted Bitwarden compatible server |
| **Caddy** | Reverse proxy with security headers and IP forwarding |
| **Process supervision** | The entrypoint runs Vaultwarden, Caddy and Supercronic as an unprivileged three-process table |
| **Supercronic** | Cron daemon for automated tasks |
| **Restic** | Encrypted incremental backups to S3/R2 |
| **msmtp** | Email notifications for system alerts |

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────┐
│              Fly.io Edge (TLS termination)              │
└───────────────────────────┬─────────────────────────────┘
                            │ :443
┌───────────────────────────▼─────────────────────────────┐
│                        Caddy                            │
│          (reverse proxy, security headers)              │
└───────────────────────────┬─────────────────────────────┘
                            │ :8080
┌───────────────────────────▼─────────────────────────────┐
│                     Vaultwarden                         │
│                  (SQLite + Rocket)                      │
└─────────────────────────────────────────────────────────┘
         │
         │ Hourly backup
         ▼
┌─────────────────────────────────────────────────────────┐
│                  Restic → Cloudflare R2                 │
│          (7 daily, 4 weekly, 3 monthly, 3 yearly)       │
└─────────────────────────────────────────────────────────┘
```

## 🚀 Quick Start

### 1. Initialize Application

```bash
# Login to Fly.io
fly auth login

# Create application
fly apps create vaultwarden

# fly.toml deliberately omits the app name (it is personal data), so point
# flyctl at your app once. Every `fly ...` command in this README relies on it.
export FLY_APP=vaultwarden

# Create the local secret file from the template, then fill in every value
cp .env.example .env
fly secrets import < .env

# Create storage volume
fly volumes create app_data --region sin --size 1   # must match primary_region in fly.toml
```

> `.env` is git ignored on purpose; only the placeholder template `.env.example` is committed. Real
> values belong in Fly secrets, so a working tree stays clean after `cp .env.example .env`.

### 2. Required Secrets Configuration

```bash
# Domain configuration (Multiple domains: "a.com b.com")
fly secrets set CADDY_DOMAINS="vault.example.com"
fly secrets set DOMAIN="https://vault.example.com"

# Restic / S3 backup settings
fly secrets set RESTIC_PASSWORD="your-secure-password"
fly secrets set RESTIC_REPOSITORY="s3:your-account-id.r2.cloudflarestorage.com/vaultwarden"
fly secrets set AWS_ACCESS_KEY_ID="your-r2-id"
fly secrets set AWS_SECRET_ACCESS_KEY="your-r2-key"

# SMTP notification settings
fly secrets set SMTP_HOST="smtp.example.com"
fly secrets set SMTP_PORT="587"
fly secrets set SMTP_FROM="sender@example.com"
fly secrets set SMTP_TO="admin@example.com"
fly secrets set SMTP_USERNAME="sender@example.com"
fly secrets set SMTP_PASSWORD="app-specific-password"

# SMTP_FROM defaults to SMTP_TO when it is left unset, so the app still boots
# when only SMTP_HOST and SMTP_TO are set for the monthly alert email.

# Optional hardening. Registration is closed unless SIGNUPS_ALLOWED is "true",
# and the admin panel stays disabled while ADMIN_TOKEN is unset.
fly secrets set SIGNUPS_ALLOWED="false"
fly secrets set SHOW_PASSWORD_HINT="false"
# fly secrets set ADMIN_TOKEN="..."   # only when /admin has to be reachable

# Anything saved through the /admin panel is written to /data/config.json, and
# that file outranks the environment. `admin_token`, the `smtp_*` keys and
# `signups_allowed` are the ones that usually drift: `fly secrets set` changes
# nothing while the key sits in /data/config.json. The entrypoint keeps that
# file at 0600 and logs which secret keys it found, without printing their
# values, so the override is visible in `fly logs`; either change the setting in
# /admin as well, or drop the key from /data/config.json and restart.

# Optional dead-man's-switch, pinged after every backup run (e.g. healthchecks.io)
fly secrets set HEALTHCHECK_URL="https://hc-ping.com/your-uuid"

# Optional: notify after every successful backup. Telegram only, like every
# other hourly alert, so the mailbox stays reserved for the monthly check.
fly secrets set BACKUP_NOTIFY_ON_SUCCESS="true"

# Optional Telegram notifications. The bot must be able to post to the target.
# A channel or group accepts its @username; a private chat only accepts the
# numeric chat id (send /start to the bot, then read it from
# https://api.telegram.org/bot<token>/getUpdates).
fly secrets set TELEGRAM_BOT_TOKEN="123456:replace-me"
fly secrets set TELEGRAM_CHAT_ID="-1001234567890"   # or "@your_channel"

# Optional tuning (defaults shown)
fly secrets set SMTP_TIMEOUT="15"        # seconds msmtp may wait for the relay
fly secrets set VERIFY_SUBSET="10%"      # data slice read back by the monthly verify
fly secrets set VERIFY_RETRY_LOCK="10m"  # how long the monthly verify waits for a running backup's lock
fly secrets set SUPERVISE_RESTART_DELAY="5"  # seconds before a crashed caddy/scheduler restarts
fly secrets set RESTIC_QUICK_TIMEOUT="60"    # seconds for init/check/cat operations
fly secrets set RESTIC_LONG_TIMEOUT="1800"   # seconds for backup/restore/prune
fly secrets set RESTIC_LOG_DIR="/data/restic-logs"  # persistent backup logs
fly secrets set RESTIC_LOG_MAX_BYTES="262144"       # cap each log file at 256 KiB
fly secrets set BACKUP_MAX_USAGE_PERCENT="85"       # alert when /data is this full
fly secrets set RESTIC_LOG_DIR_MAX_BYTES="10485760" # cap the log directory at 10 MiB
```

### 3. Deploy

```bash
fly deploy
```

## 🔢 Versions & Upgrades

Every upstream dependency is pinned in the `Dockerfile`: `VAULTWARDEN_VERSION` + `VAULTWARDEN_DIGEST` and
`SUPERCRONIC_VERSION` + checksums. The `dependency_updates` workflow
runs every two hours, resolves each one from Docker Hub and the GitHub Releases API, opens a PR that lists the pin
changes plus any pending Alpine package upgrades, builds the patched image, and validates the Caddyfile.
When only Alpine packages inside the pinned base image have newer builds, no pin changes, so the workflow
dispatches the image build directly instead of opening an empty PR.
The same workflow then publishes a timestamped image and rolls that digest out to Fly by passing `--image`
explicitly. `fly.toml` deliberately carries no image pin: a second copy of "what is
running" is exactly what went stale before. Running `fly deploy` by hand builds this repository's pinned
`Dockerfile` instead.

`main` requires the `validate` check, so the dependency workflow arms auto-merge rather than merging
directly: the bump lands only after shellcheck, the workflow lint, the self tests, the image build and the
runtime smoke test all pass.

Every published build also receives a timestamp tag in `Asia/Shanghai`, for example `202610180615`.
The build workflow is serialized globally, so two runs never publish the same timestamp concurrently.
Only commits that can change the image rebuild it: `.gitignore`, `README.md`, `LICENSE`, `.github/**` and
`tests/**` are skipped, while `fly.toml` and everything the `Dockerfile` copies always rebuild and redeploy.
Timestamp tags older than 30 days are removed by the nightly `ghcr_cleanup` workflow. GitHub stops
scheduled workflows silently, so the build expires them as well whenever that schedule has not run for a
week; the run log says which path did the work.

```bash
# Inspect the newest published image. The build workflow already rolled this
# digest out with `fly deploy --image`; fly.toml itself keeps no image pin.
docker buildx imagetools inspect ghcr.io/webees/vaultwarden:latest

# Bump VAULTWARDEN_VERSION, then build and roll out this Dockerfile by hand
fly deploy
fly releases            # list previous releases
fly releases rollback   # roll back to the previous image
```

## 💾 Backup & Recovery

| Item | Behaviour |
| :--- | :--- |
| Schedule | `@hourly` backup plus a monthly integrity check and a monthly restore drill, defined in `config/crontab` |
| Data | `/data` volume, excluding the live `db.*` SQLite files, the rebuildable `icon_cache`, `backup-status.txt`, and whichever directory `RESTIC_LOG_DIR` points to under `/data` |
| Consistency | `sqlite3 .backup` hot copy to `/data/backup.bak` plus `PRAGMA integrity_check` before upload |
| Retention | `--keep-hourly 24 --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --keep-yearly 3 --prune` |
| Alerts | Every hourly alert (backup, staleness, volume) goes to Telegram; the monthly integrity check and the monthly restore drill also email, because they cannot repeat 24 times a day. A success notification is opt-in with `BACKUP_NOTIFY_ON_SUCCESS=true`, and an optional `HEALTHCHECK_URL` ping covers the backup, verify and restore-drill runs, using the `/fail` URL when the run fails. The dependency workflow also runs `/restic.sh check-freshness` against the live app on its schedule and after every build, so a fully silent scheduler still fails an external workflow and GitHub notifies the repository owner |

```bash
fly ssh console -C "/restic.sh backup"         # manual backup
fly ssh console -C "/restic.sh snapshots"      # list snapshots
fly ssh console -C "/restic.sh verify"         # read back a data slice from the repository
fly ssh console -C "/restic.sh restore-test"   # restore latest snapshot to /tmp and validate it
fly ssh console -C "/restic.sh check-disk"     # how full the data volume is
fly ssh console -C "RESTORE_CONFIRM=yes /restic.sh restore <id>"  # overwrite the live /data
```

`/restic.sh check-freshness` runs at `:45` every hour and alerts over Telegram when no backup has succeeded for
`BACKUP_MAX_AGE` seconds (default two hours). It catches a backup that silently stops working while the
scheduler is still alive. An unreadable marker, a missing `last_success` field, a non-numeric timestamp, or a
timestamp from the future is reported instead of being read as a fresh backup. The malformed file is left in
place for diagnosis. A scheduler that has stopped firing entirely is caught by the external watchdog in
`.github/workflows/dependency_updates.yml`: it runs the same check against the live app every two hours and
after every build. A failure fails that workflow, so GitHub emails the repository owner even when Telegram
is the channel that broke. `HEALTHCHECK_URL` remains an optional third channel for a dedicated
dead-man's-switch service.

`/restic.sh check-disk` runs at `:35` every hour and alerts over Telegram when `/data` is at least
`BACKUP_MAX_USAGE_PERCENT` full (default 85). Attachments, the icon cache and the database all live on
that volume and it is grown by migrating the data rather than in place, so this is the warning that leaves
time to do that deliberately. A reading that never arrives is reported as a failure rather than a healthy
volume. The guard and the monthly `verify` are not backup runs, so neither clears the `state=running`
marker a live backup leaves in `/data/backup-status.txt`: that marker is what the `:45` freshness check
reads to tell a backup that started but never finished, and the guard runs before it.

> `restore` writes straight over the running instance's `/data`. When you only want to verify a snapshot,
> run `restore-test` instead: it checks free space, restores into a temporary directory, verifies
> `backup.bak` and `rsa_key.pem`, runs SQLite `PRAGMA integrity_check`, and cold-boots Vaultwarden against
> the restored database on loopback with a temporary config that forces registration off, without touching
> the live volume. The in-place restore refuses to run unless
> `RESTORE_CONFIRM=yes` is set, because Vaultwarden keeps `db.sqlite3` open while it runs.
>
> Losing `RESTIC_PASSWORD` makes every snapshot permanently unreadable. Keep a copy outside Fly as well.
>
> To rotate it, add the new password as an extra key first (`restic key add`), then update the secret.
> Replacing the secret without adding a key first locks you out of every existing snapshot.

### Recovering in place

A snapshot never contains the live `db.*` files: the consistent database travels as `/data/backup.bak`.
`restore` puts the keys, the attachments and that hot copy back, but swapping the database under a
running process is not safe, so the swap is armed with a marker and applied by the entrypoint before
Vaultwarden opens the database:

```bash
fly ssh console -C "RESTORE_CONFIRM=yes /restic.sh restore <id>"  # keys, attachments, backup.bak
fly ssh console -C "touch /data/restore-pending"                  # arm the database swap
fly apps restart                                                  # entrypoint swaps, then starts
```

The swap is refused, and the marker kept, when `/data/backup.bak` is missing or is not a readable
database: the machine keeps running on the database it already has, and the reason is in `fly logs`.
Fix the file and restart to retry, instead of booting on a database Vaultwarden cannot open.

`/restic.sh restore-test` runs the same restore inside a temporary directory, puts `backup.bak` where
Vaultwarden looks and boots against it, so the drill fails when the database or the swap is wrong. It runs
monthly, an hour after the integrity check, and a failure emails the operator, notifies Telegram and
records `state=failed` in `/data/backup-status.txt`, so a snapshot that stops being restorable is not
discovered for the first time during a real recovery.

## 🧯 Troubleshooting

| Symptom | Cause / fix |
| :--- | :--- |
| Cron job logs `exit status 127`, no backup ever runs | `/restic.sh` starts with `#!/bin/bash`; the image must keep the `bash` package |
| Log line `Another backup is already running` | A manual run overlapped the hourly run; the newer run exits 3 on purpose |
| Log line `[crontab] exited with status` | The scheduler crashed and was restarted by the static process table in `/services.sh`; check the lines above it |
| Client IPs look like Cloudflare edge addresses | Caddy trusts `CF-Connecting-IP` only when the edge-controlled `Fly-Client-IP` is in the static range list in `config/cloudflare_ips.caddy`; update that file from Cloudflare's official IPv4/IPv6 lists when the ranges change |
| A changed secret has no effect | Vaultwarden logs `The following environment variables are being overridden by the config.json file` and lists them. `/data/config.json` was written by the admin panel and outranks the environment; `admin_token`, the `smtp_*` keys and `signups_allowed` are the usual offenders. The entrypoint also logs `WARNING: /data/config.json overrides these environment variables` with the secret key names and keeps the file at 0600. Change that setting in `/admin`, or drop the key from `/data/config.json` and restart so the secret applies |
| No alert arrived after an hourly job failed | The hourly jobs (`backup`, `check-freshness`, `check-disk`) report through Telegram, not email. The run log in `/data/restic-logs` records `Telegram notification failed (HTTP N)` or `(curl exit N)` followed by the API's own explanation with the token replaced by `<redacted>`, so a wrong `TELEGRAM_CHAT_ID` reads differently from an unreachable API. Email is sent only by the monthly `verify`, which records `Alert email sent` or `Alert email failed (exit N)`; mail is skipped entirely when `SMTP_TO` is unset |
| Container exits with `SMTP values must not contain newlines` | One of the `SMTP_*` secrets contains a line break; `msmtprc` is line-based, so a newline would inject extra directives. Remove the break and redeploy |
| Backup logs disappear after a redeploy | Set `RESTIC_LOG_DIR=/data/restic-logs`; the default is now on the persistent volume |
| Backup log grows unexpectedly | Logs are capped at `RESTIC_LOG_MAX_BYTES` (default 256 KiB), the directory is capped at `RESTIC_LOG_DIR_MAX_BYTES` (default 10 MiB), and files older than 10 hours are removed. A failed per-file rotation is reported even while the directory total remains below its cap |
| Backup log directory cannot be trimmed | The run logs `Warning: log directory holds … could not be trimmed`, records `log trim failed` in `/data/backup-status.txt`, and sends a failure heartbeat when `HEALTHCHECK_URL` is set; free space or fix ownership under `/data/restic-logs` |
| Backup exits with `Cannot record backup start state` or `Cannot record backup completion state` | `/data/backup-status.txt` is not a writable regular file. The backup job fails with exit 2 and sends its normal failure alert instead of reporting a false success; repair the path type and owner under `/data` before retrying |
| Container exits with `… must be a positive integer` | One of `RESTIC_LOG_MAX_BYTES`, `RESTIC_LOG_DIR_MAX_BYTES`, `RESTIC_QUICK_TIMEOUT`, `RESTIC_LONG_TIMEOUT`, `BACKUP_MAX_AGE` or `BACKUP_MAX_USAGE_PERCENT` is zero or not a number; set a positive integer (the usage limit also has to be 100 or less) |
| Repository command exits with `RESTIC_PASSWORD not set` | `backup`, `snapshots`, `restore`, `restore-test` and `verify` require the secret. `check-freshness` and `check-disk` deliberately continue without it so monitoring is not disabled by a missing repository credential |
| Run log says `/data is …% full` | The volume is past `BACKUP_MAX_USAGE_PERCENT` (default 85). Move `icon_cache` aside, trim attachments, or migrate to a larger Fly volume with `fly volumes create` + `fly machine update`; the hourly backup keeps working until the volume is actually full |
| Caddy exited and the proxy stopped responding | The static process table in `/services.sh` restarts Caddy in place; if the whole container exits, Fly's `on-failure` restart policy brings the machine back (10 retries), while a failing `/alive` check takes it out of service |

## 🛠️ Management & Operations

### Deployment CLI

```bash
fly status                     # Check application status
fly logs                       # View real-time logs
fly ssh console                # Access container shell
fly apps restart               # Restart all instances
```

### Backup Operations (via SSH)

```bash
/restic.sh backup              # Run manual backup
/restic.sh snapshots           # List all snapshots
/restic.sh restore-test        # Restore latest snapshot into /tmp and validate
/restic.sh restore <id>        # Restore from specific snapshot
```

### Log Inspection

```bash
cat /data/restic-logs/*.log     # Check persisted backup logs
cat /data/restic-logs/msmtp.log # Delivery log written by the alert mailer
fly logs                        # Container output, including mailer errors
```

### Verification

The host-side suites are `tests/selftest.sh` (the helper scripts; no network, no restic repository and no
production access) and `tests/runtime_smoke.py` (boots the image). The image ships no Python on purpose, so
`tests/image_selftest.sh` stays shell; the snippets a Python test hands to `sh` in a container are single
commands.

```bash
shellcheck scripts/*.sh scripts/entrypoint/*.sh tests/*.sh # Static analysis for every helper and test script
python3 -m py_compile tests/*.py  # Compile check for the host-side test scripts
tests/selftest.sh                 # static process model, dependency resolver and workflow failure paths
tests/runtime_smoke.py <image>    # Boot the image: /alive, the non-root stack, the backup paths and a real SMTP delivery
scripts/deps.sh base             # Resolve the upstream Vaultwarden version + digest
scripts/deps.sh tools            # Resolve supercronic and recompute checksums
scripts/deps.sh compare ...      # Compare resolved values against the Dockerfile pins
scripts/deps.sh apk <image>      # List Alpine packages with a pending upgrade
docker build -t vaultwarden:local .
docker run --rm --entrypoint caddy vaultwarden:local validate --config /Caddyfile --adapter caddyfile
```

## 🔐 Security Headers

The Caddy configuration automatically applies the following security posture:
- **HSTS**: `Strict-Transport-Security` (1 year)
- **Clickjacking**: `X-Frame-Options DENY`
- **MIME Sniffing**: `X-Content-Type-Options nosniff`
- **XSS Protection**: `X-XSS-Protection 1; mode=block`
- **Privacy**: `Referrer-Policy strict-origin-when-cross-origin`
- **Indexing**: `X-Robots-Tag noindex, nofollow`
- **Permissions**: `Permissions-Policy` (camera, microphone, geolocation, payment disabled)
- **Fingerprinting**: `Server`, `X-Powered-By` and `Last-Modified` are stripped

Hosts are denied by default: only the domains listed in `CADDY_DOMAINS` are served (`/alive` stays open for
Fly health checks). The admin panel at `/admin` is served on allowed hosts and remains protected by
`ADMIN_TOKEN`, so treat that token as a high-value secret. Caddy access logs strip `Authorization`,
`Cookie`, `Proxy-Authorization`, `X-Api-Key`, `X-Auth-Token`, `CF-Access-Jwt-Assertion`,
`X-Forwarded-For`, `X-Real-IP`, and `Fly-Client-IP` before writing to stdout. Query strings are
replaced with `?redacted`, because one-time credentials and addresses do not belong in request logs;
the path remains visible for diagnosis.

The container runs as the unprivileged `vaultwarden` user. `/entrypoint.sh` orchestrates three small modules
for filesystem setup, pending restores and SMTP configuration, then drops privileges with `su-exec` before
starting `/services.sh`, which owns the static three-process table. Because Vaultwarden can write under
`/data`, the root entrypoint never follows links for its reserved status or log paths: it replaces unsafe
links with private files/directories, and it refuses to chmod or chown a symlinked `config.json`.

## 📝 License

Distributed under the [MIT License](LICENSE).

---
🚀 Optimized for Fly.io by **[WeBees](https://github.com/webees)**
