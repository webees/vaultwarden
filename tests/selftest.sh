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

# ── docs consistency ──────────────────────────────────────────────────────────
echo "--- docs"
# The deploy workflow passes the freshly built digest with `fly deploy --image`,
# and fly.toml deliberately keeps no image pin. A README that still tells the
# reader to edit a fly.toml image pin sends them to a value that does not exist.
if grep -q 'replace the value in fly.toml' README.md; then
    bad "README still points readers at a fly.toml image pin that was removed"
else
    ok "README no longer references a removed fly.toml image pin"
fi

if grep -q -- '--image' README.md; then
    ok "README documents that the deploy workflow passes --image"
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

echo
report "helper self tests"
