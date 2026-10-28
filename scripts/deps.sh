#!/bin/bash
# Dependency resolver: deps.sh <base|tools|compare|apply|apk|rebuild-needed> [args...]
set -euo pipefail

cd "$(dirname "$0")/.."
readonly DOCKERFILE=Dockerfile
readonly REGISTRY=https://registry-1.docker.io/v2/vaultwarden/server
readonly GH_API=https://api.github.com/repos
readonly HTTP_TIMEOUT="${DEPS_HTTP_TIMEOUT:-30}"
readonly GH_TIMEOUT="${DEPS_GH_TIMEOUT:-30}"

fail() { echo "$*" >&2; exit 1; }
usage_error() { echo "$*" >&2; exit 2; }
fetch() { curl -fsSL --max-time "$HTTP_TIMEOUT" --retry 2 --retry-delay 2 "$@"; }
emit() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }

gh_api() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$GH_TIMEOUT" gh api "$@"
    else
        gh api "$@"
    fi
}

pin() {
    [[ "$1" =~ ^[A-Za-z0-9_]+$ ]] || usage_error "pin: '${1:-}' is not a valid pin name"
    sed -n "s/^ARG $1=//p" "$DOCKERFILE" | head -n 1
}

validate_pin_value() {
    case "$1" in
        VAULTWARDEN_VERSION|SUPERCRONIC_VERSION)
            [[ "$2" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]]
            ;;
        VAULTWARDEN_DIGEST) [[ "$2" =~ ^sha256:[0-9a-f]{64}$ ]] ;;
        *_SHA256_amd64|*_SHA256_arm64) [[ "$2" =~ ^[0-9a-f]{64}$ ]] ;;
        *) return 1 ;;
    esac
}

base() {
    local page=1 next json found current candidates tag auth token digest
    current="$(pin VAULTWARDEN_VERSION)"
    [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fail "invalid VAULTWARDEN_VERSION pin: ${current:-missing}"
    candidates="$current"$'\n'
    next="https://hub.docker.com/v2/repositories/vaultwarden/server/tags?page_size=100&page=1"
    while [ -n "$next" ]; do
        [ "$page" -le 20 ] || fail "Docker Hub tag pagination exceeded 20 pages"
        json="$(fetch "$next")"
        jq -e '(.results | type) == "array"' >/dev/null 2>&1 <<< "$json" \
            || fail "malformed Docker Hub tag response on page ${page}"
        [ "$(jq -r '.results | length' <<< "$json")" -ne 0 ] || break
        candidates+="$(jq -r '
            .results[].name
            | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+-alpine$"))
            | sub("-alpine$"; "")
        ' <<< "$json")"$'\n'
        next="$(jq -r '.next // empty' <<< "$json")"
        case "$next" in
            ''|https://hub.docker.com/v2/repositories/vaultwarden/server/tags\?*) ;;
            *) fail "unexpected Docker Hub next-page URL on page ${page}" ;;
        esac
        page=$((page + 1))
    done
    found="$(printf '%s' "$candidates" | sed '/^$/d' | sort -u \
        | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
    tag="${found}-alpine"

    auth="$(fetch 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:vaultwarden/server:pull')"
    jq -e 'type == "object" and (.token | type == "string" and test("^[A-Za-z0-9._~+/=-]+$"))' \
        >/dev/null 2>&1 <<< "$auth" || fail "malformed registry token"
    token="$(jq -r .token <<< "$auth")"
    digest="$(fetch -I -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
        "${REGISTRY}/manifests/${tag}" \
        | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2; exit}')"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "invalid registry digest for ${tag}"
    emit version "${tag%-alpine}"
    emit digest "$digest"
}

