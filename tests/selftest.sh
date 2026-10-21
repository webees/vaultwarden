#!/bin/bash
# Reproducible checks for the helper scripts. No network, no restic repository
# and no production access: every case runs against a local fixture.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── static process model ─────────────────────────────────────────────────────
echo "--- process model"
# Three long-running processes do not justify a downloaded process manager.
# Keep the privilege-dropping bootstrap and the process table in separate,
# reviewable files so neither has to carry the other's concerns.
if grep -Eqi 'overmind|tmux|Procfile|supervise\.sh' \
    Dockerfile scripts/entrypoint.sh scripts/entrypoint/*.sh scripts/services.sh; then
    bad "the image still depends on the removed dynamic process manager"
else
    ok "the image has no Overmind, tmux, Procfile or supervise.sh dependency"
fi
for removed in config/Procfile scripts/supervise.sh; do
    if [ -e "$removed" ]; then
        bad "${removed} still exists even though the entrypoint owns the process table"
    else
        ok "${removed} is absent"
    fi
done
if grep -Fq 'run_services' scripts/entrypoint.sh; then
    bad "the bootstrap still carries the process table"
else
    ok "the bootstrap delegates process supervision"
fi
for script in scripts/entrypoint.sh scripts/entrypoint/*.sh scripts/services.sh; do
    if [ -f "$script" ]; then
        ok "${script} exists"
    else
        bad "${script} is missing"
    fi
done
for module in filesystem config restore smtp; do
    if grep -Fq "entrypoint/${module}.sh" scripts/entrypoint.sh; then
        ok "the bootstrap sources the ${module} entrypoint module"
    else
        bad "the bootstrap does not source the ${module} entrypoint module"
    fi
done
for service in '/vaultwarden' 'caddy run --config /Caddyfile' 'supercronic /crontab'; do
    if grep -Fq "$service" scripts/services.sh 2>/dev/null; then
        ok "the static process table starts ${service%% *}"
    else
        bad "the static process table does not start ${service}"
    fi
done
if grep -Fq 'scripts/services.sh' Dockerfile; then
    ok "the image copies the dedicated process table"
else
    bad "the image does not copy scripts/services.sh"
fi

# The Cloudflare ranges are deliberately checked in. A build-time fetch made the
# image depend on an unrelated live endpoint and could rewrite tracked source.
# Validate the pinned data itself so a truncated or duplicated snapshot cannot
# pass on line count alone.
if cloudflare_ranges="$(python3 - config/cloudflare_ips.caddy <<'PY'
import ipaddress
import pathlib
import sys

ranges = []
for number, line in enumerate(pathlib.Path(sys.argv[1]).read_text().splitlines(), 1):
    fields = line.split()
    if not fields or fields[0].startswith("#"):
        continue
    if len(fields) != 2 or fields[0] != "client_ip":
        raise SystemExit(f"line {number}: expected 'client_ip <CIDR>'")
    try:
        network = ipaddress.ip_network(fields[1], strict=True)
    except ValueError as error:
        raise SystemExit(f"line {number}: {error}") from error
    ranges.append(network)

if len(ranges) < 20:
    raise SystemExit(f"only {len(ranges)} ranges; expected at least 20")
if len(ranges) != len(set(ranges)):
    raise SystemExit("duplicate range")
print(len(ranges))
PY
)"; then
    ok "the static Cloudflare range list is valid (${cloudflare_ranges} ranges)"
else
    bad "the static Cloudflare range list is truncated, duplicated or invalid"
fi

# ── deps.sh ───────────────────────────────────────────────────────────────────
echo "--- deps.sh"
pinned_version="$(sed -n 's/^ARG VAULTWARDEN_VERSION=//p' Dockerfile | head -n 1)"

# Docker Hub stubs share the same auth and digest responses. The first two
# repository pages are supplied by the caller; later pages are empty.
make_dockerhub_stub() {
    local dir="$1" calls="$2" first="$3" second="${4:-}"
    [ -n "$second" ] || second='{"results":[]}'
    mkdir -p "$dir"
    : > "$calls"
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" >> %q\n' "$calls"
        printf 'case "$*" in\n'
        printf '  *page=1*) printf %%s %q ;;\n' "$first"
        printf '  *page=2*) printf %%s %q ;;\n' "$second"
        printf '  *hub.docker.com*) printf %%s %q ;;\n' '{"results":[]}'
        printf '  *auth.docker.io*) printf %%s %q ;;\n' '{"token":"stub"}'
        printf '  *) printf %%s %q ;;\n' 'docker-content-digest: sha256:stub'
        printf 'esac\n'
    } > "$dir/curl"
    chmod +x "$dir/curl"
}

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

# The two-hour job re-runs apply with identical values, so the rewrite must be a
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
if grep -q -- '-printf' scripts/*.sh scripts/entrypoint/*.sh \
    tests/image_selftest.sh tests/runtime_smoke.py; then
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
net_calls="$(wc -l < "$net_log" | tr -d ' ')"
net_timed="$(grep -c -- '--max-time' "$net_log" || true)"
if [ "$net_calls" -gt 0 ] && [ "$net_calls" = "$net_timed" ]; then
    ok "every dependency fetch sets a timeout (${net_timed}/${net_calls})"
else
    bad "outbound fetches without a timeout (${net_timed}/${net_calls})"
fi

# gh has no timeout flag, so deps.sh has to wrap it. Record the wrapper call and
# make sure no call site bypasses it.
# gh has no timeout flag, so deps.sh has to wrap every call.
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
same "every gh api call runs under a timeout" 1 "$gh_timeouts"

# Docker Hub can answer with an empty page (rate limit or malformed response).
# Paginating 20 times through the retry wrapper would burn the whole job.
if command -v jq >/dev/null 2>&1; then
    page_log="$work/tag-pages"
    page_stub="$work/page-stub"
    make_dockerhub_stub "$page_stub" "$page_log" '{"results":[]}'
    PATH="$page_stub:$PATH" "$REPO_ROOT/scripts/deps.sh" base >/dev/null 2>&1 || true
    same "an empty tag page stops the pagination loop" 1 \
        "$(grep -c 'hub.docker.com' "$page_log")"
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
    order_stub="$work/order-stub"
    make_dockerhub_stub "$order_stub" "$order_calls" \
        '{"results":[{"name":"1.36.0-alpine"},{"name":"1.38.0-alpine"},{"name":"1.37.4-alpine"}]}'
    GITHUB_OUTPUT="$work/order-out" PATH="$order_stub:$PATH" \
        "$REPO_ROOT/scripts/deps.sh" base >"$work/order.log" 2>&1
    same "the resolver picks the highest version, not the first listed" "1.38.0" \
        "$(sed -n 's/^version=//p' "$work/order-out")"
    same "the resolver resolves the manifest for that version" 1 \
        "$(grep -c 'manifests/1\.38\.0-alpine' "$order_calls")"
else
    bad "jq is required to test the version ordering guard"
fi

# Docker Hub does not guarantee version order across pages. Stopping at the
# first page that contains any stable tag can therefore select an older release
# while a newer one sits on the next page.
if command -v jq >/dev/null 2>&1; then
    cross_calls="$work/tag-cross-page-calls"
    cross_stub="$work/tag-cross-page-stub"
    make_dockerhub_stub "$cross_stub" "$cross_calls" \
        '{"results":[{"name":"1.30.0-alpine"}],"next":"https://hub.docker.com/v2/repositories/vaultwarden/server/tags?page=2&page_size=100"}' \
        '{"results":[{"name":"1.99.0-alpine"}],"next":null}'
    GITHUB_OUTPUT="$work/cross-page-out" PATH="$cross_stub:$PATH" \
        "$REPO_ROOT/scripts/deps.sh" base >"$work/cross-page.log" 2>&1
    same "the resolver scans every page for the highest release" "1.99.0" \
        "$(sed -n 's/^version=//p' "$work/cross-page-out")"
    same "the resolver uses the manifest for the newest release across pages" 1 \
        "$(grep -c 'manifests/1\.99\.0-alpine' "$cross_calls")"
else
    bad "jq is required to test cross-page version ordering"
fi

# A temporarily incomplete first page must never move the pin backwards. Treat
# the version already pinned in the Dockerfile as the floor for resolution.
if command -v jq >/dev/null 2>&1; then
    floor_calls="$work/tag-floor-calls"
    floor_stub="$work/tag-floor-stub"
    make_dockerhub_stub "$floor_stub" "$floor_calls" \
        '{"results":[{"name":"1.30.0-alpine"}],"next":"https://hub.docker.com/v2/repositories/vaultwarden/server/tags?page=2&page_size=100"}' \
        '{"results":[]}'
    GITHUB_OUTPUT="$work/floor-out" PATH="$floor_stub:$PATH" \
        "$REPO_ROOT/scripts/deps.sh" base >"$work/floor.log" 2>&1
    same "an incomplete tag list never downgrades the pinned version" "$pinned_version" \
        "$(sed -n 's/^version=//p' "$work/floor-out")"
    same "the resolver uses the manifest for the pinned version floor" 1 \
        "$(grep -c "manifests/${pinned_version}-alpine" "$floor_calls")"
else
    bad "jq is required to test the pinned-version floor"
fi

# A malformed HTTP-200 response is not an empty repository. Fail the dependency
# check instead of turning an API schema change or proxy response into success.
if command -v jq >/dev/null 2>&1; then
    malformed_stub="$work/tag-malformed-stub"
    make_dockerhub_stub "$malformed_stub" "$work/tag-malformed-calls" \
        '{"message":"rate limited"}'
    malformed_status=0
    GITHUB_OUTPUT="$work/malformed-out" PATH="$malformed_stub:$PATH" \
        "$REPO_ROOT/scripts/deps.sh" base >"$work/malformed.log" 2>&1 \
        || malformed_status=$?
    same "a malformed Docker Hub response fails the resolver" 1 "$malformed_status"
    case "$(cat "$work/malformed.log")" in
        *"malformed Docker Hub tag response"*)
            ok "the resolver names the malformed Docker Hub response"
            ;;
        *)
            bad "the resolver does not distinguish a malformed page from an empty page"
            ;;
    esac
else
    bad "jq is required to test malformed Docker Hub responses"
fi

# The next-page URL is untrusted API data. Follow only the exact Docker Hub
# endpoint so a compromised or malformed response cannot redirect the resolver
# to a different host.
if command -v jq >/dev/null 2>&1; then
    redirect_stub="$work/tag-redirect-stub"
    make_dockerhub_stub "$redirect_stub" "$work/tag-redirect-calls" \
        '{"results":[{"name":"1.37.4-alpine"}],"next":"https://attacker.invalid/steal"}'
    redirect_status=0
    GITHUB_OUTPUT="$work/redirect-out" PATH="$redirect_stub:$PATH" \
        "$REPO_ROOT/scripts/deps.sh" base >"$work/redirect.log" 2>&1 \
        || redirect_status=$?
    same "an off-host pagination URL fails the resolver" 1 "$redirect_status"
    case "$(cat "$work/redirect.log")" in
        *"unexpected Docker Hub next-page URL"*)
            ok "the resolver rejects an off-host pagination URL"
            ;;
        *)
            bad "the resolver followed a pagination URL outside Docker Hub"
            ;;
    esac
else
    bad "jq is required to test Docker Hub pagination URLs"
fi

# ── .github naming ────────────────────────────────────────────────────────────
echo "--- .github naming"
# GitHub resolves these files by name, prints that name in the Actions UI and
# puts it in every API path, so keep one convention: lowercase snake_case, and
# `.yml` everywhere so a `*.yml` glob cannot silently miss a file.
if ruby -e '
    snake = /\A[a-z0-9]+(_[a-z0-9]+)*\z/
    problems = []
    Dir.glob(".github/**/*").sort.each do |path|
      next if File.directory?(path)
      base = File.basename(path)
      dir = File.dirname(path)
      ext = File.extname(base)
      problems << "#{path}: expected the .yml extension" if ext != ".yml"
      problems << "#{path}: file name is not snake_case" unless base.delete_suffix(ext).match?(snake)
      if dir.start_with?(".github/actions/") && !File.basename(dir).match?(snake)
        problems << "#{path}: action folder is not snake_case"
      end
    end
    problems.each { |problem| warn problem }
    exit 1 unless problems.empty?
  '; then
    ok "every .github file and action folder is lowercase snake_case and .yml"
