# 🔐 Vaultwarden (Fly.io Edition)

[![Fly.io](https://img.shields.io/badge/Fly.io-Deploy-purple?style=for-the-badge&logo=flydotio)](https://fly.io)
[![Docker](https://img.shields.io/badge/Docker-ghcr.io-blue?style=for-the-badge&logo=docker)](https://ghcr.io/webees/vaultwarden)
[![Vaultwarden](https://img.shields.io/badge/Vaultwarden-Latest-green?style=for-the-badge)](https://github.com/dani-garcia/vaultwarden)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)](LICENSE)

> Production-ready Vaultwarden on Fly.io with Caddy reverse proxy, Overmind process manager, and automated Restic backups to Cloudflare R2.

## ✨ Features

| Component | Description |
| :--- | :--- |
| **Vaultwarden** | Self-hosted Bitwarden compatible server |
| **Caddy** | Reverse proxy with security headers and IP forwarding |
| **Overmind** | Process manager for robust service orchestration |
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

# Import secrets from .env
cat .env | fly secrets import

# Create storage volume
fly volumes create app_data --region sin --size 1   # must match primary_region in fly.toml
```

> The committed `.env` ships placeholders only (`vault.example.com`, `88888888`, ...). Replace every
> value before importing, and never commit real credentials.

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
fly secrets set SMTP_HOST="smtp.gmail.com"
fly secrets set SMTP_PORT="587"
fly secrets set SMTP_FROM="sender@example.com"
fly secrets set SMTP_TO="admin@example.com"
fly secrets set SMTP_USERNAME="sender@example.com"
fly secrets set SMTP_PASSWORD="app-specific-password"

# Optional dead-man's-switch, pinged after every backup run (e.g. healthchecks.io)
fly secrets set HEALTHCHECK_URL="https://hc-ping.com/your-uuid"

# Optional tuning (defaults shown)
fly secrets set SMTP_TIMEOUT="15"        # seconds msmtp may wait for the relay
fly secrets set VERIFY_SUBSET="10%"      # data slice read back by the monthly verify
fly secrets set CRON_RESTART_DELAY="5"   # seconds before the scheduler is restarted
fly secrets set RESTIC_LOG_DIR="/data/restic-logs"  # persistent backup logs
fly secrets set RESTIC_LOG_MAX_BYTES="262144"       # cap each log file at 256 KiB
fly secrets set RESTIC_LOG_DIR_MAX_BYTES="10485760" # cap the log directory at 10 MiB
```

### 3. Deploy

```bash
fly deploy
```

## 🔢 Versions & Upgrades

The base image is pinned with the `VAULTWARDEN_VERSION` build arg in the `Dockerfile`, so a rebuild never
silently changes the Vaultwarden version. The GHCR workflow additionally runs weekly to pick up Alpine
package (`caddy`, `restic`, `sqlite`) security updates. `fly.toml` pins the deployed amd64 image by digest,
so update that digest deliberately after a successful workflow run.

Every published build also receives a timestamp tag in `Asia/Shanghai`, for example `202610180615`.

```bash
# Show the new amd64 digest, then replace the value in fly.toml
docker buildx imagetools inspect ghcr.io/webees/vaultwarden:latest

# Bump VAULTWARDEN_VERSION, then rebuild and redeploy
fly deploy
fly releases            # list previous releases
fly releases rollback   # roll back to the previous image
```

## 💾 Backup & Recovery

| Item | Behaviour |
| :--- | :--- |
| Schedule | `@hourly` backup plus a monthly integrity check, defined in `config/crontab` |
| Data | `/data` volume, excluding the live `db.*` SQLite files, the rebuildable `icon_cache`, and `restic-logs` |
| Consistency | `sqlite3 .backup` hot copy to `/data/backup.bak` plus `PRAGMA integrity_check` before upload |
| Retention | `--keep-hourly 24 --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --keep-yearly 3 --prune` |
| Alerts | Email on failure (`SMTP_*`) and an optional `HEALTHCHECK_URL` ping on every run |

```bash
fly ssh console -C "/restic.sh backup"         # manual backup
fly ssh console -C "/restic.sh snapshots"      # list snapshots
fly ssh console -C "/restic.sh verify"         # read back a data slice from the repository
fly ssh console -C "/restic.sh restore <id>"   # restore snapshot
```

> `restore` writes straight over the running instance's `/data`. When you only want to verify a snapshot,
> restore into a scratch machine or a temporary path instead.
>
> Losing `RESTIC_PASSWORD` makes every snapshot permanently unreadable. Keep a copy outside Fly as well.
>
> To rotate it, add the new password as an extra key first (`restic key add`), then update the secret.
> Replacing the secret without adding a key first locks you out of every existing snapshot.

## 🧯 Troubleshooting

| Symptom | Cause / fix |
| :--- | :--- |
| Cron job logs `exit status 127`, no backup ever runs | `/restic.sh` starts with `#!/bin/bash`; the image must keep the `bash` package |
| Log line `Another backup is already running` | A manual run overlapped the hourly run; the newer run exits 3 on purpose |
| Log line `[cronloop] supercronic exited` | The scheduler crashed and was restarted by `/cronloop.sh`; check the lines above it |
| Client IPs look like Cloudflare edge addresses | Caddy trusts `CF-Connecting-IP` only when the edge-controlled `Fly-Client-IP` is in Cloudflare's published origin ranges; update those ranges in `config/Caddyfile` if they change |
| Backup failures produce no email | `SMTP_TO`/`SMTP_HOST` unset (the script then skips mail); check `/var/log/msmtp.log` |
| Backup logs disappear after a redeploy | Set `RESTIC_LOG_DIR=/data/restic-logs`; the default is now on the persistent volume |
| Backup log grows unexpectedly | Logs are capped at `RESTIC_LOG_MAX_BYTES` (default 256 KiB), the directory is capped at `RESTIC_LOG_DIR_MAX_BYTES` (default 10 MiB), and files older than 10 hours are removed |

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
/restic.sh restore <id>        # Restore from specific snapshot
/restic.sh test                # Test email notifications
```

### Log Inspection

```bash
cat /data/restic-logs/*.log    # Check persisted backup logs
tail -f /var/log/msmtp.log     # Monitor email logs
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
`ADMIN_TOKEN`, so treat that token as a high-value secret.

## 📝 License

Distributed under the [MIT License](LICENSE).

---
🚀 Optimized for Fly.io by **[WeBees](https://github.com/webees)**