tools() {
    local arch release tag url urls
    release="$(gh_api "${GH_API}/aptible/supercronic/releases?per_page=100" \
        --jq '[.[] | {tag_name, prerelease, draft, assets}]' | jq -c '
            def version:
                .tag_name[1:] | split(".") as $parts
                | [($parts[0] | tonumber), ($parts[1] | tonumber),
                   (($parts[2] // "0") | tonumber)];
            [.[]
             | select((.prerelease | not) and (.draft | not))
             | select((.tag_name | type) == "string"
                      and (.tag_name | test("^v[0-9]+(\\.[0-9]+){1,2}$")))]
            | sort_by(version) | last // empty
        ')"
    jq -e 'type == "object"
        and (.tag_name | type == "string" and test("^v[0-9]+(\\.[0-9]+){1,2}$"))
        and (.assets | type == "array")' >/dev/null 2>&1 <<< "$release" \
        || fail "malformed supercronic release metadata"
    tag="$(jq -r .tag_name <<< "$release")"
    for arch in amd64 arm64; do
        urls="$(jq -r --arg name "supercronic-linux-${arch}" '
            [.assets[] | select(.name == $name) | .browser_download_url]
            | if length == 1 and (.[0] | type == "string") then .[0] else empty end
        ' <<< "$release")"
        [ -n "$urls" ] && [[ "$urls" != *$'\n'* ]] \
            || fail "supercronic release ${tag}: missing or ambiguous ${arch} asset"
        url="$urls"
        [[ "$url" =~ ^https://github\.com/aptible/supercronic/releases/download/${tag}/supercronic-linux-${arch}$ ]] \
            || fail "untrusted download URL for supercronic ${arch}"
        emit "supercronic_sha_${arch}" "$(fetch "$url" | sha256sum | cut -d' ' -f1)"
    done
    emit supercronic_version "$tag"
}

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
    emit changed "$changed"
}

APPLY_TMP=""
trap '[ -z "$APPLY_TMP" ] || rm -f "$APPLY_TMP"' EXIT

apply() {
    local pair name value escaped expressions=()
    [ "$#" -gt 0 ] || usage_error "apply: no pins supplied"
    for pair in "$@"; do
        case "$pair" in *=*) ;; *) usage_error "apply: expected NAME=VALUE, got '${pair}'" ;; esac
        name="${pair%%=*}"
        value="${pair#*=}"
        [[ "$name" =~ ^[A-Za-z0-9_]+$ ]] || usage_error "apply: '${name}' is not a valid pin name"
        [ -n "$value" ] || usage_error "apply: ${name} has an empty value"
        grep -q "^ARG ${name}=" "$DOCKERFILE" \
            || usage_error "apply: ${name} is not declared in ${DOCKERFILE}"
        validate_pin_value "$name" "$value" || usage_error "apply: ${name} has an invalid value"
        escaped="$(printf '%s' "$value" | sed 's/[&\\|]/\\&/g')"
        expressions+=(-e "s|^ARG ${name}=.*|ARG ${name}=${escaped}|")
    done
    APPLY_TMP="$(mktemp)"
    sed "${expressions[@]}" "$DOCKERFILE" > "$APPLY_TMP"
    mv "$APPLY_TMP" "$DOCKERFILE"
    APPLY_TMP=""
    git --no-pager diff -- "$DOCKERFILE"
}

apk() {
    [ "$#" -ge 1 ] || usage_error "usage: deps.sh apk <image>"
    local image="$1" rows count
    rows="$(docker run --rm "$image" sh -c \
        'apk update >/dev/null 2>&1 || { echo "apk update failed" >&2; exit 1; }; apk version -v -l "<" || { echo "apk version failed" >&2; exit 1; }' \
        | awk 'NF == 3 {print $1, $3}')"
    count="$(grep -c . <<< "$rows" || true)"
    {
        printf 'count=%s\nrows<<APK_EOF\n%s\nAPK_EOF\n' "$count" "$rows"
    } >> "${GITHUB_OUTPUT:-/dev/stdout}"
    printf 'upgradable packages: %s\n%s\n' "$count" "$rows"
}

rebuild_needed() {
    local base_count="${1:-}" published_count="${2:-}"
    [[ "$base_count" =~ ^[0-9]+$ && "$published_count" =~ ^[0-9]+$ ]] \
        || usage_error "usage: deps.sh rebuild-needed <base-count> <published-count>"
    [ "$base_count" -ne 0 ] || { echo "no rebuild needed: the pinned base image has no package upgrades"; return 1; }
    [ "$published_count" -ne 0 ] || { echo "no rebuild needed: the published image already contains the package upgrades"; return 1; }
    echo "rebuild needed: ${published_count} package upgrade(s) remain in the published image"
}

case "${1:-}" in
    base)           base ;;
    tools)          tools ;;
    compare)        shift; compare "$@" ;;
    apply)          shift; apply "$@" ;;
    apk)            shift; apk "$@" ;;
    rebuild-needed) shift; rebuild_needed "$@" ;;
    *)              usage_error "usage: deps.sh <base|tools|compare|apply|apk|rebuild-needed> [args...]" ;;
esac
