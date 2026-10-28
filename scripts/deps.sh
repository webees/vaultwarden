#!/bin/bash
# Dependency resolver: deps.sh <base|tools|compare|apply|apk|rebuild-needed> [args...]
set -euo pipefail

cd "$(dirname "$0")/.."
readonly DOCKERFILE=Dockerfile
readonly REGISTRY=https://registry-1.docker.io/v2/vaultwarden/server
readonly GH_API=https://api.github.com/repos
readonly HTTP_TIMEOUT="${DEPS_HTTP_TIMEOUT:-30}"
readonly GH_TIMEOUT="${DEPS_GH_TIMEOUT:-30}"

# Bound every network request.
fetch() { curl -fsSL --max-time "$HTTP_TIMEOUT" --retry 2 --retry-delay 2 "$@"; }

# gh has no timeout flag; use the runner's timeout when available.
gh_api() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$GH_TIMEOUT" gh api "$@"
    else
        gh api "$@"
    fi
}

emit() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }

pin() {
    case "$1" in
        ''|*[!A-Za-z0-9_]*)
            echo "pin: '${1:-}' is not a valid pin name" >&2
            exit 2
            ;;
    esac
    sed -n "s/^ARG $1=//p" "$DOCKERFILE" | head -n 1
}

# Validate upstream values before writing them into the Dockerfile.
validate_pin_value() {
    local name="$1" value="$2"
    case "$name" in
        VAULTWARDEN_VERSION|SUPERCRONIC_VERSION)
            [[ "$value" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]]
            ;;
        VAULTWARDEN_DIGEST)
            [[ "$value" =~ ^sha256:[0-9a-f]{64}$ ]]
            ;;
        *_SHA256_amd64|*_SHA256_arm64)
            [[ "$value" =~ ^[0-9a-f]{64}$ ]]
            ;;
        *)
            return 1
            ;;
    esac
}

sha256() { sha256sum | cut -d' ' -f1; }

base() {
    local page next json tag found current_version candidates
    current_version="$(pin VAULTWARDEN_VERSION)"
    case "$current_version" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *)
            echo "invalid VAULTWARDEN_VERSION pin: ${current_version:-missing}" >&2
            exit 1
            ;;
    esac
    candidates="${current_version}"$'\n'
    page=1
    next="https://hub.docker.com/v2/repositories/vaultwarden/server/tags?page_size=100&page=1"
    while [ -n "$next" ]; do
        [ "$page" -le 20 ] || {
            echo "Docker Hub tag pagination exceeded 20 pages" >&2
            exit 1
        }
        json="$(fetch "$next")"
        # A malformed page is not evidence that the feed is current.
        if ! jq -e '(.results | type) == "array"' >/dev/null 2>&1 <<< "$json"; then
            echo "malformed Docker Hub tag response on page ${page}" >&2
            exit 1
        fi
        if [ "$(jq -r '.results | length' <<< "$json")" -eq 0 ]; then
            break
        fi
        candidates+="$(jq -r '
            .results[].name
            | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+-alpine$"))
            | sub("-alpine$"; "")
        ' <<< "$json")"$'\n'
        next="$(jq -r '.next // empty' <<< "$json")"
        case "$next" in
            ''|https://hub.docker.com/v2/repositories/vaultwarden/server/tags\?*) ;;
            *)
                echo "unexpected Docker Hub next-page URL on page ${page}" >&2
                exit 1
                ;;
        esac
        page=$((page + 1))
    done
    # Include the current pin so a partial feed cannot downgrade it.
    found="$(printf '%s' "$candidates" \
        | sed '/^$/d' \
        | sort -u \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -n 1)"
    tag="${found}-alpine"

    local auth_json token digest
    auth_json="$(fetch 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:vaultwarden/server:pull')"
    if ! jq -e '
        type == "object"
        and (.token | type == "string" and test("^[A-Za-z0-9._~+/=-]+$"))
    ' >/dev/null 2>&1 <<< "$auth_json"; then
        echo "malformed registry token" >&2
        exit 1
    fi
    token="$(jq -r .token <<< "$auth_json")"
    digest="$(fetch -I -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
        "${REGISTRY}/manifests/${tag}" \
        | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2; exit}')"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
        || { echo "invalid registry digest for ${tag}" >&2; exit 1; }

    emit version "${tag%-alpine}"
    emit digest "$digest"
}