else
    bad "a .github file name or action folder breaks the snake_case convention"
fi

# The file name is what `gh workflow run`, the API paths and the Actions UI
# all reference. A file named after its registry (the old `ghcr.yml`) hid the
# fact that this workflow also rolls the image out to production, and a file
# name that drifts from the display name makes the two disagree in the UI.
if ruby -ryaml -e '
    Dir[".github/workflows/*.yml"].sort.each do |path|
      stem = File.basename(path, ".yml")
      display = (YAML.load_file(path)["name"] || "").downcase.gsub(/[^a-z0-9]+/, "_")
      unless display.include?(stem)
        warn "#{path}: display name #{display.inspect} does not contain #{stem.inspect}"
        exit 1
      end
    end
  '; then
    ok "every workflow file is named after what it does, and matches its display name"
else
    bad "a workflow file name does not describe the workflow, or disagrees with its display name"
fi

# ── workflow config ───────────────────────────────────────────────────────────
echo "--- workflow config"
# Every push to main rolled a new production release, including commits that can
# not change the image at all: the workflow rename on 2026-10-19T02:10Z rebuilt
# both architectures and deployed a release for a `.github`-only change.
# `.gitignore` slipped through the same way on 2026-10-19T04:23Z, so it is
# asserted separately: the smoke-suite commit touched nothing else that builds.
#
# The ignore list has to stay inside what `.dockerignore` keeps out of the build
# context, so nothing the image is built from can ever be skipped. fly.toml is
# the deliberate exception: it is not in the image, but only `flyctl deploy`
# applies the machine config, so a config-only commit still has to deploy.
# Psych parses the bare `on:` key as boolean true, hence the fallback.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/build_and_deploy.yml")
    push = (doc["on"] || doc[true])["push"] || {}
    ignored = Array(push["paths-ignore"])
    excluded = File.readlines(".dockerignore").map(&:strip)
    exit 1 if ignored.empty?
    exit 1 if ignored.include?("fly.toml")
    ignored.each do |entry|
      exit 1 unless excluded.include?(entry.sub(%r{/\*\*\z}, ""))
    end
    exit 1 unless ignored.include?(".github/**")
    exit 1 unless ignored.include?("tests/**")
    exit 1 unless ignored.include?(".gitignore")
  '; then
    ok "the build runs for every commit that can change the image, and skips the rest"
