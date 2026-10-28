# Vaultwarden on Fly.io

Vaultwarden packaged for Fly.io with a Caddy reverse proxy, static process supervision,
and encrypted Restic backups to S3-compatible storage such as Cloudflare R2.

## Architecture

```text
Fly proxy :443 -> Caddy :8080 -> Vaultwarden :8081
                              |-> Supercronic
                              `-> Restic -> S3/R2
```

The entrypoint prepares `/data`, drops privileges, and starts one process table. Caddy and
Supercronic restart after a crash; Vaultwarden exit stops the container so Fly can replace it.
The app name is not committed and must be supplied by the repository secret `FLY_APP` or with
`fly --app <name>`.

## Prerequisites

- Fly CLI and an authenticated account
- Docker for local validation
- A persistent Fly volume mounted at `/data`
- An S3-compatible Restic repository and credentials

## Setup

```bash
fly apps create <app-name>
export FLY_APP=<app-name>
fly volumes create app_data --region sin --size 1 --app "$FLY_APP"

cp .env.example .env
# Fill .env without committing it.
fly secrets import --app "$FLY_APP" < .env

fly secrets set --app "$FLY_APP" \
  CADDY_DOMAINS="vault.example.com" \
  DOMAIN="https://vault.example.com" \
  RESTIC_PASSWORD="<repository-password>" \
  RESTIC_REPOSITORY="s3:<endpoint>/<bucket>" \
  AWS_ACCESS_KEY_ID="<access-key>" \
  AWS_SECRET_ACCESS_KEY="<secret-key>"
```

`CADDY_DOMAINS` is a space-separated allowlist. Requests with any other `Host` receive `403`;
`/alive` remains reachable for Fly checks. `SIGNUPS_ALLOWED=false` is the safe default.

### Optional alerts

```bash
fly secrets set --app "$FLY_APP" \
  TELEGRAM_BOT_TOKEN="<bot-token>" \
  TELEGRAM_CHAT_ID="<chat-id>"

fly secrets set --app "$FLY_APP" \
  SMTP_HOST="smtp.example.com" \
  SMTP_PORT="587" \
  SMTP_TIMEOUT="15" \
  SMTP_FROM="sender@example.com" \
  SMTP_TO="admin@example.com" \
  SMTP_USERNAME="sender@example.com" \
  SMTP_PASSWORD="<app-password>"
