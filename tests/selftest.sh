#!/bin/bash
# Reproducible checks for the helper scripts. No network, no restic repository
# and no production access: every case runs against a local fixture.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
. "$REPO_ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# BSD stat and GNU stat disagree about -f, so pick the flag per platform.
file_mode() {
    case "$(uname -s)" in
        Darwin) stat -f '%Lp' "$1" ;;
        *)      stat -c '%a' "$1" ;;
    esac
}

# ── supervise.sh ──────────────────────────────────────────────────────────────
echo "--- supervise.sh"
counter="$work/supervise.count"
: > "$counter"
SUPERVISE_RESTART_DELAY=0.05 ./scripts/supervise.sh probe \
    sh -c "printf 'run\n' >> \"$counter\"; exit 7" 2>"$work/supervise.err" &
supervisor=$!
sleep 1
kill -TERM "$supervisor" 2>/dev/null
wait "$supervisor"
supervisor_status=$?
runs="$(wc -l < "$counter" | tr -d ' ')"
if [ "$runs" -ge 2 ]; then
    ok "restarts a child that exits non-zero (${runs} runs observed)"
else
    bad "did not restart the child (${runs} runs observed)"
fi
same "exits with status 0 on SIGTERM" 0 "$supervisor_status"

# A bad delay used to spin: `sleep` failed every iteration and the supervisor
# restarted the child as fast as the shell could loop. Start it in the
# background so the pre-fix code cannot hang the suite, then terminate it.
run_supervise_invalid() { # delay
    SUPERVISE_RESTART_DELAY="$1" ./scripts/supervise.sh probe true \
        >/dev/null 2>&1 &
    local pid=$!
    sleep 0.3
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid"
}
run_supervise_invalid bogus
same "a non-numeric restart delay is rejected" 2 "$?"
run_supervise_invalid 0.0
same "a zero restart delay is rejected" 2 "$?"

./scripts/supervise.sh probe >/dev/null 2>&1 &
supervise_empty_pid=$!
sleep 0.3
kill -TERM "$supervise_empty_pid" 2>/dev/null || true
wait "$supervise_empty_pid"
same "a supervisor without a child command is rejected" 2 "$?"

# ── refresh-cloudflare-ips.sh ─────────────────────────────────────────────────
echo "--- refresh-cloudflare-ips.sh"
# Build a stub `curl` that answers with exactly N ranges per call.
# shellcheck disable=SC2016  # the $i belongs to the generated stub, not here
fake_curl() { # dir, ranges-per-call
    mkdir -p "$1"
    {
        printf '#!/bin/sh\n'
        printf 'i=0\n'
        printf 'while [ "$i" -lt %s ]; do\n' "$2"
        printf '    printf "10.0.%%s.0/24\\n" "$i"\n'
        printf '    i=$((i + 1))\n'
        printf 'done\n'
    } > "$1/curl"
    chmod +x "$1/curl"
}

cf="$work/cf"
mkdir -p "$cf/scripts" "$cf/config"
cp scripts/refresh-cloudflare-ips.sh "$cf/scripts/"
printf 'client_ip 203.0.113.0/24\n' > "$cf/config/cloudflare-ips.caddy"
seeded="$(cksum < "$cf/config/cloudflare-ips.caddy")"
target="$cf/config/cloudflare-ips.caddy"

fake_curl "$work/shim-low" 3
( cd / && PATH="$work/shim-low:$PATH" "$cf/scripts/refresh-cloudflare-ips.sh" ) \
    >"$work/low.out" 2>&1
low_status=$?
same "refuses a truncated Cloudflare response" 1 "$low_status"
same "keeps the existing list when the fetch is truncated" "$seeded" \
    "$(cksum < "$target")"

fake_curl "$work/shim-high" 12
( cd / && PATH="$work/shim-high:$PATH" "$cf/scripts/refresh-cloudflare-ips.sh" ) \
    >"$work/high.out" 2>&1
high_status=$?
same "rewrites the list on a healthy response" 0 "$high_status"
same "stores both the v4 and the v6 ranges" 24 "$(wc -l < "$target" | tr -d ' ')"
same "keeps the list readable for the unprivileged Caddy user" 644 "$(file_mode "$target")"

# ── deps.sh ───────────────────────────────────────────────────────────────────
echo "--- deps.sh"
pinned_version="$(sed -n 's/^ARG VAULTWARDEN_VERSION=//p' Dockerfile | head -n 1)"
GITHUB_OUTPUT="$work/deps-same" ./scripts/deps.sh compare \
    "VAULTWARDEN_VERSION=$pinned_version" >"$work/compare-same.out" 2>&1
same "reports no change for the value already pinned" "false" \
    "$(sed -n 's/^changed=//p' "$work/deps-same")"
GITHUB_OUTPUT="$work/deps-diff" ./scripts/deps.sh compare \
    "VAULTWARDEN_VERSION=0.0.0-selftest" >"$work/compare-diff.out" 2>&1
same "reports a change for a different value" "true" \
    "$(sed -n 's/^changed=//p' "$work/deps-diff")"
same "writes the changed flag exactly once" 1 \
    "$(grep -c '^changed=' "$work/deps-diff")"

