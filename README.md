# Vaultwarden on Fly.io

Vaultwarden on Fly.io with a Caddy proxy, supervised background processes, and encrypted Restic
backups to any S3-compatible store such as Cloudflare R2.

## Architecture

```text
Fly proxy :443 -> Caddy :8080 -> Vaultwarden :8081
                              |-> Supercronic
                              `-> Restic -> S3/R2
```

The entrypoint repairs `/data` ownership and modes, drops privileges, and starts one process table.
Caddy and Supercronic restart after a crash; a Vaultwarden exit stops the container so Fly can
replace it. The app name stays out of the repository and comes from the `FLY_APP` repository secret.

## Setup

Requirements: an authenticated Fly CLI, Docker for validation, a Fly volume at `/data`, and Restic
repository credentials.

```bash
fly apps create <app-name>
export FLY_APP=<app-name>
fly volumes create app_data --region sin --size 1 --app "$FLY_APP"
cp .env.example .env  # fill it locally; never commit it
fly secrets import --app "$FLY_APP" < .env
```

`CADDY_DOMAINS` is a space-separated Host allowlist; other hosts receive `403`. `/alive` remains
reachable for Fly checks. `SIGNUPS_ALLOWED=false` is the safe default.

Optional Telegram and SMTP alerts use the placeholders in `.env.example`. Hourly backup, freshness,
and disk failures use Telegram. Monthly verification and restore failures also use email when SMTP
exists. Successful backups are quiet. When `HEALTHCHECK_URL` is set, success pings the base URL and
failure pings `<HEALTHCHECK_URL>/fail`.

The `/admin` origin accepts only a Cloudflare network carrying `Cf-Access-Jwt-Assertion`; configure
Cloudflare Access for `/admin` and `/admin/*`. Keep the long, random `ADMIN_TOKEN` as a second factor.

## Deploy

Image and production-input changes build a multi-architecture GHCR image. Each build receives an
`Asia/Shanghai` timestamp tag such as `202610180615`; Fly deploys the exact amd64 digest rather than a
mutable tag.

```bash
fly releases --app "$FLY_APP"
fly status --app "$FLY_APP"
fly releases rollback <release> --app "$FLY_APP"
```

Deployment passes only when the newest release is complete, every machine runs the expected digest,
and all health checks pass. Timestamp tags expire after 30 days; cleanup runs nightly and from builds
when the schedule is stale.

Dependabot updates pinned Actions. Every two hours the dependency workflow checks Vaultwarden,
Supercronic, Alpine packages, Cloudflare ranges, and Actions, then opens or refreshes one protected
PR. Auto-merge waits for required `validate`; the merged commit follows the same build and deploy path.

### Tuning

| Variable | Default | Purpose |
| :--- | :--- | :--- |
| `BACKUP_MAX_AGE` | `7200` | Maximum seconds since a successful backup |
| `BACKUP_MAX_USAGE_PERCENT` | `85` | Volume usage alarm threshold |
| `RESTIC_LOG_DIR` | `/data/restic-logs` | Bounded operational log directory |
| `RESTIC_LOG_MAX_BYTES` | `262144` | Maximum size of one log file |
| `RESTIC_LOG_DIR_MAX_BYTES` | `10485760` | Maximum total log-directory size |
| `RESTIC_QUICK_TIMEOUT` | `60` | Timeout for short Restic commands |
| `RESTIC_LONG_TIMEOUT` | `1800` | Timeout for backup and restore commands |
| `VERIFY_SUBSET` | `10%` | Data percentage read during repository verification |
| `VERIFY_RETRY_LOCK` | `10m` | Lock wait for scheduled verification |
| `SUPERVISE_RESTART_DELAY` | `5` | Delay before restarting Caddy or the scheduler |

## Backup And Restore

Backup runs hourly at `:17`; freshness checks run at `:45`, disk checks at `:35`, and verification
and restore drills run monthly. SQLite `.backup` creates `/data/backup.bak`, then
`PRAGMA integrity_check` validates it. Snapshots keep keys, attachments, and that consistent database
copy; live SQLite files, `icon_cache`, status state, and the configured log directory are excluded.
Retention is 24 hourly, 7 daily, 4 weekly, 3 monthly, and 3 yearly snapshots before prune. Every
command is time-bounded, each run log is capped at 256 KiB, and the directory at 10 MiB.

```bash
fly ssh console --app "$FLY_APP" -C "/restic.sh {backup|snapshots|verify|restore-test|check-freshness|check-disk}"
```

`restore-test` checks free space, restores to an isolated temporary directory, validates SQLite, and
cold-boots Vaultwarden against the restored database. It never changes the production database.

### In-Place Recovery

Live `db.sqlite3` files are intentionally absent from snapshots. The consistent copy is
`/data/backup.bak`, which the entrypoint swaps in before Vaultwarden starts:

```bash
fly ssh console --app "$FLY_APP" -C "RESTORE_CONFIRM=yes /restic.sh restore <snapshot-id>"
fly ssh console --app "$FLY_APP" -C "touch /data/restore-pending"
fly apps restart "$FLY_APP"
```

The swap fails closed on symlinks, wrong file types, or an unreadable database, leaving the live
database untouched and reporting the reason in `fly logs`. Keep an offline copy of
`RESTIC_PASSWORD`; losing it makes every snapshot unreadable. To rotate it, add the new key with
`restic key add` before changing the secret.

The Actions operation menu is limited to `check-freshness`, `notify-test`, `snapshots`, `verify`,
`restore-test`, and `backup`. It accepts no arbitrary command. In-place `restore` remains an SSH
operation guarded by `RESTORE_CONFIRM=yes`.

## Security

Caddy adds HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`,
`Permissions-Policy`, and `X-Robots-Tag`, while removing `Server`, `X-Powered-By`, and `Last-Modified`.
Access logs redact credentials, forwarding headers, and query strings.

Cloudflare ranges are validated and synchronized from the official IPv4 and IPv6 lists; direct Fly
traffic still trusts `Fly-Client-IP`. Reserved paths are checked without following symlinks, and all
runtime processes run as unprivileged `vaultwarden`.

Settings saved by the admin panel live in `/data/config.json` and override matching environment
variables. The entrypoint reports when `admin_token`, `signups_allowed`, or any `smtp_*` key wins
over a Fly secret. Prefer Fly secrets and remove those keys from `/data/config.json` before restart.

## Troubleshooting

| Symptom | Check |
| :--- | :--- |
| Repeated machine restarts | `fly logs`; a Vaultwarden exit intentionally stops the stack |
| Fly health check fails | `fly status`; `/alive` must pass through Caddy |
| New settings have no effect | Remove matching keys from `/data/config.json`, then restart |
| Backup stale or lock stuck | Run `check-freshness`, then inspect `fly logs` and `/data/backup-status.txt` |
| Restore did not apply | Check `restore-pending` and entrypoint diagnostics |
| Alert did not arrive | Run `notify-test`; the run log records the transport result |

## Verification

```bash
shellcheck scripts/*.sh scripts/entrypoint/*.sh tests/*.sh
python3 -m py_compile scripts/*.py tests/*.py
python3 -m unittest discover -s tests -p 'test_*.py'
docker build --tag vaultwarden:local .
python3 tests/runtime_smoke.py vaultwarden:local
```

`tests/runtime_smoke.py` boots the image and validates process supervision, proxy boundaries, backup
paths, SMTP delivery, log limits, SQLite integrity, and isolated restore. CI also enforces source,
workflow, test, and documentation size budgets to prevent structural regressions.

## License

MIT. See [LICENSE](LICENSE).
