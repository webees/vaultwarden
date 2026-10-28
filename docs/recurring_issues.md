# Recurring Engineering Decisions

This file records defects that were fixed more than once, especially where a later simplification removed the fix. These are permanent invariants: a change that weakens one needs a failing regression test and an explicit replacement design first.

Review basis: all 243 commits reachable before this decision commit were inspected on 2026-10-28. The recurring pattern is not only missing code; it is removing an existing invariant while optimizing line count. Commit identifiers below are evidence, not exceptions to the rules.

## Every-Round Goal Gate

Before any other audit, optimization, scoring, or completion work in a round, scan every recorded failure class below against the current implementation and run its regression gate. For each class, trace reachable history with `git log -S` and `git log -G`, then classify it as never fixed, regressed after simplification, or partially fixed and identify the one authoritative implementation.

- If history shows a regression or a weakened invariant, restore that invariant in the round's first patch before unrelated optimization. Do not combine that patch with line-count reduction.
- Check every execution path that reaches the invariant, not only the path named in a previous fix. A guard on preflight, one command, or one caller is partial until all equivalent paths enforce it.
- State explicitly whether the same invariant was previously fixed and later removed. If it was, record the final decision and a regression test that fails when that guard is removed.
- Every changed class must have positive, boundary, negative, and mutation-control tests. The mutation control must fail when the authoritative guard is removed.
- Update the affected History, Final decision, and Regression gate when evidence changes.
- Record the history evidence, authoritative guard, and mutation-control result in the PR or final report without creating per-round files.
- No score or completion claim is valid while any recorded gate is missing, failing, or unverified. An accepted residual must remain explicitly open and must never count as passing.

## Bounded Diagnostics

History: `33ccfc2`, `b9187d4`, `f34550e`, `8154030`, `3874f9d`, and `9c06b0b` repeatedly tightened persistent logs, directory limits, timeouts, and captured command output. `5cd1219` then reduced `log()` back to unbounded command substitution while keeping only downstream file truncation. `6751d9e` restored fail-closed trimming only before a backup; `655e499` found the post-backend path still downgraded the same failure to a warning and later recorded `state=ok`.

Final decision: bound output at capture time and again before persistence. Command output flows through `tail -c` before shell memory or a temporary file can grow without limit; the persistent log is replaced atomically within its byte cap and temporary files are removed on success and failure. Capture, redaction, or normal write failures abort the operation instead of producing a false success. Log maintenance is enforced on every path that can create or append data: before a new run log is created and again after backend work. Failure at either point aborts, records a failed operation, alerts, and never continues with only a warning or `state=ok`. Per-file and directory limits remain independent safeguards.

Regression gate: oversized command output, failed `tail`, leftover log temporaries, unsafe limits, an uncappable existing log, an unmaintainable directory before work, an unmaintainable directory after backend work, and write failures must all fail closed in `tests/runtime_smoke.py`. The before-work case must prove that the backend is never called; the after-work case must prove that no new success time is recorded and that removing the post-backend guard creates a false-success mutation. `scripts/restic.sh` must never return to the unbounded `body="$("$@" 2>&1)"` capture removed in `5cd1219`.

## Outbound Network Bounds

History: `bb51cdb` bounded `curl` calls, `12d9215` added a `gh api` timeout wrapper with an unbounded fallback, `5256c7a` bounded workflow API calls independently, and `376f55f` preserved the partial script fallback during simplification. The recurring defect is a partially fixed boundary: the timeout exists on CI but silently disappears on hosts without the expected command.

Final decision: every outbound operation has a positive numeric time limit. `scripts/deps.sh` rejects zero, negative, fractional, and non-numeric timeout configuration before starting a request. `gh api` runs through `timeout` or `gtimeout` with a mandatory SIGKILL grace period, so a process that ignores SIGTERM still cannot hang the job. Absence of a supported timeout command fails closed, and a raw unbounded fallback is forbidden.

Regression gate: success must prove the timeout wrapper is called; missing wrappers, unsafe timeout values, and a mutation that restores the raw fallback must fail in `tests/test_repository_contracts.py`. Every new outbound command must add a deterministic failure-path test instead of relying on CI runner behavior.

## One Address Policy

History: host matching was reworked in `760d87e`, `b947f5a`, `1763a2e`, and `9a034cf`; address validation was centralized in `f102ad2` and hardened in `ba7f452`. No earlier commit rejected numeric IPv4 forms and later removed that exact guard, but the pre-`f102ad2` design had no syntax validator and the new central validator still admitted dotted, decimal, and hexadecimal numeric forms. The recurrence is incomplete centralization and simplification, not a deleted numeric-IP patch.

