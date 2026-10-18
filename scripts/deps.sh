#!/bin/bash
# Dependency pin resolver used by .github/workflows/security-updates.yml.
# Usage: deps.sh <base|tools|compare|apply> [VAR=VALUE ...]
# Every resolved or changed value is written to $GITHUB_OUTPUT (or stdout).
set -euo pipefail

cd "$(dirname "$0")/.."
readonly DOCKERFILE=Dockerfile
readonly REGISTRY=https://registry-1.docker.io/v2/vaultwarden/server
readonly GH_API=https://api.github.com/repos

emit() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }

pin() { sed -n "s/^ARG $1=//p" "$DOCKERFILE" | head -n 1; }

sha256() { sha256sum | cut -d' ' -f1; }

base() {
    local page json tag found
    for page in $(seq 1 20); do
        json="$(curl -fsSL "https://hub.docker.com/v2/repositories/vaultwarden/server/tags?page_size=100&page=${page}")"
        found="$(jq -r '[.results[].name | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+-alpine$"))] | first' <<< "$json")"
        if [ -n "$found" ] && [ "$found" != "null" ]; then
            tag="$found"
            break
        fi
    done
    [ -n "${tag:-}" ] || { echo "no vaultwarden tag found" >&2; exit 1; }

    local token digest
    token="$(curl -fsSL 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:vaultwarden/server:pull' | jq -r .token)"
    digest="$(curl -fsSI -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
        "${REGISTRY}/manifests/${tag}" \
        | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2; exit}')"
    [ -n "$digest" ] || { echo "no digest for ${tag}" >&2; exit 1; }

    emit version "${tag%-alpine}"
    emit digest "$digest"
}

tools() {
    local sc_tag sc_release sc_url
    sc_release="$(gh api "${GH_API}/aptible/supercronic/releases?per_page=20" \
        --jq '[.[] | select((.prerelease | not) and (.draft | not))] | first')"
    sc_tag="$(jq -r .tag_name <<< "$sc_release")"
    for arch in amd64 arm64; do
        sc_url="$(jq -r --arg a "linux-${arch}\$" '.assets[] | select(.name | test($a)) | .browser_download_url' <<< "$sc_release")"
        emit "supercronic_sha_${arch}" "$(curl -fsSL "$sc_url" | sha256)"
    done
    emit supercronic_version "$sc_tag"

    local om_tag
    om_tag="$(gh api "${GH_API}/DarthSim/overmind/releases?per_page=20" \
        --jq '[.[] | select((.prerelease | not) and (.draft | not))] | first | .tag_name')"
    for arch in amd64 arm64; do
        emit "overmind_sha_${arch}" "$(curl -fsSL \
            "https://github.com/DarthSim/overmind/releases/download/${om_tag}/overmind-${om_tag}-linux-${arch}.gz" \
            | gunzip -c | sha256)"
    done
    emit overmind_version "$om_tag"
}

# Compare current pins against VAR=VALUE pairs; emit changed=true when any differ.
compare() {
    local pair name want have changed=false
    for pair in "$@"; do
        name="${pair%%=*}"
        want="${pair#*=}"
        have="$(pin "$name")"
        if [ "$have" = "$want" ]; then
            echo "ok   ${name}"
        else
            echo "diff ${name}: ${have} -> ${want}"
            changed=true
        fi
    done
    # Emitted once at the end: a duplicate key in $GITHUB_OUTPUT only works
    # because GitHub keeps the last value, which is easy to break silently.
    emit changed "$changed"
}

# Scratch file for apply(). Global on purpose: an EXIT trap runs after the
# function has returned, where a `local` would already be unset.
APPLY_TMP=""
cleanup_apply_tmp() {
    [ -n "$APPLY_TMP" ] && rm -f "$APPLY_TMP"
    return 0
}

# Rewrite the pins in place from VAR=VALUE pairs.
apply() {
    local pair name value
    APPLY_TMP="$(mktemp)"
    trap cleanup_apply_tmp EXIT
    for pair in "$@"; do
        name="${pair%%=*}"
        value="${pair#*=}"
        # `sed -i` needs a suffix on BSD and rejects one on GNU, so rewrite
        # through a temp file and rename instead of editing in place.
        sed "s|^ARG ${name}=.*|ARG ${name}=${value}|" "$DOCKERFILE" > "$APPLY_TMP"
        mv "$APPLY_TMP" "$DOCKERFILE"
    done
    git --no-pager diff -- "$DOCKERFILE"
}

# Report the Alpine packages that have a newer build in the pinned base image.
apk() {
    local image="$1" rows count
    rows="$(docker run --rm "$image" sh -c \
        'apk update >/dev/null 2>&1; apk version -v -l "<" 2>/dev/null' \
        | awk 'NF == 3 {print $1, $3}')"
    count="$(printf '%s\n' "$rows" | grep -c . || true)"
    {
        printf 'count=%s\n' "$count"
        printf 'rows<<APK_EOF\n%s\nAPK_EOF\n' "$rows"
    } >> "${GITHUB_OUTPUT:-/dev/stdout}"
    echo "upgradable packages: ${count}"
    printf '%s\n' "$rows"
}

command="${1:?usage: deps.sh <base|tools|compare|apply|apk> [args...]}"
shift
"$command" "$@"