else
    bad "a commit that cannot change the image still rebuilds and redeploys, or an ignored path is built into the image"
fi

# The Fly app name is personal data, so it must never be committed: fly.toml
# carries no `app` key and the deploy step reads it from a repository secret,
# which also makes flyctl's own output masked in this public repo's logs.
if ruby -ryaml -e '
    exit 1 if File.read("fly.toml") =~ /^\s*app\s*=/
    release = YAML.load_file(".github/workflows/build_and_deploy.yml")
      .dig("jobs", "deploy", "steps")
      .find { |s| s["name"].to_s.include?("Release") }
    exit 1 unless release
    exit 1 unless (release["env"] || {})["FLY_APP"].to_s.include?("secrets.FLY_APP")
    run = release["run"].to_s
    exit 1 unless run =~ /--app\s+"[^A-Za-z0-9"]/
  '; then
    ok "fly.toml keeps no app name and the deploy reads it from a secret"
else
    bad "fly.toml or the deploy step hardcodes the Fly app name"
fi

# A push to main already builds the multi-arch image in the Docker workflow and
# deploys that exact digest. Rebuilding the same Dockerfile in Validate doubles
# every merge's build work, so the image steps must stay on the pre-merge
# events and build_and_deploy.yml must not keep conditions for an event it
# never receives.
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
    doc = YAML.load_file(".github/workflows/build_and_deploy.yml")
    exit 1 if (doc["on"] || doc[true]).key?("pull_request")
  ' || grep -qF "github.event_name != 'pull_request'" .github/workflows/build_and_deploy.yml; then
    bad "build_and_deploy.yml keeps pull_request-only conditions although the workflow has no pull_request trigger"