tools() {
    local arch sc_tag sc_release sc_releases sc_url urls
    sc_releases="$(gh_api "${GH_API}/aptible/supercronic/releases?per_page=100" \
        --jq '[.[] | {tag_name, prerelease, draft, assets}]')"
    # GitHub orders releases by publication time, not semantic version. Select
    # the highest recent stable tag so a later-published maintenance release
    # cannot make the dependency workflow downgrade Supercronic.
    sc_release="$(jq -c '
        def version:
            .tag_name[1:] | split(".") as $parts
            | [($parts[0] | tonumber), ($parts[1] | tonumber),
               (($parts[2] // "0") | tonumber)];
        [.[]
         | select((.prerelease | not) and (.draft | not))
         | select((.tag_name | type) == "string"
                  and (.tag_name | test("^v[0-9]+(\\.[0-9]+){1,2}$")))]
        | sort_by(version)
        | last // empty
    ' <<< "$sc_releases")"
    if ! jq -e '
        type == "object"
        and (.tag_name | type == "string" and test("^v[0-9]+(\\.[0-9]+){1,2}$"))
        and (.assets | type == "array")
    ' >/dev/null 2>&1 <<< "$sc_release"; then
        echo "malformed supercronic release metadata" >&2
        exit 1
    fi
    sc_tag="$(jq -r .tag_name <<< "$sc_release")"
    for arch in amd64 arm64; do
        urls="$(jq -r --arg name "supercronic-linux-${arch}" '
            [.assets[] | select(.name == $name) | .browser_download_url]
            | if length == 1 and (.[0] | type == "string") then .[0] else empty end
        ' <<< "$sc_release")"
        if [ -z "$urls" ] || [[ "$urls" == *$'\n'* ]]; then
            echo "supercronic release ${sc_tag}: missing or ambiguous ${arch} asset" >&2
            exit 1
        fi
        sc_url="$urls"
        if [[ ! "$sc_url" =~ ^https://github\.com/aptible/supercronic/releases/download/${sc_tag}/supercronic-linux-${arch}$ ]]; then
            echo "untrusted download URL for supercronic ${arch}" >&2
            exit 1
        fi
        emit "supercronic_sha_${arch}" "$(fetch "$sc_url" | sha256)"
    done
    emit supercronic_version "$sc_tag"
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

apply() {
    local pair name value
    # Validate every pair before the first rewrite.
    for pair in "$@"; do
        case "$pair" in
            *=*) ;;
            *) echo "apply: expected NAME=VALUE, got '${pair}'" >&2; exit 2 ;;
        esac
        name="${pair%%=*}"
        value="${pair#*=}"
        case "$name" in
            ''|*[!A-Za-z0-9_]*)
                echo "apply: '${name}' is not a valid pin name" >&2
                exit 2
                ;;
        esac
        [ -n "$value" ] || {
            echo "apply: ${name} has an empty value" >&2
            exit 2
        }
        if ! validate_pin_value "$name" "$value"; then
            echo "apply: ${name} has an invalid value" >&2
            exit 2
        fi
        grep -q "^ARG ${name}=" "$DOCKERFILE" || {
            echo "apply: ${name} is not declared in ${DOCKERFILE}" >&2
            exit 2
        }
    done
    APPLY_TMP="$(mktemp)"
    trap cleanup_apply_tmp EXIT
    for pair in "$@"; do
        name="${pair%%=*}"
        value="${pair#*=}"
        # Escape sed replacement syntax even for validated values.
        value="$(printf '%s' "$value" | sed 's/[&\\|]/\\&/g')"
        # A temp file is portable across BSD and GNU sed.
        sed "s|^ARG ${name}=.*|ARG ${name}=${value}|" "$DOCKERFILE" > "$APPLY_TMP"
        mv "$APPLY_TMP" "$DOCKERFILE"
    done
    git --no-pager diff -- "$DOCKERFILE"
}

apk() {
    [ "$#" -ge 1 ] || {
        echo "usage: deps.sh apk <image>" >&2
        exit 2
    }
    local image="$1" rows count
    # A failed index refresh must not look like no upgrades.
    rows="$(docker run --rm "$image" sh -c \
        'apk update >/dev/null 2>&1 || { echo "apk update failed" >&2; exit 1; }; apk version -v -l "<" || { echo "apk version failed" >&2; exit 1; }' \
        | awk 'NF == 3 {print $1, $3}')"
    count="$(printf '%s\n' "$rows" | grep -c . || true)"
    {
        printf 'count=%s\n' "$count"
        printf 'rows<<APK_EOF\n%s\nAPK_EOF\n' "$rows"
    } >> "${GITHUB_OUTPUT:-/dev/stdout}"
    echo "upgradable packages: ${count}"
    printf '%s\n' "$rows"
}

# 0=rebuild, 1=no action, 2=invalid input.
rebuild_needed() {
    local base_count="${1:-}" published_count="${2:-}"
    case "$base_count" in
        ''|*[!0-9]*)
            echo "usage: deps.sh rebuild-needed <base-count> <published-count>" >&2
            exit 2
            ;;
    esac
    case "$published_count" in
        ''|*[!0-9]*)
            echo "usage: deps.sh rebuild-needed <base-count> <published-count>" >&2
            exit 2
            ;;
    esac
    if [ "$base_count" -eq 0 ]; then
        echo "no rebuild needed: the pinned base image has no package upgrades"
        return 1
    fi
    if [ "$published_count" -eq 0 ]; then
        echo "no rebuild needed: the published image already contains the package upgrades"
        return 1
    fi
    echo "rebuild needed: ${published_count} package upgrade(s) remain in the published image"
    return 0
}

command="${1:?usage: deps.sh <base|tools|compare|apply|apk|rebuild-needed> [args...]}"
shift
case "$command" in
    rebuild-needed) rebuild_needed "$@" ;;
    *)              "$command" "$@" ;;
esac
