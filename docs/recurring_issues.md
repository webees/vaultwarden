# Recurring Engineering Decisions

This file records defects that were fixed more than once, especially where a later simplification removed the fix. These are permanent invariants: a change that weakens one needs a failing regression test and an explicit replacement design first.

Review basis: all 243 commits reachable before this decision commit were inspected on 2026-10-28. The recurring pattern is not only missing code; it is removing an existing invariant while optimizing line count. Commit identifiers below are evidence, not exceptions to the rules.

## Bounded Diagnostics

History: `33ccfc2`, `b9187d4`, `f34550e`, `8154030`, `3874f9d`, and `9c06b0b` repeatedly tightened persistent logs, directory limits, timeouts, and captured command output. `5cd1219` then reduced `log()` back to unbounded command substitution while keeping only downstream file truncation.

Final decision: bound output at capture time and again before persistence. Command output flows through `tail -c` before shell memory or a temporary file can grow without limit; the persistent log is replaced atomically within its byte cap and temporary files are removed on success and failure. Capture, redaction, or normal write failures abort the operation instead of producing a false success. Failure-notification logging is explicitly best-effort so an unwritable log cannot suppress the alert; the operation still exits nonzero. Per-file and directory limits remain independent safeguards.

Regression gate: oversized command output, failed `tail`, leftover log temporaries, unsafe limits, an uncappable existing log, and write failures must all fail closed in `tests/runtime_smoke.py`. `scripts/restic.sh` must never return to the unbounded `body="$("$@" 2>&1)"` capture removed in `5cd1219`.

## One Address Policy

History: proxy trust and address parsing changed in `3946373`, `807a94f`, `1763a2e`, and `f102ad2`. Multiple near-duplicate validators made it possible to fix one input path while leaving another path permissive.

Final decision: `scripts/entrypoint/config.sh` owns one host/port rule and one HTTPS URL rule for `DOMAIN` and `HEALTHCHECK_URL`. Restic repositories accept only absolute local paths or unambiguous S3 URIs. Userinfo, encoding, traversal, ambiguous separators, invalid ports, oversized values, and raw Unicode hosts fail closed. IDNA hosts must be supplied in canonical ASCII punycode form.

Regression gate: accepted and rejected cases plus mutation controls live in `tests/test_address_audit.py`; changing a guard without observing its mutation test fail is not valid coverage.

## Restore Isolation

History: restore safety required repeated fixes in `35f6371`, `d33b662`, `9097c10`, `04ce17f`, `360f8c6`, `5be475a`, `acaad01`, and `eba14c9`. The recurring causes were symlinks, SQLite sidecars, partial swaps, and treating a successful command exit as a valid restore.

Final decision: restore drills use a bounded, loopback-only scratch directory and never modify production `/data`. In-place restore requires explicit confirmation, rejects non-regular paths and symlinks, validates database output exactly, and keeps a rollback journal until the swap succeeds.

Regression gate: isolated restore, corrupt output, symlink, missing file, sidecar, copy failure, chown failure, and rollback cases must remain in the runtime suite.

## State And Process Supervision

History: stale locks, marker ambiguity, and service recovery were repeatedly repaired in `0ab38a6`, `5f289fc`, `ff5c7d9`, `c6a0a3c`, `8a4ab80`, and `d4cd093` through `9fda30f`.

Final decision: missing, unreadable, oversized, non-regular, stale, and in-flight backup states are distinct. Only the process holding the backup lock may publish `running`. Caddy and Supercronic restart after failure; Vaultwarden exit stops the container so Fly owns machine recovery.

Regression gate: lock creation failure, unknown state, stale running marker, status write failure, forced Caddy restart, forced scheduler restart, and Vaultwarden exit are executable runtime cases.

## Cloudflare Ranges

History: ranges were hard-coded in `59ca5a6`, automated in `a911a74`, hardened in `748c7e8` and `93a1cb5`, and corrected for repository-relative execution in `f5738aa`.

Final decision: keep a checked-in fallback and update it through validated official lists. Response size, family, prefix width, overlap, duplicate count, CIDR validity, and atomic replacement are checked before commit. Manual-only updates are not an acceptable replacement for synchronization.

Regression gate: network failure, malformed or truncated lists, family mismatch, overlap, excessive size/count, retries, atomic replacement, and directory `fsync` failure are covered by Python tests.

## Privacy And Public History

Final decision: never add deployment domains, personal addresses, credentials, tokens, bucket identifiers, private network addresses, or machine identifiers to source, tests, workflow data, commit messages, or artifacts. Synthetic test values must use reserved documentation ranges or dynamic construction.

Regression gate: current tracked files are scanned automatically. Reachable history is scanned separately; public provider metadata, Cloudflare's public CIDRs, reserved documentation addresses, and explicit placeholders are classified rather than counted as secrets.

## Simplification Rule

Line-count reduction is not evidence of quality. A simplification may remove duplication only after preserving: authority boundaries, fail-closed behavior, bounded resource use, atomic state transitions, rollback paths, and the negative control that proves each guard is active. This rule takes precedence over further compaction.