else
    ok "build_and_deploy.yml has no conditions for an event it never receives"
fi

# The image that actually reaches Fly is the one the Docker workflow publishes.
# Booting that exact digest before the artifact is uploaded is the only runtime
# gate on the merge path, and both workflows share one implementation.
if ruby -ryaml -e '
    runs = YAML.load_file(".github/workflows/build_and_deploy.yml")["jobs"]["build"]["steps"]
              .map { |s| s["run"] || "" }.join("\n")
    exit 1 unless runs.include?("tests/runtime_smoke.py")
    steps = YAML.load_file(".github/workflows/validate.yml")["jobs"]["validate"]["steps"]
    exit 1 unless steps.any? { |s| (s["run"] || "").include?("tests/runtime_smoke.py") }
    exit 1 if steps.any? { |s| (s["run"] || "").include?("docker cp tests/") }
  '; then
    ok "the published image is smoke tested, through one shared script"
else
    bad "build_and_deploy.yml does not smoke test the published image, or the smoke test is duplicated inline"
fi

# The two-hour dependency job reports pending package upgrades, but nothing failed
# when the image that actually gets deployed still carried them.
if ruby -ryaml -e '
    runs = YAML.load_file(".github/workflows/build_and_deploy.yml")["jobs"]["build"]["steps"]
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
    steps = YAML.load_file(".github/workflows/build_and_deploy.yml")["jobs"]["build"]["steps"]
    expiry = steps.select { |s| s["uses"].to_s.include?(".github/actions/expire_tags") }
    exit 1 if expiry.empty?
    exit 1 if expiry.all? { |s| (s["if"] || "").empty? }
    exit 1 unless steps.any? { |s| (s["run"] || "").include?("event=schedule") }
    best_effort = expiry.find { |s| s["continue-on-error"] == true }
    exit 1 if best_effort.nil? || best_effort["id"].to_s.empty?
    exit 1 unless steps.any? { |s|
      (s["run"] || "").include?("::warning::") &&
        (s["if"] || "").include?("steps.#{best_effort["id"]}.outcome")
    }
    nightly = YAML.load_file(".github/workflows/ghcr_cleanup.yml")["jobs"]["cleanup"]["steps"]
    exit 1 unless nightly.any? { |s| s["uses"].to_s.include?(".github/actions/expire_tags") }
    shared = YAML.load_file(".github/actions/expire_tags/action.yml")
    exit 1 unless (shared["runs"]["steps"][0]["with"]["delete-tags"] || "").include?("[0-9]{12}")
  '; then
    ok "the build expires old timestamp tags when the nightly cleanup is behind"
else
    bad "tag expiry depends on a GitHub schedule that can stop silently, its best-effort failure is not reported, or the two call sites diverged"
fi

if ruby -ryaml -e '
    runner = YAML.load_file(".github/workflows/ghcr_cleanup.yml")["jobs"]["cleanup"]["runs-on"]
    exit 1 if runner.to_s.include?("latest")
  '; then
    ok "the cleanup job pins its runner instead of tracking ubuntu-latest"
else
    bad "the cleanup job runs on a floating ubuntu-latest runner"
fi

# The cleanup action deletes untagged and partial manifests. If it runs while a
# multi-arch push is in flight, it can remove manifests the build is about to
# publish. Put both workflows in one repository-wide concurrency group so the
# registry is mutated by one workflow at a time.
if ruby -ryaml -e '
    build = YAML.load_file(".github/workflows/build_and_deploy.yml")["concurrency"] || {}
    cleanup = YAML.load_file(".github/workflows/ghcr_cleanup.yml")["concurrency"] || {}
    exit 1 unless build["group"] == "ghcr-registry"
    exit 1 unless cleanup["group"] == "ghcr-registry"
    exit 1 if build["cancel-in-progress"] != false
    exit 1 if cleanup["cancel-in-progress"] != false
  '; then
    ok "builds and cleanup serialize on the same GHCR concurrency group"
else
    bad "GHCR cleanup can race an in-flight image push"
fi

# A job with no timeout-minutes holds its runner for the six-hour default, so a
# wedged docker build or a hung API call burns a runner for the rest of the day.
if ruby -ryaml -e '
    Dir[".github/workflows/*.yml"].each do |f|
      (YAML.load_file(f)["jobs"] || {}).each_value do |job|
        exit 1 unless job.is_a?(Hash) && job["timeout-minutes"]
      end
    end
  '; then
    ok "every workflow job bounds its own runtime"
else
    bad "a workflow job can hang for the six-hour default"
fi

# actions/checkout writes the workflow token into .git/config by default, which
# every later step can then reuse. Only the dependency job pushes, so only that
# one needs the credential to survive.
if ruby -ryaml -e '
    Dir[".github/workflows/*.yml"].each do |f|
      (YAML.load_file(f)["jobs"] || {}).each_value do |job|
        steps = job["steps"] || []
        next if steps.any? { |s| (s["run"] || "").include?("git push") }
        steps.each do |s|
          next unless s["uses"].to_s.start_with?("actions/checkout@")
          with = s["with"]
          exit 1 unless with.is_a?(Hash) && with["persist-credentials"] == false
        end
      end
    end
  '; then
    ok "checkouts that never push drop the persisted credential"
else
    bad "a checkout leaves the workflow token in .git/config"
fi

