# Vaultwarden on Fly.io

Vaultwarden on Fly.io with a Caddy proxy, supervised background processes, and encrypted Restic
backups to any S3-compatible store such as Cloudflare R2.

## Architecture

The entrypoint repairs `/data` ownership and modes, drops privileges, and starts one process table. Caddy and Supercronic restart after a crash;
a Vaultwarden exit stops the container so Fly can replace it. The app name comes only from the `FLY_APP` repository secret.

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

Address inputs fail closed: `DOMAIN` must be a canonical HTTPS origin, `RESTIC_REPOSITORY` must be an
absolute path or unambiguous `s3://` URI, and `HEALTHCHECK_URL` must be an HTTPS base URL. Hosts must be DNS names or canonical ASCII punycode; IP literals, raw Unicode, userinfo, encoding, control characters, and traversal-like paths are rejected before runtime writes.

Alerts are opt-in: hourly backup, freshness, and disk failures use Telegram; monthly verification and restore-drill failures use SMTP and Telegram. Successful backups are quiet.
`notify-test` exercises every configured transport. An HTTPS `HEALTHCHECK_URL` receives a success ping after backup, verification, or restore drills and `/fail` on guarded failures.

The `/admin` route accepts traffic only from configured Cloudflare ranges when `Cf-Access-Jwt-Assertion` is present. Caddy checks the network source and header presence, not JWT validity.
Enforce Cloudflare Access for `/admin` and `/admin/*`, and keep the long, random `ADMIN_TOKEN` as a second factor.

## Deploy

Image and production-input changes build a multi-architecture GHCR image. Each build receives an
`Asia/Shanghai` timestamp tag such as `202610180615`; Fly deploys its exact amd64 digest, not a mutable tag.

```bash
fly releases --app "$FLY_APP"
fly status --app "$FLY_APP"
fly releases rollback <release> --app "$FLY_APP"
```

Deployment passes only when the newest release is complete, every machine runs the expected digest,
and all health checks pass. Timestamp tags expire after 30 days; stale Actions artifacts and build
caches are removed nightly, and a nightly watchdog replays a stale dependency schedule.

Dependabot checks pinned Actions daily. Every two hours the dependency workflow checks official Vaultwarden,
Supercronic, Alpine packages, and Cloudflare ranges, then opens or refreshes one protected PR. Its scheduled
audit also verifies the live release, digest, machines and health; auto-merge waits for required `validate`.

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

Backup runs hourly at `:17`; freshness checks run at `:45`, disk checks at `:35`; verification runs at 03:30 and the restore drill at 04:15 on the first day of each month (`Asia/Shanghai`). SQLite `.backup` creates
`/data/backup.bak`, then `PRAGMA integrity_check` validates it. Snapshots keep keys, attachments, and that consistent database copy; live SQLite files, `icon_cache`, status state, and the configured log directory are excluded.
Retention is 24 hourly, 7 daily, 4 weekly, 3 monthly, and 3 yearly snapshots before prune. Every
command is time-bounded, each run log is capped at 256 KiB, and the directory at 10 MiB; an unmaintainable cap refuses new work.

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

The Actions operation menu accepts only `check-freshness`, `notify-test`, `snapshots`, `verify`,
`restore-test`, or `backup`; in-place `restore` remains an SSH operation guarded by `RESTORE_CONFIRM=yes`.

## Security

Caddy adds HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`, and `X-Robots-Tag`, while removing `Server`,
`X-Powered-By`, and `Last-Modified`. Access logs redact credentials, forwarding headers, and query strings.

Cloudflare ranges are validated and synchronized from the official IPv4 and IPv6 lists; direct Fly
traffic still trusts `Fly-Client-IP`. Reserved paths are checked without following symlinks, and all
runtime processes run as unprivileged `vaultwarden`.

Recurring defects and the guards that must not be simplified away are recorded in [docs/recurring_issues.md](docs/recurring_issues.md).

Follow [SECURITY.md](SECURITY.md): report privately and never include credentials, production identifiers, or unredacted logs.

Settings in `/data/config.json` override matching environment variables. The entrypoint reports when `admin_token`, `signups_allowed`, or any `smtp_*` key wins over a Fly secret; prefer Fly secrets and remove those keys before restart.

## Troubleshooting

| Symptom | Check |
| :--- | :--- |
| Repeated machine restarts | `fly logs`; a Vaultwarden exit intentionally stops the stack |
| Fly health check fails | `fly status`; `/alive` must pass through Caddy |
| `/admin` returns `403` | Confirm Cloudflare Access is configured and the request reaches the origin through a current Cloudflare range |
| New settings have no effect | Remove matching keys from `/data/config.json`, then restart |
| Backup stale or lock stuck | Run `check-freshness`, then inspect `fly logs` and `/data/backup-status.txt` |
| Restore did not apply | Check `restore-pending` and entrypoint diagnostics |

## Verification

```bash
shellcheck scripts/*.sh scripts/entrypoint/*.sh
PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/vaultwarden-pycache" python3 -m py_compile scripts/*.py tests/*.py
PYTHONDONTWRITEBYTECODE=1 TMPDIR=/tmp python3 -m unittest discover -s tests -p 'test_*.py'
docker build --tag vaultwarden:local .
PYTHONDONTWRITEBYTECODE=1 TMPDIR=/tmp python3 tests/runtime_smoke.py vaultwarden:local
PYTHONDONTWRITEBYTECODE=1 TMPDIR=/tmp python3 tests/performance.py vaultwarden:local
```

`tests/runtime_smoke.py` validates supervision, proxy boundaries, backup paths, SMTP delivery, log limits, SQLite integrity, and isolated restore.
Use `tests/performance.py --write-baseline` and `--baseline` on the same host to enforce the median drift gate.

## License

This repository is MIT licensed; see [LICENSE](LICENSE). Vaultwarden and packaged components retain their upstream licenses.
See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
