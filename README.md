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

### 1. Initialize Application

```bash
# Login to Fly.io
fly auth login

# Create application
fly apps create vaultwarden

# Import secrets from .env
cat .env | fly secrets import

# Create storage volume
fly volumes create app_data --region hkg --size 1
```

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
```

### 3. Deploy

```bash
fly deploy
```

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
cat /var/log/restic/*.log      # Check backup logs
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

## 📝 License

MIT

---
Made with ❤️ for 🔐