# apply rewrites the Dockerfile in place, so it only ever runs on a throwaway
# copy that has an index for `git diff` to compare against.
apply_tree="$work/apply"
mkdir -p "$apply_tree/scripts"
cp scripts/deps.sh "$apply_tree/scripts/"
cp Dockerfile "$apply_tree/"
( cd "$apply_tree" && git init -q && git add Dockerfile ) >/dev/null 2>&1
"$apply_tree/scripts/deps.sh" apply "VAULTWARDEN_VERSION=0.0.0-selftest" \
    >"$work/apply.out" 2>&1
same "apply rewrites the pin in place" "ARG VAULTWARDEN_VERSION=0.0.0-selftest" \
    "$(grep '^ARG VAULTWARDEN_VERSION=' "$apply_tree/Dockerfile")"
same "apply prints the diff it produced" 1 \
    "$(grep -c '^+ARG VAULTWARDEN_VERSION=0.0.0-selftest$' "$work/apply.out")"
same "apply leaves no scratch file next to the Dockerfile" 1 \
    "$(find "$apply_tree" -maxdepth 1 -type f -name 'Dockerfile*' | wc -l | tr -d ' ')"
GITHUB_OUTPUT="$work/deps-applied" "$apply_tree/scripts/deps.sh" compare \
    "VAULTWARDEN_VERSION=0.0.0-selftest" >/dev/null 2>&1
same "the rewritten pin round-trips through compare" "false" \
    "$(sed -n 's/^changed=//p' "$work/deps-applied")"

# `sed` matches nothing when the name is wrong, so a typo or a renamed pin used
# to turn `apply` into a silent no-op: the workflow reported success while the
# Dockerfile still carried the old version. Validate every pair up front, before
# the first rewrite, so a rejected request leaves the file byte-identical.
guard_before="$(cksum < "$apply_tree/Dockerfile")"
apply_unknown_out="$("$apply_tree/scripts/deps.sh" apply "VAULTWARDEN_VERSION_TYPO=9.9.9" 2>&1)"
apply_unknown_status=$?
same "apply refuses a pin the Dockerfile does not declare" 2 "$apply_unknown_status"
same "apply leaves the Dockerfile untouched when it refuses" "$guard_before" \
    "$(cksum < "$apply_tree/Dockerfile")"
case "$apply_unknown_out" in
    *VAULTWARDEN_VERSION_TYPO*) ok "apply names the unknown pin in its error" ;;
    *) bad "apply does not name the unknown pin: [$apply_unknown_out]" ;;
esac

apply_empty_out="$("$apply_tree/scripts/deps.sh" apply "VAULTWARDEN_VERSION=" 2>&1)"
apply_empty_status=$?
same "apply refuses an empty value" 2 "$apply_empty_status"
same "apply keeps the Dockerfile intact after an empty value" "$guard_before" \
    "$(cksum < "$apply_tree/Dockerfile")"
case "$apply_empty_out" in
    *VAULTWARDEN_VERSION*) ok "apply names the empty-valued pin" ;;
    *) bad "apply does not name the empty-valued pin: [$apply_empty_out]" ;;
esac

apply_bad_name_out="$("$apply_tree/scripts/deps.sh" apply "BAD-NAME=1" 2>&1)"
apply_bad_name_status=$?
same "apply refuses a name that is not a shell identifier" 2 "$apply_bad_name_status"
same "apply keeps the Dockerfile intact after a bad name" "$guard_before" \
    "$(cksum < "$apply_tree/Dockerfile")"
case "$apply_bad_name_out" in
    *BAD-NAME*) ok "apply names the rejected identifier" ;;
    *) bad "apply does not name the rejected identifier: [$apply_bad_name_out]" ;;
esac

apply_no_eq_out="$("$apply_tree/scripts/deps.sh" apply "VAULTWARDEN_VERSION" 2>&1)"
apply_no_eq_status=$?
same "apply refuses a pair without a value separator" 2 "$apply_no_eq_status"
same "apply keeps the Dockerfile intact after a malformed pair" "$guard_before" \
    "$(cksum < "$apply_tree/Dockerfile")"
case "$apply_no_eq_out" in
    *NAME=VALUE*) ok "apply explains the expected NAME=VALUE form" ;;
    *) bad "apply does not explain the expected form: [$apply_no_eq_out]" ;;
esac

# Pin values come from upstream release metadata and are spliced into a sed
# replacement. A value containing `&` or `|` could rewrite the wrong text or
# corrupt the Dockerfile, and a malformed digest would silently break the build.
apply_sed_meta_out="$("$apply_tree/scripts/deps.sh" apply \
    "VAULTWARDEN_VERSION=1.2.3&boom" 2>&1)"
apply_sed_meta_status=$?
same "apply refuses a version containing sed replacement syntax" 2 \
    "$apply_sed_meta_status"
same "apply keeps the Dockerfile intact after a sed metacharacter" "$guard_before" \
    "$(cksum < "$apply_tree/Dockerfile")"
case "$apply_sed_meta_out" in
    *VAULTWARDEN_VERSION*) ok "apply names the rejected version value" ;;
    *) bad "apply does not name the rejected version value: [$apply_sed_meta_out]" ;;
esac

apply_bad_digest_out="$("$apply_tree/scripts/deps.sh" apply \
    "VAULTWARDEN_DIGEST=sha256:not-a-digest" 2>&1)"
