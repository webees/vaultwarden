#!/bin/sh
# Shared assertions for the test scripts. Sourced, never executed directly.
failures=0

ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

report() { # suite name
    if [ "$failures" -eq 0 ]; then
        printf '%s passed\n' "$1"
    else
        printf '%s %s failed\n' "$failures" "$1" >&2
        exit 1
    fi
}
