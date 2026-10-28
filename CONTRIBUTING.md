# Contributing

## Before Changing Code

Open an issue for behavior changes or security-sensitive work. Keep deployment-specific identifiers and generated files out of the repository.

Use a `codex/` feature branch. Commit messages and pull requests must be in English and should explain the defect, the minimal fix, and the verification performed.

## Required Checks

Run the relevant checks before opening a pull request:

```bash
shellcheck scripts/*.sh scripts/entrypoint/*.sh
python3 -m py_compile scripts/*.py tests/*.py
python3 -m unittest discover -s tests -p 'test_*.py'
docker build --tag vaultwarden:local .
python3 tests/runtime_smoke.py vaultwarden:local
python3 tests/performance.py vaultwarden:local
```

Changes to startup, Caddy, backups, restore, notifications, or image contents also require runtime smoke coverage. Tests must prove accepted and rejected paths, failure behavior, side effects, and temporary-file cleanup.

## Pull Requests

Keep the diff small and focused. Do not include credentials, production addresses, private logs, caches, generated reports, or unrelated refactors. Address review findings with new commits or a clearly documented force-with-lease update; do not bypass required checks.