apply_bad_digest_status=$?
same "apply refuses a malformed image digest" 2 "$apply_bad_digest_status"
same "apply keeps the Dockerfile intact after a malformed digest" "$guard_before" \
    "$(cksum < "$apply_tree/Dockerfile")"
case "$apply_bad_digest_out" in
    *VAULTWARDEN_DIGEST*) ok "apply names the malformed digest" ;;
    *) bad "apply does not name the malformed digest: [$apply_bad_digest_out]" ;;
esac

# A rejected pair must not half-apply the pairs that came before it.
"$apply_tree/scripts/deps.sh" apply "VAULTWARDEN_VERSION=1.2.3" "NOPE=4" \
    >/dev/null 2>&1
same "a rejected pair leaves earlier pairs unwritten" "$guard_before" \
    "$(cksum < "$apply_tree/Dockerfile")"

# The daily job re-runs apply with identical values, so the rewrite must be a
# no-op then: a growing diff would reopen the PR on every schedule.
# Stage the applied state first, otherwise the diff below is measured against
# the pre-apply index and shows the first run's change all over again.
( cd "$apply_tree" && git add Dockerfile ) >/dev/null 2>&1
"$apply_tree/scripts/deps.sh" apply "VAULTWARDEN_VERSION=0.0.0-selftest" \
    >"$work/apply-again.out" 2>&1
same "apply is idempotent for an unchanged value" "$guard_before" \
    "$(cksum < "$apply_tree/Dockerfile")"
same "a repeated apply produces no diff" 0 \
    "$(grep -c '^[+-]ARG ' "$work/apply-again.out")"

# `apk` needs an image to inspect. Without one it used to die on an unbound
# variable, which reads like a broken script instead of a missing argument.
apk_out="$("$REPO_ROOT/scripts/deps.sh" apk 2>&1)"
apk_status=$?
same "apk without an image exits 2" 2 "$apk_status"
case "$apk_out" in
    *usage*deps.sh\ apk*) ok "apk without an image prints its usage" ;;
    *) bad "apk without an image printed [$apk_out]" ;;
esac

# A package-only update never changes the Dockerfile, so the pin comparison
# cannot see it. Whether that needs a rebuild is a separate, testable unit.
"$REPO_ROOT/scripts/deps.sh" rebuild-needed 3 >"$work/rebuild-yes.out" 2>&1
same "a pending package upgrade asks for a rebuild" 0 "$?"
"$REPO_ROOT/scripts/deps.sh" rebuild-needed 0 >"$work/rebuild-no.out" 2>&1
same "no pending upgrade leaves the build alone" 1 "$?"
"$REPO_ROOT/scripts/deps.sh" rebuild-needed bogus >/dev/null 2>&1
same "an invalid package count is rejected" 2 "$?"

# The pinned base image ships packages that already have newer builds. `apk add`
# never touches them, so without an explicit upgrade the weekly rebuild would
# keep shipping the outdated zlib/tzdata that deps.sh apk reports.
if grep -q 'apk --no-cache upgrade' Dockerfile; then
    ok "the dependency layer upgrades the pinned base packages"
else
    bad "the dependency layer only installs new packages, so patched base packages never land"
fi

