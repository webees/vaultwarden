#!/usr/bin/env bash
# Run one allow-listed production operation, retrying only Fly transport errors.
set -euo pipefail

: "${FLY_APP:?FLY_APP must hold the Fly app name}"
: "${OPERATION:?OPERATION must name a production operation}"
: "${FLY_LOG_REDACT:?FLY_LOG_REDACT must contain the log redaction expression}"

max_attempts="${FLY_OPERATION_MAX_ATTEMPTS:-3}"
budget_seconds="${FLY_OPERATION_BUDGET_SECONDS:-2400}"
retry_delay_seconds="${FLY_OPERATION_RETRY_DELAY_SECONDS:-10}"

[[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::FLY_OPERATION_MAX_ATTEMPTS must be a positive integer" >&2
  exit 2
}
[[ "$budget_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::FLY_OPERATION_BUDGET_SECONDS must be a positive integer" >&2
  exit 2
}
[[ "$retry_delay_seconds" =~ ^[0-9]+$ ]] || {
  echo "::error::FLY_OPERATION_RETRY_DELAY_SECONDS must be a non-negative integer" >&2
  exit 2
}

case "$OPERATION" in
  check-freshness|notify-test|snapshots|verify|restore-test|backup)
    command="/restic.sh ${OPERATION}"
    ;;
  *)
    echo "::error::unsupported production operation" >&2
    exit 2
    ;;
esac

# These failures occur before or while Fly establishes the SSH tunnel. Command
# failures such as a failed restic check must still fail without a retry.
transient_pattern='tunnel unavailable|Error contacting Fly\.io API|context deadline exceeded|connection (reset|refused)|i/o timeout|TLS handshake timeout|temporary failure in name resolution|HTTP (502|503|504)'

log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

deadline=$((SECONDS + budget_seconds))
attempt=1
while (( attempt <= max_attempts )); do
  remaining=$((deadline - SECONDS))
  if (( remaining <= 0 )); then
    echo "::error::Fly operation timed out before attempt ${attempt}" >&2
    exit 124
  fi

  set +e
  timeout "$remaining" flyctl ssh console --app "$FLY_APP" --command "$command" \
    2>&1 | sed -E "$FLY_LOG_REDACT" | tee "$log_file"
  status="${PIPESTATUS[0]}"
  set -e

  if (( status == 0 )); then
    exit 0
  fi
  if (( status == 124 )); then
    echo "::error::Fly operation exceeded its ${budget_seconds}s budget" >&2
    exit "$status"
  fi
  if ! grep -Eiq "$transient_pattern" "$log_file"; then
    exit "$status"
  fi
  if (( attempt == max_attempts )); then
    echo "::error::Fly transport remained unavailable after ${max_attempts} attempts" >&2
    exit "$status"
  fi

  delay=$((retry_delay_seconds * attempt))
  if (( delay >= deadline - SECONDS )); then
    echo "::error::No budget remains for another Fly operation attempt" >&2
    exit "$status"
  fi
  echo "Fly transport failed transiently; retrying in ${delay}s (attempt $((attempt + 1))/${max_attempts})" >&2
  sleep "$delay"
  attempt=$((attempt + 1))
done