# GitHub documents that scheduled runs queue up behind the hourly load spike, so
# a cron on minute 0 is the slowest slot to pick.
if ruby -ryaml -e '
    Dir[".github/workflows/*.yml"].each do |f|
      doc = YAML.load_file(f)
      on = doc["on"] || doc[true] || {}
      Array(on["schedule"]).each do |entry|
        exit 1 if entry["cron"].to_s.split(" ")[0] == "0"
      end
    end
  '; then
    ok "no scheduled workflow queues at the top of the hour"
else
    bad "a scheduled workflow runs at minute 0, when the GitHub queue is longest"
fi

# A release can restart the machine while the backup starts at the top of the
# hour. Production hit that race during restic check: the backup was killed,
# left a repository lock, and the post-deploy freshness probe correctly raised
# an incident. Keep the hourly cadence but give deployment a clear margin.
backup_jobs="$(awk '$6 == "/restic.sh" && $7 == "backup" {count++} END {print count + 0}' config/crontab)"
backup_schedule="$(awk '$6 == "/restic.sh" && $7 == "backup" {print $1, $2, $3, $4, $5; exit}' config/crontab)"
backup_minute="${backup_schedule%% *}"
backup_hourly_fields="${backup_schedule#* }"
same "exactly one hourly backup is scheduled" 1 "$backup_jobs"
case "$backup_minute" in
    ''|0|*[!0-9]*)
        bad "the backup runs at minute 0 and can race a deployment restart"
        ;;
    *)
        if [ "$backup_minute" -le 59 ] && [ "$backup_hourly_fields" = "* * * *" ]; then
            ok "the hourly backup avoids the deployment window (minute ${backup_minute})"
        else
            bad "the backup is not an hourly schedule with a minute in 1-59"
        fi
        ;;
esac

# The monthly verify must not share a minute with the hourly backup: restic
# refuses the exclusive lock by default, so the check failed instantly with
# "repo already locked" instead of verifying anything.
verify_minute="$(awk '/\/restic\.sh verify$/ {print $1}' config/crontab | head -n 1)"
if [ -n "$verify_minute" ] && [ "$verify_minute" != "0" ]; then
    ok "the monthly verify avoids the top of the hour (minute ${verify_minute})"
else
    bad "the monthly verify fires at minute 0, the same minute as @hourly backup"
fi

# The drill is the only job that proves a snapshot still restores and boots, and
# nothing scheduled it: a repository that had quietly become unrestorable was
# only found when someone ran the drill by hand. Keep it on a fixed day of the
# month and off the top of the hour, where it would fight the hourly backup for
# the repository lock.
drill_schedule="$(awk '/\/restic\.sh restore-test$/ {print $1, $2, $3, $4, $5}' config/crontab | head -n 1)"
drill_minute="${drill_schedule%% *}"
drill_dom="$(printf '%s\n' "$drill_schedule" | awk '{print $3}')"
if [ -n "$drill_schedule" ] && [ "$drill_minute" != "0" ] && [ "$drill_dom" != "*" ]; then
    ok "the restore drill is scheduled monthly, away from the hourly backup (minute ${drill_minute}, day ${drill_dom})"
else
    bad "the restore drill is unscheduled, or it runs every day at minute 0 next to the hourly backup"
fi

# A dependency check that ran once a day left an upstream release unnoticed for
# most of that day, and the build workflow only warns after three silent days,
# so the schedule has already aged out by the time anyone hears about it. Pin a
# sub-daily cadence rather than the exact cron, so it can be retuned later.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/dependency_updates.yml")
    on = doc["on"] || doc[true] || {}
    entries = Array(on["schedule"])
    exit 1 if entries.empty?
    exit 1 unless entries.all? { |e| e["cron"].to_s.split(" ")[1].to_s.match?(/[*,\-]/) }
  '; then
    ok "the dependency check runs more than once a day"
else
    bad "the dependency check still runs only once a day"
fi

# A scheduled workflow is best-effort: GitHub can delay it and disables it for
# an inactive repository. A completed build is a real event, so use it as a
# fallback trigger and keep the automatic merge decision in sync with it.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/dependency_updates.yml")
    on = doc["on"] || doc[true] || {}
    run = on["workflow_run"]
    exit 1 if run.nil?
    exit 1 unless Array(run["workflows"]).any? { |w| w.include?("Build and Deploy") }
    exit 1 unless Array(run["types"]).include?("completed")
    exit 1 unless Array(run["branches"]).include?("main")
    gate = (doc["jobs"]["check"]["env"] || {})["AUTO_MERGE"].to_s
    exit 1 unless gate.include?("workflow_run")
  '; then
    ok "a completed build also triggers the dependency check"
else
    bad "the dependency check still depends only on GitHub's best-effort schedule"
fi

# The dependency check only opened a PR when a pin changed, so an Alpine-only
# security update waited for the weekly rebuild. The apk probe has to run every
# day, and a non-zero count has to dispatch the build workflow.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/dependency_updates.yml")
    steps = doc["jobs"]["check"]["steps"]
    apk = steps.find { |s| (s["run"] || "").include?("deps.sh apk") }
    exit 1 if apk.nil? || apk.key?("if")
    rebuild = steps.find { |s| (s["run"] || "").include?("rebuild-needed") }
    exit 1 if rebuild.nil?
    exit 1 unless (rebuild["run"] || "").include?("gh workflow run")
    exit 1 unless (rebuild["if"] || "").include?("success()")
    exit 1 unless (doc["permissions"] || {})["actions"] == "write"
  '; then
    ok "the two-hour check probes packages every run and dispatches a rebuild when needed"
else
    bad "package-only updates still wait for the weekly rebuild"
fi