# The image ships BusyBox find, which rejects -printf. A GNU-only log size or
# mtime query fails silently there and turns the log directory cap into a no-op.
# selftest.sh itself is excluded: it carries the pattern being searched for.
if grep -q -- '-printf' scripts/*.sh tests/image-selftest.sh tests/runtime-smoke.sh; then
    bad "a script uses find -printf, which the image's BusyBox find does not support"
else
    ok "no script relies on the GNU-only find -printf"
fi

# Every outbound fetch needs a bounded wait: a stalled request otherwise holds a
# CI job open until GitHub's six-hour limit. This records the arguments curl
# actually receives, so a call site that forgets the flags fails the check.
net_log="$work/curl-args"
: > "$net_log"
net_stub="$work/curl-stub"
mkdir -p "$net_stub"
{
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >> "%s"\n' "$net_log"
    printf 'exit 0\n'
} > "$net_stub/curl"
chmod +x "$net_stub/curl"
PATH="$net_stub:$PATH" "$REPO_ROOT/scripts/deps.sh" base >/dev/null 2>&1 || true
PATH="$net_stub:$PATH" "$REPO_ROOT/scripts/refresh-cloudflare-ips.sh" >/dev/null 2>&1 || true
net_calls="$(wc -l < "$net_log" | tr -d ' ')"
net_timed="$(grep -c -- '--max-time' "$net_log" || true)"
if [ "$net_calls" -gt 0 ] && [ "$net_calls" = "$net_timed" ]; then
    ok "every dependency fetch sets a timeout (${net_timed}/${net_calls})"
else
    bad "outbound fetches without a timeout (${net_timed}/${net_calls})"
fi

# gh has no timeout flag, so deps.sh has to wrap it. Record the wrapper call and
# make sure no call site bypasses it.
# gh has no timeout flag, so deps.sh has to wrap every call. The stub release
# carries both arch assets so `tools` reaches its second gh call before the
# empty overmind download ends the run.
gh_log="$work/gh-args"
timeout_log="$work/timeout-args"
: > "$gh_log"
: > "$timeout_log"
gh_stub="$work/gh-stub"
mkdir -p "$gh_stub"
gh_release='{"tag_name":"v0","assets":[{"name":"supercronic-linux-amd64","browser_download_url":"https://example.com/a"},{"name":"supercronic-linux-arm64","browser_download_url":"https://example.com/b"}]}'
{
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >> "%s"\n' "$gh_log"
    printf 'printf "%%s\\n" %s\n' "'$gh_release'"
} > "$gh_stub/gh"
{
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >> "%s"\n' "$timeout_log"
    printf 'shift\n'
    printf 'exec "$@"\n'
} > "$gh_stub/timeout"
printf '#!/bin/sh\nexit 0\n' > "$gh_stub/curl"
chmod +x "$gh_stub/gh" "$gh_stub/timeout" "$gh_stub/curl"
PATH="$gh_stub:$PATH" "$REPO_ROOT/scripts/deps.sh" tools >/dev/null 2>&1 || true
gh_timeouts="$(grep -c -E '^[0-9]+ gh api' "$timeout_log" 2>/dev/null || true)"
same "every gh api call runs under a timeout" 2 "$gh_timeouts"

# Docker Hub can answer with an empty page (rate limit or malformed response).
# Paginating 20 times through the retry wrapper would burn the whole job.
if command -v jq >/dev/null 2>&1; then
    page_log="$work/tag-pages"
    : > "$page_log"
    page_stub="$work/page-stub"
    mkdir -p "$page_stub"
    {
        printf '#!/bin/sh\n'
        printf 'printf "page\\n" >> "%s"\n' "$page_log"
        printf 'printf "{\\"results\\":[]}\\n"\n'
    } > "$page_stub/curl"
    chmod +x "$page_stub/curl"
    PATH="$page_stub:$PATH" "$REPO_ROOT/scripts/deps.sh" base >/dev/null 2>&1 || true
    same "an empty tag page stops the pagination loop" 1 \
        "$(wc -l < "$page_log" | tr -d ' ')"
else
    bad "jq is required to test the empty-page guard"
fi

# The default tag order is neither version order nor last_updated: page 1 lists
# `latest` (2026-10-05) above `testing` (2026-10-16), and the API only sorts by
# date when asked. A republished older tag can therefore sit above the newest
# release, and taking the first match would open a dependency PR that downgrades
# a security-critical image.
if command -v jq >/dev/null 2>&1; then
    order_calls="$work/tag-order-calls"
    : > "$order_calls"
    order_stub="$work/order-stub"
    mkdir -p "$order_stub"
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" >> "%s"\n' "$order_calls"
        printf 'case "$*" in\n'
        printf '  *hub.docker.com*) printf %%s %s ;;\n' \
            "'{\"results\":[{\"name\":\"1.36.0-alpine\"},{\"name\":\"1.38.0-alpine\"},{\"name\":\"1.37.4-alpine\"}]}'"
        printf '  *auth.docker.io*) printf %%s %s ;;\n' "'{\"token\":\"stub\"}'"
        printf '  *) printf %s ;;\n' "'docker-content-digest: sha256:stub\\n'"
        printf 'esac\n'
    } > "$order_stub/curl"
    chmod +x "$order_stub/curl"
    GITHUB_OUTPUT="$work/order-out" PATH="$order_stub:$PATH" \
        "$REPO_ROOT/scripts/deps.sh" base >"$work/order.log" 2>&1
    same "the resolver picks the highest version, not the first listed" "1.38.0" \
        "$(sed -n 's/^version=//p' "$work/order-out")"
    same "the resolver resolves the manifest for that version" 1 \
        "$(grep -c 'manifests/1\.38\.0-alpine' "$order_calls")"
else
    bad "jq is required to test the version ordering guard"
fi

# ── workflow config ───────────────────────────────────────────────────────────
echo "--- workflow config"
# fly.toml carries the machine config, and only a deploy applies it. If the
# build workflow ignores fly.toml, a config-only commit deploys nothing at all.
# Psych parses the bare `on:` key as boolean true, hence the fallback.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/ghcr.yml")
    push = (doc["on"] || doc[true])["push"] || {}
    exit 1 if Array(push["paths-ignore"]).include?("fly.toml")
  '; then
    ok "ghcr.yml rebuilds and redeploys when fly.toml changes"
else
    bad "ghcr.yml ignores fly.toml, so a config-only commit would never deploy"
fi

# A push to main already builds the multi-arch image in the Docker workflow and
# deploys that exact digest. Rebuilding the same Dockerfile in Validate doubles
# every merge's build work, so the image steps must stay on the pre-merge
# events and ghcr.yml must not keep conditions for an event it never receives.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/validate.yml")
    steps = doc["jobs"]["validate"]["steps"]
    heavy = steps.select { |s| (s["run"] || "").include?("validate:local") }
    exit 1 if heavy.empty?
    exit 1 unless heavy.all? { |s| (s["if"] || "").include?("push") }
  '; then
    ok "validate.yml skips the image build on pushes to main"
else
    bad "validate.yml rebuilds the image on every push to main, duplicating the Docker workflow"
fi

# shellcheck disable=SC2016  # the literal workflow expression, not shell code
if ! ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/ghcr.yml")
    exit 1 if (doc["on"] || doc[true]).key?("pull_request")
  ' || grep -qF "github.event_name != 'pull_request'" .github/workflows/ghcr.yml; then
    bad "ghcr.yml keeps pull_request-only conditions although the workflow has no pull_request trigger"
else
    ok "ghcr.yml has no conditions for an event it never receives"
fi

# The image that actually reaches Fly is the one the Docker workflow publishes.
# Booting that exact digest before the artifact is uploaded is the only runtime
# gate on the merge path, and both workflows share one implementation.
if ruby -ryaml -e '
    runs = YAML.load_file(".github/workflows/ghcr.yml")["jobs"]["build"]["steps"]
              .map { |s| s["run"] || "" }.join("\n")
    exit 1 unless runs.include?("tests/runtime-smoke.sh")
    steps = YAML.load_file(".github/workflows/validate.yml")["jobs"]["validate"]["steps"]
    exit 1 unless steps.any? { |s| (s["run"] || "").include?("tests/runtime-smoke.sh") }
    exit 1 if steps.any? { |s| (s["run"] || "").include?("docker cp tests/") }
  '; then
    ok "the published image is smoke tested, through one shared script"
else
    bad "ghcr.yml does not smoke test the published image, or the smoke test is duplicated inline"
fi

# The daily dependency job reports pending package upgrades, but nothing failed
# when the image that actually gets deployed still carried them.
if ruby -ryaml -e '
    runs = YAML.load_file(".github/workflows/ghcr.yml")["jobs"]["build"]["steps"]
              .map { |s| s["run"] || "" }.join("\n")
    exit 1 unless runs.include?("deps.sh apk")
  '; then
    ok "the build fails when the published image still has upgradable packages"
else
    bad "nothing gates the published image on pending package upgrades"
fi

# GitHub stops scheduled workflows without saying so: the nightly tag cleanup
# last ran on 2026-01-03, so the 30-day expiry the README promises was not
# enforced. The build has to expire old tags itself when the schedule is stale.
if ruby -ryaml -e '
    steps = YAML.load_file(".github/workflows/ghcr.yml")["jobs"]["build"]["steps"]
    expiry = steps.select { |s| s["uses"].to_s.include?(".github/actions/expire-tags") }
    exit 1 if expiry.empty?
    exit 1 if expiry.all? { |s| (s["if"] || "").empty? }
    exit 1 unless steps.any? { |s| (s["run"] || "").include?("event=schedule") }
    nightly = YAML.load_file(".github/workflows/ghcr-cleanup.yml")["jobs"]["cleanup"]["steps"]
    exit 1 unless nightly.any? { |s| s["uses"].to_s.include?(".github/actions/expire-tags") }
    shared = YAML.load_file(".github/actions/expire-tags/action.yml")
    exit 1 unless (shared["runs"]["steps"][0]["with"]["delete-tags"] || "").include?("[0-9]{12}")
  '; then
    ok "the build expires old timestamp tags when the nightly cleanup is behind"
else
    bad "tag expiry depends on a GitHub schedule that can stop silently, or the two call sites diverged"
fi

if ruby -ryaml -e '
    runner = YAML.load_file(".github/workflows/ghcr-cleanup.yml")["jobs"]["cleanup"]["runs-on"]
    exit 1 if runner.to_s.include?("latest")
  '; then
    ok "the cleanup job pins its runner instead of tracking ubuntu-latest"
else
    bad "the cleanup job runs on a floating ubuntu-latest runner"
fi

# The monthly verify must not share a minute with the hourly backup: restic
# refuses the exclusive lock by default, so the check failed instantly with
# "repo already locked" instead of verifying anything.
verify_minute="$(awk '/\/restic\.sh verify$/ {print $1}' config/crontab | head -n 1)"
if [ -n "$verify_minute" ] && [ "$verify_minute" != "0" ]; then
    ok "the monthly verify avoids the top of the hour (minute ${verify_minute})"
else
    bad "the monthly verify fires at minute 0, the same minute as @hourly backup"
fi

# The daily check only opened a PR when a pin changed, so an Alpine-only
# security update waited for the weekly rebuild. The apk probe has to run every
# day, and a non-zero count has to dispatch the build workflow.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/security-updates.yml")
    steps = doc["jobs"]["check"]["steps"]
    apk = steps.find { |s| (s["run"] || "").include?("deps.sh apk") }
    exit 1 if apk.nil? || apk.key?("if")
    rebuild = steps.find { |s| (s["run"] || "").include?("rebuild-needed") }
    exit 1 if rebuild.nil?
    exit 1 unless (rebuild["run"] || "").include?("gh workflow run")
    exit 1 unless (rebuild["if"] || "").include?("success()")
    exit 1 unless (doc["permissions"] || {})["actions"] == "write"
  '; then
    ok "the daily check probes packages every run and dispatches a rebuild when needed"
else
    bad "package-only updates still wait for the weekly rebuild"
fi

# workflow_run never fired for a workflow_dispatch build, so a manual rebuild
# published an image that never reached Fly. The deploy has to live in the same
# workflow, and the separate workflow must be gone to avoid double deploys.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/ghcr.yml")
    deploy = doc["jobs"]["deploy"]
    exit 1 if deploy.nil?
    exit 1 unless Array(deploy["needs"]).include?("build")
    exit 1 unless (deploy["if"] || "").include?("refs/heads/main")
    steps = deploy["steps"] || []
    guard = steps.find { |s| s["id"] == "guard" }
    exit 1 if guard.nil? || guard["id"].to_s.empty?
    exit 1 unless (guard["run"] || "").include?("skip=true")
    release = steps.find { |s| (s["run"] || "").include?("flyctl deploy") }
    exit 1 if release.nil?
    exit 1 unless (release["run"] || "").include?("--image")
    exit 1 unless (release["if"] || "").include?("steps.guard.outputs.skip")
    exit 1 unless (deploy["concurrency"] || {})["group"] == "fly-deploy"
    exit 1 if File.exist?(".github/workflows/deploy.yml")
  '; then
    ok "the build workflow deploys its own digest, for pushes and manual rebuilds"
else
    bad "manual rebuilds publish an image that never reaches Fly, or deploys are duplicated"
fi

# The `gh api` calls in ghcr.yml need the same bound as the ones in deps.sh:
# gh has no timeout flag of its own.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/ghcr.yml")
    runs = doc["jobs"].values.flat_map { |j| (j["steps"] || []).map { |s| s["run"] || "" } }.join("\n")
    unbounded = runs.lines.select { |l| l.include?("gh api") && !l.include?("timeout") }
    exit 1 unless unbounded.empty?
  '; then
    ok "ghcr.yml bounds every gh api call"
else
    bad "ghcr.yml calls gh api without a timeout"
fi

# The cleanup guard used to swallow an unreadable schedule with `|| true`, so an
# API failure was reported as "no scheduled run found", and the early exit also
# skipped the dependency-schedule warning. Run the real step body with a stub gh.
ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/ghcr.yml")
    step = doc["jobs"]["build"]["steps"].find { |s| s["id"] == "cleanup-check" }
    print step["run"]
  ' > "$work/cleanup-check.sh"
guard_stub="$work/guard-stub"
guard_out="$work/guard-out"
mkdir -p "$guard_stub"
run_guard() { # gh exit status
    : > "$guard_out"
    {
        printf '#!/bin/sh\n'
        printf 'exit %s\n' "$1"
    } > "$guard_stub/gh"
    chmod +x "$guard_stub/gh"
    GITHUB_OUTPUT="$guard_out" GITHUB_REPOSITORY=example/repo \
        PATH="$guard_stub:$PATH" bash "$work/cleanup-check.sh" > "$work/guard-run.log" 2>&1
}
run_guard 1
if grep -q 'could not read the cleanup schedule' "$work/guard-run.log"; then
    ok "an unreadable cleanup schedule is reported as such"
else
    bad "an unreadable cleanup schedule is misreported as an empty one"
fi
same "an unreadable cleanup schedule still requests the sweep" "needed=true" \
    "$(grep '^needed=' "$guard_out" | tail -n 1)"
run_guard 0
if grep -q 'no scheduled dependency check has ever run' "$work/guard-run.log"; then
    ok "the dependency-schedule warning still runs when the cleanup has no record"
else
    bad "the dependency-schedule warning is skipped by an early exit"
fi

# `paths-ignore` means a README-only commit never triggers this workflow, so
# "main moved" is not proof that a newer build will take over. A doc-only merge
# during a build window used to cancel the deployment of the commit being built,
# leaving the code change unpublished until the next code push. Run the real
# guard body with a stub gh that answers both queries.
ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/ghcr.yml")
    deploy = doc["jobs"]["deploy"]
    step = (deploy["steps"] || []).find { |s| s["id"] == "guard" }
    exit 1 if step.nil?
    exit 1 unless (deploy["permissions"] || {})["actions"] == "read"
    print step["run"]
  ' > "$work/deploy-guard.sh" || true
if [ -s "$work/deploy-guard.sh" ]; then
    deploy_stub="$work/deploy-stub"
    deploy_out="$work/deploy-out"
    mkdir -p "$deploy_stub"
    deploy_stub_case() { # main-tip sha, newest-run sha, runs-query exit code
        {
            printf '#!/bin/sh\n'
            printf 'case "$*" in\n'
            printf '  *git/ref/heads/main*) printf "%%s\\n" %s ;;\n' "'$1'"
            printf '  *workflows/ghcr.yml/runs*)\n'
            if [ "$3" = "0" ]; then
                printf '    printf "%%s\\n" %s\n' "'$2'"
            fi
            printf '    exit %s\n' "$3"
            printf '    ;;\n'
            printf '  *) exit 1 ;;\n'
            printf 'esac\n'
        } > "$deploy_stub/gh"
        chmod +x "$deploy_stub/gh"
    }
    run_deploy_guard() {
        : > "$deploy_out"
        GITHUB_OUTPUT="$deploy_out" GITHUB_REPOSITORY=example/repo GITHUB_SHA=abc123 \
            PATH="$deploy_stub:$PATH" bash "$work/deploy-guard.sh" \
            > "$work/deploy-run.log" 2>&1
    }
    deploy_skip() { grep '^skip=' "$deploy_out" | tail -n 1 | cut -d= -f2; }

    # main moved to a doc-only commit that never started a run: still deploy.
    deploy_stub_case doc999 abc123 0
    run_deploy_guard
    same "a doc-only commit on main does not cancel the deploy" "false" "$(deploy_skip)"

    # a newer commit did start its own run: stand down for it.
    deploy_stub_case def456 def456 0
    run_deploy_guard
    same "a newer run of this workflow supersedes this build" "true" "$(deploy_skip)"

    # the run list cannot be read: deploy, and say why.
    deploy_stub_case doc999 "" 1
    run_deploy_guard
    same "an unreadable run list still deploys" "false" "$(deploy_skip)"
    if grep -q 'could not read the workflow runs' "$work/deploy-run.log"; then
        ok "an unreadable run list is reported"
    else
        bad "an unreadable run list is swallowed"
    fi
else
    bad "the deploy guard step or its actions:read permission is missing"
fi

# The dependency job has two places that turned a real failure into a reassuring
# message: `gh pr create ... || echo "PR already exists"` and a status-check poll
# that read an API error as "no checks registered". Both leave the operator
# chasing the wrong cause, so assert the behaviour with stubs.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/security-updates.yml")
    step = (doc["jobs"]["check"]["steps"] || []).find { |s| s["id"] == "pr" }
    exit 1 if step.nil?
    body = step["run"] || ""
    exit 1 if body.include?("|| echo")
    exit 1 unless body.include?("gh pr list")
  '; then
    ok "the dependency PR step checks for an existing PR instead of swallowing failures"
else
    bad "the dependency PR step reports every gh pr create failure as an existing PR"
fi

# A version-named branch creates a new PR when the upstream version moves while
# an older auto-merge PR is still open. The old PR can then merge stale pins
# after the newer one. Keep one stable automation branch, and update its title
# and body when it already has an open PR.
# shellcheck disable=SC2016  # Ruby source, not shell expansion
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/security-updates.yml")
    step = (doc["jobs"]["check"]["steps"] || []).find { |s| s["id"] == "pr" }
    body = step && (step["run"] || "")
    exit 1 if body.nil? || body.empty?
    exit 1 unless body.include?("branch=\"deps/upstream\"")
    exit 1 if body.include?("branch=\"deps/upstream-${VERSION}\"")
    exit 1 unless body.include?("gh pr list") && body.include?("--state open")
    exit 1 unless body.include?("gh pr edit")
  '; then
    ok "dependency PRs use one stable branch and refresh an existing open PR"
else
    bad "dependency PRs use a version branch that can leave a stale auto-merge PR behind"
fi

# Execute the real PR step with stub git/gh commands. This proves the stable
# branch is not just present in YAML: an existing open PR is updated in place,
# and a missing PR is created.
ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/security-updates.yml")
    step = (doc["jobs"]["check"]["steps"] || []).find { |s| s["id"] == "pr" }
    print step["run"] if step
  ' > "$work/pr-step.sh" || true
if [ -s "$work/pr-step.sh" ]; then
    pr_stub="$work/pr-stub"
    pr_log="$work/pr-gh.log"
    pr_out="$work/pr-output"
    mkdir -p "$pr_stub"
    # shellcheck disable=SC2016  # generated stub, not shell expansion
    {
        printf '#!/bin/sh\n'
        printf 'case "$1" in\n'
        printf '  diff) exit 1 ;;\n'
        printf '  *) exit 0 ;;\n'
        printf 'esac\n'
    } > "$pr_stub/git"
    # shellcheck disable=SC2016  # generated stub, not shell expansion
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" >> "%s"\n' "$pr_log"
        printf 'case "$1 $2" in\n'
        printf '  "pr list") printf "%%s\\n" "${OPEN_PR_COUNT:-0}" ;;\n'
        printf 'esac\n'
        printf 'exit 0\n'
    } > "$pr_stub/gh"
    chmod +x "$pr_stub/git" "$pr_stub/gh"
    run_pr_step() { # open-pr count
        : > "$pr_log"
        : > "$pr_out"
        GITHUB_OUTPUT="$pr_out" GITHUB_REPOSITORY=example/repo RUNNER_TEMP="$work" \
            VERSION=1.2.3 DIGEST=sha256:stub SUPERCRONIC=v0 OVERMIND=v0 \
            APK_COUNT=0 APK_ROWS='' OPEN_PR_COUNT="$1" \
            PATH="$pr_stub:$PATH" bash "$work/pr-step.sh" \
            > "$work/pr-run.log" 2>&1
    }

    run_pr_step 1
    same "an existing open dependency PR is updated" 0 "$?"
    same "the stable dependency branch is recorded" "deps/upstream" \
        "$(sed -n 's/^branch=//p' "$pr_out")"
    same "an existing open dependency PR does not create a duplicate" 0 \
        "$(grep -c '^pr create' "$pr_log")"
    same "an existing open dependency PR is refreshed" 1 \
        "$(grep -c '^pr edit' "$pr_log")"

    run_pr_step 0
    same "a missing dependency PR is created" 1 \
        "$(grep -c '^pr create' "$pr_log")"
    same "a missing dependency PR is not edited" 0 \
        "$(grep -c '^pr edit' "$pr_log")"
else
    bad "the dependency PR step could not be extracted for execution"
fi

ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/security-updates.yml")
    step = (doc["jobs"]["check"]["steps"] || []).find { |s| s["id"] == "arm" }
    print step["run"] if step
  ' > "$work/arm-merge.sh" || true
if [ -s "$work/arm-merge.sh" ]; then
    arm_stub="$work/arm-stub"
    mkdir -p "$arm_stub"
    # The poll sleeps 10s between 18 attempts; the stub keeps the test instant.
    printf '#!/bin/sh\nexit 0\n' > "$arm_stub/sleep"
    chmod +x "$arm_stub/sleep"
    arm_stub_case() { # mode: count <n> | fail
        {
            printf '#!/bin/sh\n'
            printf 'case "$*" in\n'
            printf '  *"pr merge"*) exit 0 ;;\n'
            case "$1" in
                fail) printf '  *) exit 1 ;;\n' ;;
                *)    printf '  *) printf "%%s\\n" %s ;;\n' "'$2'" ;;
            esac
            printf 'esac\n'
        } > "$arm_stub/gh"
        chmod +x "$arm_stub/gh"
    }
    run_arm() {
        BRANCH=deps/upstream-1.0.0 GITHUB_REPOSITORY=example/repo \
            PATH="$arm_stub:$PATH" bash "$work/arm-merge.sh" > "$work/arm-run.log" 2>&1
    }

    arm_stub_case count 2
    run_arm
    same "arming auto-merge succeeds once checks register" 0 "$?"
    same "arming auto-merge reports how many checks registered" 1 \
        "$(grep -c 'auto-merge armed; 2 status check(s)' "$work/arm-run.log")"

    arm_stub_case fail
    run_arm
    same "an unreadable check list fails the step" 1 "$?"
    if grep -q 'could not read the status checks' "$work/arm-run.log"; then
        ok "an unreadable check list is reported as such"
    else
        bad "an unreadable check list is misreported as a missing check"
    fi
else
    bad "the auto-merge step is missing or has no id to select it by"
fi

# ── docs consistency ──────────────────────────────────────────────────────────
echo "--- docs"
# The build workflow deploys the freshly built digest with `fly deploy --image`,
# and fly.toml deliberately keeps no image pin. A README that still tells the
# reader to edit a fly.toml image pin sends them to a value that does not exist.
if grep -q 'replace the value in fly.toml' README.md; then
    bad "README still points readers at a fly.toml image pin that was removed"
else
    ok "README no longer references a removed fly.toml image pin"
fi

if grep -q -- '--image' README.md; then
    ok "README documents that the build workflow passes --image"
else
    bad "README does not explain how the built digest reaches Fly"
fi

# The health check and the restart policy are separate mechanisms: Fly pulls a
# machine out of service when /alive fails, and the machine-level restart policy
# restarts a container that exits. Describing one as the other misleads during
# an incident, so keep the troubleshooting row on the real mechanism.
if grep -qi 'no longer marked restartable' README.md; then
    bad "README explains a container exit with a health-check mechanism"
else
    ok "README keeps the restart policy distinct from the health check"
fi

# The run log records whether the alert was delivered, so the old advice to go
# hunting through the mailer's stderr is no longer the right pointer.
if grep -q 'msmtp writes to stderr' README.md; then
    bad "README still points alert debugging at the mailer's stderr"
else
    ok "README points alert debugging at the recorded outcome"
fi

# "Ping on every run" reads as "the success URL on every run", which would leave
# an operator believing a failing backup still reports in. The documented call
# sites and the failure URL have to match what heartbeat() actually does.
if grep -q -- '/fail' README.md; then
    ok "README documents the failure URL the ping uses"
else
    bad "README does not say which URL the failure ping targets"
fi

# The runtime smoke test is the only check that proves a message is delivered,
# so the verification list has to point at it instead of leaving it undiscovered.
if grep -q 'runtime-smoke.sh' README.md; then
    ok "README lists the runtime smoke test in its verification commands"
else
    bad "README does not mention tests/runtime-smoke.sh"
fi

# A destructive command that is documented without its guard is a trap: the
# reader copies the command, gets an error, and goes looking for a workaround.
if grep -q 'RESTORE_CONFIRM=yes' README.md; then
    ok "README documents the in-place restore confirmation"
else
    bad "README shows restore without its RESTORE_CONFIRM guard"
fi

# The database is not in the snapshot, so a recovery guide that stops at
# `restore` leaves the reader with an instance that never loaded the backup.
if grep -q 'restore-pending' README.md; then
    ok "README documents how the restored database reaches /data/db.sqlite3"
else
    bad "README does not explain the database swap after restore"
fi

# The README documents these knobs and the template is what a local run copies,
# so a missing entry means the operator silently gets a default instead.
missing_env=""
for name in BACKUP_MAX_AGE RESTIC_LOG_DIR RESTIC_LOG_MAX_BYTES RESTIC_LOG_DIR_MAX_BYTES \
    RESTIC_QUICK_TIMEOUT RESTIC_LONG_TIMEOUT SUPERVISE_RESTART_DELAY VERIFY_SUBSET; do
    grep -q "^${name}=" .env.example || missing_env="${missing_env} ${name}"
done
if [ -z "$missing_env" ]; then
    ok "every documented tuning variable appears in .env.example"
else
    bad "missing from .env.example:${missing_env}"
fi

echo
report "helper self tests"
