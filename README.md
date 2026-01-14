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
| **Caddy** | Automatic HTTPS, security headers, Cloudflare IP forwarding |
| **Overmind** | Tmux-based process manager (graceful restarts) |
| **Supercronic** | Cron daemon for containers |
| **Restic** | Encrypted incremental backups with retention policy |
| **msmtp** | Email notifications on backup failures |

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      Fly.io Edge                        │
└───────────────────────────┬─────────────────────────────┘
                            │ :443
┌───────────────────────────▼─────────────────────────────┐
│                        Caddy                            │
│              (TLS termination, headers)                 │
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

### 1. Create App & Volume

```bash
fly auth login
fly apps create vaultwarden
fly volumes create app_data --region hkg --size 1
```

### 2. Configure Secrets

```bash
# Required: Domain
# Caddy domains (Catch-all: :80, Specific: example.com:80 example.org:80)
fly secrets set CADDY_DOMAINS="vault.example.com:80"
# Vaultwarden domain (full URL with protocol)
fly secrets set DOMAIN="https://vault.example.com"

# Required: Cloudflare R2 backup
fly secrets set RESTIC_PASSWORD="your-password"
fly secrets set RESTIC_REPOSITORY="s3:your-account-id.r2.cloudflarestorage.com/vaultwarden"
fly secrets set AWS_ACCESS_KEY_ID="your-r2-access-key"
fly secrets set AWS_SECRET_ACCESS_KEY="your-r2-secret-key"

# Required: Email (for Vaultwarden & backup alerts)
fly secrets set SMTP_HOST="smtp.gmail.com"
fly secrets set SMTP_PORT="587"
fly secrets set SMTP_FROM="your@email.com"
fly secrets set SMTP_TO="notify@email.com"
fly secrets set SMTP_USERNAME="your@email.com"
fly secrets set SMTP_PASSWORD="app-password"

# Optional: Vaultwarden settings
fly secrets set SIGNUPS_ALLOWED="false"
fly secrets set SHOW_PASSWORD_HINT="false"
fly secrets set ORG_CREATION_USERS="admin@email.com"
# fly secrets set ADMIN_TOKEN="secure-token"
```

### 3. Deploy

```bash
fly deploy
```

## 🛠️ Management

### Fly CLI

> Use `-a <app-name>` to specify app when not in project directory.

```bash
# SSH into container
fly ssh console
fly ssh console -a vaultwarden

# View logs
fly logs
fly logs -a vaultwarden

# Deploy
fly deploy
fly deploy -a vaultwarden

# Manage secrets
fly secrets list -a vaultwarden
fly secrets set KEY=value -a vaultwarden

# App status
fly status -a vaultwarden
fly apps list

# Scale & restart
fly scale count 1 -a vaultwarden
fly apps restart vaultwarden
```

### Backup Commands (via SSH)

```bash
/restic.sh backup              # Run manual backup
/restic.sh snapshots           # List all snapshots
/restic.sh restore <id>        # Restore from snapshot
```

### View Logs (via SSH)

```bash
cat /var/log/restic/*.log      # Backup logs
tail -f /var/log/msmtp.log     # Email logs
```

## 📁 Configuration

| File | Purpose |
| :--- | :--- |
| `config/Caddyfile` | Reverse proxy, security headers |
| `config/Procfile` | Process definitions for Overmind |
| `config/crontab` | Backup schedule (default: hourly) |
| `scripts/restic.sh` | Backup script with email alerts |

## 🔒 Security

- **HSTS**: Strict-Transport-Security enabled
- **XSS Protection**: X-XSS-Protection header
- **Clickjacking**: X-Frame-Options DENY
- **MIME Sniffing**: X-Content-Type-Options nosniff
- **No Indexing**: X-Robots-Tag noindex, nofollow
- **Cloudflare**: CF-Connecting-IP forwarded as X-Real-IP

## 📊 Backup Retention

| Period | Kept |
| :--- | :--- |
| Daily | 7 |
| Weekly | 4 |
| Monthly | 3 |
| Yearly | 3 |

## 🔧 Environment Variables

| Variable | Required | Description |
| :--- | :--- | :--- |
| `CADDY_DOMAINS` | ✅ | Caddy domains (e.g., `:80`, `vault.example.com:80`) |
| `DOMAIN` | ✅ | Vaultwarden URL (e.g., `https://vault.example.com`) |
| `RESTIC_PASSWORD` | ✅ | Encryption password for backups |
| `RESTIC_REPOSITORY` | ✅ | R2 URL: `s3:<account-id>.r2.cloudflarestorage.com/<bucket>` |
| `AWS_ACCESS_KEY_ID` | ✅ | Cloudflare R2 Access Key ID |
| `AWS_SECRET_ACCESS_KEY` | ✅ | Cloudflare R2 Secret Access Key |
| `SMTP_HOST` | ✅ | SMTP server for notifications |
| `SMTP_PORT` | ❌ | SMTP port (default: 587) |
| `SMTP_FROM` | ✅ | Sender email address |
| `SMTP_TO` | ✅ | Recipient for backup alerts |
| `SMTP_USERNAME` | ✅ | SMTP authentication user |
| `SMTP_PASSWORD` | ✅ | SMTP authentication password |
| `SIGNUPS_ALLOWED` | ❌ | Allow new user registration (default: false) |
| `ADMIN_TOKEN` | ❌ | Admin panel access token |
| `ORG_CREATION_USERS` | ❌ | Users allowed to create organizations |

## 📚 References

- [Vaultwarden Wiki](https://github.com/dani-garcia/vaultwarden/wiki)
- [Configuration Options](https://github.com/dani-garcia/vaultwarden/wiki/Configuration-overview)
- [SMTP Configuration](https://github.com/dani-garcia/vaultwarden/wiki/SMTP-Configuration)
- [Enabling Admin Page](https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page)

## 📝 License

MIT

---

Made with ❤️ for 🔐