```

Hourly backup, freshness, and disk alerts use Telegram. Monthly verification and restore drills
also use email when SMTP is configured. `HEALTHCHECK_URL` is optional; successful runs ping the
base URL and failures ping the same URL with `/fail`. Successful hourly backups are quiet unless
`BACKUP_NOTIFY_ON_SUCCESS=true`.

### Admin panel

The panel is available at `/admin`, but the origin accepts it only from a Cloudflare network with
`Cf-Access-Jwt-Assertion`. Configure Cloudflare Access for the exact `/admin` and `/admin/*` paths.
Keep `ADMIN_TOKEN` as a second factor; it should be long, random, and stored only as a secret.

## Deploy

Commits touching the image, `fly.toml`, or referenced build files trigger a multi-architecture
GHCR build. The workflow publishes a timestamp tag in `Asia/Shanghai`, such as
`202610180615`, and passes the exact image digest to Fly with `fly deploy --image`:

```bash
fly releases --app "$FLY_APP"
fly status --app "$FLY_APP"
fly releases rollback <release> --app "$FLY_APP"
```

Deployment succeeds only when the newest release is complete, every machine runs the expected
digest, and all Fly health checks pass. Tag cleanup removes timestamp tags older than 30 days and
also runs from the build workflow when the nightly schedule is stale.

Dependabot keeps immutable Actions pins current. The dependency workflow runs every two hours,
checks Vaultwarden, Supercronic, Alpine packages, Cloudflare ranges, and Actions, then opens or
updates one protected pull request. Auto-merge waits for the required `validate` check. A merged
update is rebuilt and deployed by the same delivery path.

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
| `VERIFY_SUBSET` | `10%` | Data percentage read by repository verification |
| `VERIFY_RETRY_LOCK` | `10m` | Lock wait for scheduled verification |
| `SUPERVISE_RESTART_DELAY` | `5` | Delay before restarting Caddy or the scheduler |

## Backup and restore

| Item | Behaviour |
| :--- | :--- |
| Schedule | Backup hourly at `:17`; freshness at `:45`; disk check at `:35`; monthly verify and restore drill |
| Consistency | `sqlite3 .backup` creates `/data/backup.bak`, followed by `PRAGMA integrity_check` |
| Contents | Keys, attachments and the consistent database copy; live SQLite files, `icon_cache`, status state and the configured log directory are excluded |
| Retention | 24 hourly, 7 daily, 4 weekly, 3 monthly and 3 yearly snapshots, then prune |
| Limits | Commands have bounded timeouts; each run log is capped at 256 KiB and the log directory at 10 MiB |

```bash
fly ssh console --app "$FLY_APP" -C "/restic.sh audit"
fly ssh console --app "$FLY_APP" -C "/restic.sh backup"
fly ssh console --app "$FLY_APP" -C "/restic.sh snapshots"
fly ssh console --app "$FLY_APP" -C "/restic.sh verify"
fly ssh console --app "$FLY_APP" -C "/restic.sh restore-test"
fly ssh console --app "$FLY_APP" -C "/restic.sh check-freshness"
fly ssh console --app "$FLY_APP" -C "/restic.sh check-disk"
```

`audit` is read-only. `restore-test` checks free space, restores into an isolated temporary
directory, validates SQLite, and cold-boots Vaultwarden against the restored database. It never
changes the production database.

### In-place recovery

The live `db.sqlite3` is intentionally absent from snapshots. The consistent copy is
`/data/backup.bak`, which the entrypoint swaps in before Vaultwarden starts:

```bash
fly ssh console --app "$FLY_APP" -C "RESTORE_CONFIRM=yes /restic.sh restore <snapshot-id>"
fly ssh console --app "$FLY_APP" -C "touch /data/restore-pending"
fly apps restart "$FLY_APP"
```

The swap fails closed if `backup.bak`, `db.sqlite3`, their sidecars, or the reserved scratch path
are symlinks, non-regular files where a file is required, or an unreadable database. The live
database is left in place and the reason appears in `fly logs`. Remove the unsafe path and retry.

Keep an offline copy of `RESTIC_PASSWORD`: losing it makes every snapshot unreadable. To rotate the
password, add the new key with `restic key add` before changing the secret.

### Operate from Actions

The dependency workflow exposes a fixed production-operation menu: `audit`, `check-freshness`,
`notify-test`, `snapshots`, `verify`, `restore-test` and `backup`. It accepts no arbitrary command
or arguments. `restore` is deliberately unavailable there and remains an SSH operation guarded by
`RESTORE_CONFIRM=yes`.

## Security

Caddy adds HSTS, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, a restrictive
`Referrer-Policy`, `Permissions-Policy`, and `X-Robots-Tag`; it removes `Server`,
`X-Powered-By`, and `Last-Modified`. The access log strips `Authorization`, `Cookie`,
`Proxy-Authorization`, `X-Api-Key`, `X-Auth-Token`, `Cf-Access-Jwt-Assertion`,
`X-Forwarded-For`, `X-Real-Ip`, and `Fly-Client-Ip`. Query strings are replaced with
`?redacted`.

Cloudflare addresses are validated and synchronized from the official IPv4 and IPv6 lists; direct
Fly traffic still receives the trusted `Fly-Client-IP`. The root entrypoint never follows symlinks
for reserved paths, and the runtime processes run as the unprivileged `vaultwarden` user.

Settings saved through the admin panel are stored in `/data/config.json`, which overrides matching
environment variables. The entrypoint reports when `admin_token`, `signups_allowed`, or any
`smtp_*` key in that file overrides a Fly secret. Prefer Fly secrets and remove those keys from
`config.json` before restarting.

## Troubleshooting

| Symptom | Check |
| :--- | :--- |
| Machine repeatedly restarts | `fly logs`; a Vaultwarden exit intentionally stops the stack |
| Fly health check fails | `fly status`; `/alive` must pass through Caddy |
| New settings have no effect | Remove matching keys from `/data/config.json`, then restart |
| Backup is stale or lock is stuck | Run `audit`, then inspect `fly logs` and `/data/backup-status.txt` |
| Restore did not apply | Check for `restore-pending`, then inspect entrypoint diagnostics |
| Alert did not arrive | Run `notify-test`; the bounded run log records the transport result |

## Verification

```bash
shellcheck scripts/*.sh scripts/entrypoint/*.sh tests/*.sh
python3 -m py_compile scripts/*.py tests/*.py
python3 -m unittest discover -s tests -p 'test_*.py'
docker build --tag vaultwarden:local .
python3 tests/runtime_smoke.py vaultwarden:local
```

`tests/test_repository_contracts.py` covers helper and workflow contracts. `tests/runtime_smoke.py`
boots the built image and validates the process stack, proxy boundaries, backup paths, SMTP
delivery, log limits, SQLite integrity, and isolated restore flow. CI also enforces fixed
no-regression line budgets for the largest scripts, workflows, and documentation.

## License

MIT. See [LICENSE](LICENSE).