Final decision: `scripts/entrypoint/config.sh` owns one host/port rule and one HTTPS URL rule for `DOMAIN` and `HEALTHCHECK_URL`. Restic repositories accept only absolute local paths or unambiguous S3 URIs. Hosts are DNS-only: IPv4 literals and numeric IPv4-compatible forms are rejected alongside bracketed IPv6, while names such as `version.127.example` remain valid. Userinfo, encoding, traversal, ambiguous separators, invalid ports, oversized values, and raw Unicode hosts fail closed. IDNA hosts must be supplied in canonical ASCII punycode form.

Regression gate: every entry point, an accepted name containing a numeric label, rejected numeric forms, and empty S3 path segments are covered in `tests/test_address_audit.py`. Dedicated mutation controls remove the shared numeric guard and the empty-segment guard independently; per-entry IP checks are forbidden because they recreate the fragmentation that caused this recurrence.

## Restore Isolation

History: restore safety required repeated fixes in `35f6371`, `d33b662`, `9097c10`, `04ce17f`, `360f8c6`, `5be475a`, `acaad01`, and `eba14c9`. The recurring causes were symlinks, SQLite sidecars, partial swaps, and treating a successful command exit as a valid restore.

Final decision: restore drills use a bounded, loopback-only scratch directory and never modify production `/data`. In-place restore requires explicit confirmation, rejects non-regular paths and symlinks, validates database output exactly, and keeps a rollback journal until the swap succeeds.

Regression gate: isolated restore, corrupt output, symlink, missing file, sidecar, copy failure, chown failure, and rollback cases must remain in the runtime suite.

## State And Process Supervision

History: stale locks, marker ambiguity, and service recovery were repeatedly repaired in `0ab38a6`, `5f289fc`, `ff5c7d9`, `c6a0a3c`, `8a4ab80`, and `d4cd093` through `9fda30f`.

Final decision: missing, unreadable, oversized, non-regular, stale, and in-flight backup states are distinct. Status writes are atomic or fail without truncating the previous marker. Only the process holding the backup lock may publish `running`. Caddy and Supercronic restart after failure; Vaultwarden exit stops the container so Fly owns machine recovery.

Regression gate: lock creation failure, unknown state, stale running marker, status write failure without marker corruption, forced Caddy restart, forced scheduler restart, and Vaultwarden exit are executable runtime cases. A mutation that restores the in-place status-write fallback must fail the repository contract.

## Runtime Harness Lifecycle

History: Validate run `40674101240` reported a shell case failure with no container output while the same case passed repeatedly. Container-runtime startup failures can therefore be mistaken for product assertions when existence is judged only by the process exit code.

Final decision: each isolated shell case emits start and end lifecycle markers. A missing end marker with a nonzero Docker exit is retried at most three times as infrastructure failure. An end marker with a nonzero status fails immediately as a product assertion, and a clean exit without both terminal markers fails closed as a harness error. Infrastructure retries may never convert an executed failed assertion into a pass.

Regression gate: interrupted-attempt recovery, immediate assertion failure, exhausted retry failure, and clean-exit marker loss are covered deterministically in `tests/test_repository_contracts.py`, followed by repeated execution of the affected runtime case.

## Cloudflare Ranges

History: ranges were hard-coded in `59ca5a6`, automated in `a911a74`, hardened in `748c7e8` and `93a1cb5`, and corrected for repository-relative execution in `f5738aa`.

Final decision: keep a checked-in fallback and update it through validated official lists. Response size, family, prefix width, overlap, duplicate count, CIDR validity, and atomic replacement are checked before commit. Manual-only updates are not an acceptable replacement for synchronization.

Regression gate: network failure, malformed or truncated lists, family mismatch, overlap, excessive size/count, retries, atomic replacement, and directory `fsync` failure are covered by Python tests.

## Privacy And Public History

History: credential and identifier leakage required repeated repairs in `0ab0f23`, `608c11d`, `80e930d`, `343cd3d`, `034f35f`, and `c690cac`. History rewriting removed previously reachable values instead of leaving them hidden only in current files.

Final decision: never add deployment domains, personal addresses, credentials, tokens, bucket identifiers, private network addresses, or machine identifiers to source, tests, workflow data, commit messages, or artifacts. Synthetic test values must use reserved documentation ranges or dynamic construction.

Regression gate: current tracked files are scanned automatically. Reachable history is scanned separately; public provider metadata, Cloudflare's public CIDRs, reserved documentation addresses, and explicit placeholders are classified rather than counted as secrets.

## Simplification Rule

History: `667d36c`, `97a0e8e`, `376f55f`, `5cd1219`, and `6751d9e` show that line-count reduction repeatedly weakened output bounds, timeout fallbacks, and log or status failure handling until the authoritative guards and their tests were restored.

Final decision: line-count reduction is not evidence of quality. A simplification may remove duplication only after preserving authority boundaries, fail-closed behavior, bounded resource use, atomic state transitions, rollback paths, and the negative control that proves each guard is active. This rule takes precedence over further compaction.

Regression gate: every recurring class must retain History, Final decision, and Regression gate sections, and repository tests must fail if a class or required field is removed. Simplification must also preserve every existing class gate and mutation control.