# The apk probe reads the pinned base image, so it keeps reporting the same
# upgrades after our build has already applied them. A workflow_run fallback
# that also dispatched package-only rebuilds would loop build -> check -> build.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/dependency_updates.yml")
    steps = doc["jobs"]["check"]["steps"]
    rebuild = steps.find { |s| (s["run"] || "").include?("rebuild-needed") }
    exit 1 if rebuild.nil?
    exit 1 unless (rebuild["if"] || "").include?("workflow_run")
  '; then
    ok "the package-only rebuild cannot loop when a build triggers the check"
else
    bad "a build-triggered dependency check can dispatch builds forever"
fi

# The app's own scheduler cannot report its own silence, so the external
# dependency-check workflow also has to ask the live app whether the backup
# heartbeat is fresh. A failure there fails the workflow, which gives GitHub's
# own notification as a second channel when Telegram is the thing that broke.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/dependency_updates.yml")
    job = doc["jobs"]["watchdog"]
    exit 1 if job.nil?
    gate = job["if"].to_s
    exit 1 unless gate.include?("schedule") && gate.include?("workflow_run")
    steps = job["steps"] || []
    setup = steps.find { |s| (s["uses"] || "").include?("setup-flyctl") }
    exit 1 if setup.nil? || !(setup["uses"] || "").match?(/@[0-9a-f]{40}/)
    check = steps.find { |s| (s["run"] || "").include?("/restic.sh check-freshness") }
    exit 1 if check.nil?
    exit 1 unless (check["run"] || "").include?("flyctl ssh console")
    env = check["env"] || {}
    exit 1 unless env.keys.include?("FLY_API_TOKEN") && env.keys.include?("FLY_APP")
  '; then
    ok "the external dependency workflow checks the production backup heartbeat"
else
    bad "a silent scheduler still has no external backup-heartbeat check"
fi

# workflow_run never fired for a workflow_dispatch build, so a manual rebuild
# published an image that never reached Fly. The deploy has to live in the same
# workflow, and the separate workflow must be gone to avoid double deploys.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/build_and_deploy.yml")
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
    exit 1 if File.exist?(".github/workflows/deploy.yml")
  '; then
    ok "the build workflow deploys its own digest, for pushes and manual rebuilds"
else
    bad "manual rebuilds publish an image that never reaches Fly, or deploys are duplicated"
fi

# One serialization mechanism per workflow. The run-wide `ghcr-registry` group
# already serializes every job in this run - including the deploy - against the
# other runs and the cleanup workflow. A job-level group can only duplicate that
# lock, and reusing the run-wide name inside the run deadlocks it: the job waits
# for a slot its own run is holding.
if ruby -ryaml -e '
    Dir[".github/workflows/*.yml"].sort.each do |path|
      doc = YAML.load_file(path)
      (doc["jobs"] || {}).each do |id, job|
        next unless job.is_a?(Hash)
        next if (job["concurrency"] || {}).empty?
        warn "#{path}: job #{id} declares its own concurrency group"
        exit 1
      end
    end
  '; then
    ok "each workflow serializes through one run-wide concurrency group"
else
    bad "a workflow job declares a second concurrency group that can duplicate or deadlock the run-wide one"
fi

# The lint step parsed `.github/workflows/*.yml` and dependabot.yml by name, so
# the composite action that expires GHCR tags was never parsed: a syntax error
# there would only surface when a run reached that step. Execute the real step
# against a copy of the tree, then break the action file and require it to fail.
ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/validate.yml")
    step = doc["jobs"]["validate"]["steps"].find { |s| (s["run"] || "").include?("tomllib") }
    exit 1 if step.nil?
    print step["run"]
  ' > "$work/yaml-lint.sh" || true
if ! [ -s "$work/yaml-lint.sh" ]; then
    bad "validate.yml no longer parses its YAML files"
elif ! command -v python3 >/dev/null 2>&1; then
    bad "python3 is required to execute the CI syntax step"
else
    lint_tree="$work/lint-tree"
    mkdir -p "$lint_tree"
    cp -R .github "$lint_tree/"
    cp fly.toml "$lint_tree/"
    ( cd "$lint_tree" && bash "$work/yaml-lint.sh" ) > "$work/yaml-lint.log" 2>&1
    same "the CI syntax step accepts the tree as committed" 0 "$?"
    printf 'inputs: [\n' >> "$lint_tree/.github/actions/expire_tags/action.yml"
    if ( cd "$lint_tree" && bash "$work/yaml-lint.sh" ) > "$work/yaml-lint-broken.log" 2>&1; then
        bad "the CI syntax step never parses the composite action"
    else
        ok "a broken composite action fails the CI syntax step"
    fi
fi

# The `gh api` calls in build_and_deploy.yml need the same bound as the ones in
# deps.sh: gh has no timeout flag of its own.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/build_and_deploy.yml")
    runs = doc["jobs"].values.flat_map { |j| (j["steps"] || []).map { |s| s["run"] || "" } }.join("\n")
    unbounded = runs.lines.select { |l| l.include?("gh api") && !l.include?("timeout") }
    exit 1 unless unbounded.empty?
  '; then
    ok "build_and_deploy.yml bounds every gh api call"
else
    bad "build_and_deploy.yml calls gh api without a timeout"
fi

# The cleanup guard used to swallow an unreadable schedule with `|| true`, so an
# API failure was reported as "no scheduled run found", and the early exit also
# skipped the dependency-schedule warning. Run the real step body with a stub gh.
ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/build_and_deploy.yml")
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
if grep -q 'no automatic dependency check has ever run' "$work/guard-run.log"; then
    ok "the dependency-check warning still runs when the cleanup has no record"
