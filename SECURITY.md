# Security Policy

## Supported Version

Security fixes target the latest commit on `main`. Older images and deployment forks are not supported.

## Reporting

Report vulnerabilities through the repository's private GitHub Security Advisory form. Do not open a public issue or include credentials, production URLs, personal data, or unredacted logs.

Include the affected commit or image digest, deployment model, reproduction steps, expected impact, and a minimal redacted proof of concept. Maintainers will acknowledge a complete report, validate it, and coordinate disclosure after a fix is available.

Use a disposable deployment where possible. Do not access, alter, or retain data that you do not own or have permission to test.

## Scope

In scope: this repository's Dockerfile, entrypoint, process supervision, Caddy policy, backup and restore scripts, address validation, notification paths, and tests.

Upstream Vaultwarden vulnerabilities should also be reported to the Vaultwarden project. Third-party packages retain their own security policies.
