#!/usr/bin/env bash
# answerable-emit.sh — emit a structured record to the answerable ledger
# Usage: answerable-emit.sh <kind> <target> <why> [reversible]
# If answerable is not on $PATH, prints a note to stderr and exits 0 (never blocks a build).
set -uo pipefail

KIND="${1:?Usage: answerable-emit.sh <kind> <target> <why> [reversible]}"
TARGET="${2:?Usage: answerable-emit.sh <kind> <target> <why> [reversible]}"
WHY="${3:?Usage: answerable-emit.sh <kind> <target> <why> [reversible]}"
REVERSIBLE="${4:-false}"

if ! command -v answerable >/dev/null 2>&1; then
    echo "answerable-emit: answerable not on PATH; skipping ledger record (kind=$KIND target=$TARGET)" >&2
    exit 0
fi

if [[ "$REVERSIBLE" == "true" ]]; then
    answerable record --kind "$KIND" --target "$TARGET" --why "$WHY" --reversible
else
    answerable record --kind "$KIND" --target "$TARGET" --why "$WHY"
fi