else
    bad "the dependency-check warning is skipped by an early exit"
fi

# A single windowed query (`per_page=50` then filter) misreports a healthy check
# as never run once enough manual runs push the automatic one off the page.
# Query each automatic event directly and keep the newest.
if grep -q 'per_page=50' .github/workflows/build_and_deploy.yml; then
    bad "the dependency check still relies on a fixed page window"
else
    ok "the dependency check queries each automatic event directly"
fi
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_guard_events() {
    : > "$guard_out"
    # The step parses timestamps with GNU `date -d`, which BSD date lacks. The
    # step runs on ubuntu-latest, so stub the clock to keep this test hermetic
    # and let it exercise the real event-selection code on any host.
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" 1700000000\n'
    } > "$guard_stub/date"
    chmod +x "$guard_stub/date"
    {
        printf '#!/bin/sh\n'
        printf 'case "$*" in\n'
        printf '  *ghcr_cleanup.yml/runs*) printf "%%s\\n" %s ;;\n' "'$now_iso'"
        printf '  *dependency_updates.yml/runs?event=schedule*) printf "%%s\\n" %s ;;\n' \
            "'2000-01-01T00:00:00Z'"
        printf '  *dependency_updates.yml/runs?event=workflow_run*) printf "%%s\\n" %s ;;\n' \
            "'$now_iso'"
        printf '  *) exit 1 ;;\n'
        printf 'esac\n'
    } > "$guard_stub/gh"
    chmod +x "$guard_stub/gh"
    GITHUB_OUTPUT="$guard_out" GITHUB_REPOSITORY=example/repo \
        PATH="$guard_stub:$PATH" bash "$work/cleanup-check.sh" > "$work/guard-run.log" 2>&1
}
run_guard_events
if grep -q "last automatic dependency check: ${now_iso} " "$work/guard-run.log"; then
    ok "the newest automatic dependency run wins across both events"
else
    bad "the dependency-check report did not pick the newest event"
fi

# `paths-ignore` means a README-only commit never triggers this workflow, so
# "main moved" is not proof that a newer build will take over. A doc-only merge
# during a build window used to cancel the deployment of the commit being built,
# leaving the code change unpublished until the next code push. Run the real
# guard body with a stub gh that answers both queries.
ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/build_and_deploy.yml")
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
            printf '  *workflows/build_and_deploy.yml/runs*)\n'
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

    # the run list cannot be read: refuse to deploy an unverified build.
    deploy_stub_case doc999 "" 1
    run_deploy_guard
    same "an unreadable run list fails the deployment gate" 1 "$?"
    if grep -q 'refusing to deploy' "$work/deploy-run.log"; then
        ok "an unreadable run list explains why deployment stopped"
    else
        bad "an unreadable run list does not explain the deployment stop"
    fi
else
    bad "the deploy guard step or its actions:read permission is missing"
fi

# The dependency job has two places that turned a real failure into a reassuring
# message: `gh pr create ... || echo "PR already exists"` and a status-check poll
# that read an API error as "no checks registered". Both leave the operator
# chasing the wrong cause, so assert the behaviour with stubs.
if ruby -ryaml -e '
    doc = YAML.load_file(".github/workflows/dependency_updates.yml")
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
    doc = YAML.load_file(".github/workflows/dependency_updates.yml")
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
    doc = YAML.load_file(".github/workflows/dependency_updates.yml")
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
            VERSION=1.2.3 DIGEST=sha256:stub SUPERCRONIC=v0 \
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
    doc = YAML.load_file(".github/workflows/dependency_updates.yml")
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

# The dispatch after the merge waits up to ten minutes for the pull request to
# land, so it must only run when this run is the one merging the PR. A manual
# dispatch that leaves the merge to a human - the documented `auto_merge: false`
# path - used to poll for ten minutes and fail a run that did exactly what was
# asked. Both steps now read one decision, so they cannot drift apart.
if ruby -ryaml -e '
    job = YAML.load_file(".github/workflows/dependency_updates.yml")["jobs"]["check"]
    gate = (job["env"] || {})["AUTO_MERGE"].to_s
    exit 1 unless gate.include?("inputs.auto_merge")
    exit 1 unless gate.include?("github.event_name")
    exit 1 unless gate.include?("schedule")
    steps = job["steps"]
    arm = steps.find { |s| s["id"] == "arm" }
    dispatch = steps.find { |s| (s["run"] || "").include?("did not merge within") }
    exit 1 if arm.nil? || dispatch.nil?
    exit 1 unless (arm["if"] || "").include?("env.AUTO_MERGE")
    exit 1 unless (dispatch["if"] || "").include?("env.AUTO_MERGE")
    exit 1 unless (dispatch["if"] || "").include?("always()")
  '; then
    ok "the post-merge dispatch is gated on the same auto-merge decision as the merge"
else
    bad "the post-merge dispatch runs on a run that is not merging the pull request"
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
if grep -q 'runtime_smoke.py' README.md; then
    ok "README lists the runtime smoke test in its verification commands"
else
    bad "README does not mention tests/runtime_smoke.py"
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

# Every header the Caddyfile keeps out of the access log is a promise about what
# a log line can contain. The watchdog that introduced `X-Backup-Status-Token`
# was deleted and its filter outlived it, so the README listed nine headers
# while Caddy filtered ten and neither list could be trusted.
log_filters="$(sed -n 's/.*request>headers>\([^ ]*\) delete.*/\1/p' config/Caddyfile)"
filter_count="$(printf '%s\n' "$log_filters" | grep -c .)"
if [ "$filter_count" -lt 5 ]; then
    bad "only ${filter_count} Caddy log filters were found; the extraction is broken"
