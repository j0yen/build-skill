#!/usr/bin/env bash
# secretcont_ac3_credential_reuse_guard_flags_unbacked_claim.sh —
# PRD-build-tenant-secret-continuity AC3: given a PRD file whose text
# contains a credential-reuse claim with no matching secrets-path file,
# when the new guard (prd-lint.sh's credential-reuse-unbacked check)
# runs, then it flags the PRD by name (warn, not fail) -- and does NOT
# flag it once a matching secret file exists, and does NOT flag a PRD
# with no such claim at all. Exercises prd-lint.sh directly against
# fresh fixtures (not just trusting prd-lint-selftest.sh's own run).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/build-queue" "$tmp/visions" "$tmp/state-scratch"
echo "plain vision" > "$tmp/visions/plain.md"

fails=0

has_id() { # $1=json $2=field(failures|warnings) $3=id
  printf '%s' "$1" | python3 -c "
import json, sys
d = json.load(sys.stdin)[0]
ids = [x['id'] for x in d.get('$2', [])]
sys.exit(0 if '$3' in ids else 1)
"
}

cat > "$tmp/build-queue/PRD-secretcont-claim.md" <<'EOF'
- Status: building
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given the tenant key already held from a prior dispatch, When reused, Then it just works.
EOF

cat > "$tmp/build-queue/PRD-secretcont-clean.md" <<'EOF'
- Status: building
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a clean run, When it starts, Then no credential claim is made.
EOF

out="$(BUILD_STATE_DIR="$tmp/state-scratch" "$LINT" --format json "$tmp/build-queue/PRD-secretcont-claim.md" 2>/dev/null)"
if has_id "$out" warnings credential-reuse-unbacked; then
  echo "ok  SECRETCONT AC3: unbacked credential-reuse claim is flagged (no secret file)"
else
  echo "FAIL SECRETCONT AC3: expected credential-reuse-unbacked warning, got: $out"
  fails=$((fails + 1))
fi

mkdir -p "$tmp/state-scratch/secrets/secretcont-claim"
echo '{"value":"x","written_at":"2026-01-01T00:00:00Z"}' > "$tmp/state-scratch/secrets/secretcont-claim/tenant_key.json"
out="$(BUILD_STATE_DIR="$tmp/state-scratch" "$LINT" --format json "$tmp/build-queue/PRD-secretcont-claim.md" 2>/dev/null)"
if has_id "$out" warnings credential-reuse-unbacked; then
  echo "FAIL SECRETCONT AC3: still flagged once a matching secret file exists: $out"
  fails=$((fails + 1))
else
  echo "ok  SECRETCONT AC3: claim with a backing secret file is NOT flagged"
fi

out="$(BUILD_STATE_DIR="$tmp/state-scratch" "$LINT" --format json "$tmp/build-queue/PRD-secretcont-clean.md" 2>/dev/null)"
if has_id "$out" warnings credential-reuse-unbacked; then
  echo "FAIL SECRETCONT AC3: a PRD with no credential claim was flagged anyway: $out"
  fails=$((fails + 1))
else
  echo "ok  SECRETCONT AC3: a PRD with no credential claim is NOT flagged"
fi

if [ "$fails" -eq 0 ]; then
  echo "ok  SECRETCONT AC3: ALL PASS"
  exit 0
else
  echo "FAIL SECRETCONT AC3: $fails check(s) failed"
  exit 1
fi