else
    undocumented=""
    for header in $log_filters; do
        grep -qi -- "\`${header}\`" README.md || undocumented="${undocumented} ${header}"
    done
    if [ -z "$undocumented" ]; then
        ok "README documents all ${filter_count} headers the Caddyfile filters"
    else
        bad "README does not document these Caddy log filters:${undocumented}"
    fi
fi

# Settings saved through the admin panel land in /data/config.json, and that
# file wins over the environment. A README that only lists `fly secrets set`
# sends the operator to a command that silently changes nothing.
if grep -q 'config.json' README.md && grep -qi 'admin panel' README.md; then
    ok "README documents that /data/config.json outranks the environment"
else
    bad "README does not warn that /data/config.json overrides the Fly secrets"
fi

# The alert channels follow how often a job can repeat its warning. An hourly
# job would repeat an email up to 24 times a day, so the hourly jobs stay on
# Telegram and only the monthly jobs keep the incident email. A regression
# that routes an hourly job back through the mailer is invisible until the
# mailbox fills, so pin the split to the source.
for job in backup check_freshness check_disk; do
    body="$(sed -n "/^${job}() {/,/^}/p" scripts/restic.sh)"
    case "$body" in
        *send_telegram*)
            case "$body" in
                *send_mail*|*notify*)
                    bad "${job}() still reaches the mailer for its hourly warning"
                    ;;
                *)
                    ok "${job}() notifies through Telegram only"
                    ;;
            esac
            ;;
        *)
            bad "${job}() no longer notifies at all"
            ;;
    esac
done
for job in verify restore_test; do
    body="$(sed -n "/^${job}() {/,/^}/p" scripts/restic.sh)"
    case "$body" in
        *notify_rare*) ok "the monthly ${job}() keeps the incident email" ;;
        *) bad "${job}() lost the incident email channel" ;;
    esac
done

# The README documents these knobs and the template is what a local run copies,
# so a missing entry means the operator silently gets a default instead.
missing_env=""
for name in BACKUP_MAX_AGE RESTIC_LOG_DIR RESTIC_LOG_MAX_BYTES RESTIC_LOG_DIR_MAX_BYTES \
    RESTIC_QUICK_TIMEOUT RESTIC_LONG_TIMEOUT SUPERVISE_RESTART_DELAY VERIFY_SUBSET \
    BACKUP_NOTIFY_ON_SUCCESS BACKUP_MAX_USAGE_PERCENT TELEGRAM_BOT_TOKEN \
    TELEGRAM_CHAT_ID VERIFY_RETRY_LOCK; do
    grep -q "^${name}=" .env.example || missing_env="${missing_env} ${name}"
done
if [ -z "$missing_env" ]; then
    ok "every documented tuning variable appears in .env.example"
else
    bad "missing from .env.example:${missing_env}"
fi

# The README is the operator's runbook, so every test path it names has to
# exist. It pointed at tests/selftest.py, a file that was never there: pasting
# the documented command failed with "No such file or directory".
missing_doc=""
while IFS= read -r path; do
    [ -e "$path" ] || missing_doc="${missing_doc} ${path}"
done < <(grep -oE 'tests/[A-Za-z0-9._-]+' README.md | sort -u)
if [ -z "$missing_doc" ]; then
    ok "every test path the README names exists"
else
    bad "the README names test paths that do not exist:${missing_doc}"
fi

# The README promises the entrypoint reports the /data/config.json keys that
# override a Fly secret. A key the warning does not cover stays invisible while
# `fly secrets set` silently does nothing, and signups_allowed is the one that
# decides whether anyone can register. `smtp_*` must be matched by its prefix,
# not by a short hardcoded list that misses host, port or future keys.
entry_keys="$(sed -n 's/.*for key in \(.*\); do.*/\1/p' scripts/entrypoint/config.sh | head -n 1)"
missing_keys=""
for key in admin_token signups_allowed; do
    case " $entry_keys " in
        *" $key "*) ;;
        *) missing_keys="${missing_keys} ${key}" ;;
    esac
done
if ! grep -Fq '"smtp_[A-Za-z0-9_]+"' scripts/entrypoint/config.sh; then
    missing_keys="${missing_keys} smtp_*"
fi
if [ -z "$missing_keys" ]; then
    ok "the config.json override warning covers known keys and every smtp_* key"
else
    bad "the config.json override warning misses documented keys:${missing_keys}"
fi

# The dependency check moved from daily to every two hours, but the operator
# docs and the nearby comments still described the old cadence. Pin the
# wording so the runbook cannot quietly drift from the workflow again.
if stale_cadence="$(grep -nE 'runs dai[l]y|checks them dai[l]y|dai[l]y job|dai[l]y check' \
    README.md Dockerfile scripts/deps.sh \
    .github/workflows/build_and_deploy.yml tests/selftest.sh)"; then
    bad "stale dependency cadence wording remains: ${stale_cadence//$'\n'/; }"
else
    stale_status=$?
    if [ "$stale_status" -eq 1 ]; then
        if grep -qF 'runs every two hours' README.md; then
            ok "the dependency docs and comments describe the two-hour cadence"
        else
            bad "README does not document the dependency workflow's two-hour cadence"
        fi
    else
        bad "could not scan the repository for stale dependency cadence wording"
    fi
fi

echo
report "helper self tests"
