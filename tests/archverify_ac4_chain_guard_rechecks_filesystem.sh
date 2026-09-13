#!/usr/bin/env bash
# archverify_ac4_chain_guard_rechecks_filesystem.sh —
# PRD-build-archive-verify-before-shipped acceptance criterion 4 /
# requirement 3: given a manifest entry with `status: shipped` but the
# PRD file still present in build-queue/ (the exact stuck state found
# 2026-09-13 across four real slugs), when chain-guard.sh check
# evaluates `archive-done` for that slug, then it does NOT return
# `stop: archive-done` — it returns a verdict directing one retry of the
# archive step instead (`continue: <slug>: archive-incomplete`).
#
# No git fixture needed here — chain-guard.sh's own filesystem check
# only cares about plain file presence/absence under --prd-dir, exactly
# like the tests/chained-tick_ac*.sh siblings this mirrors.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CG="$HERE/../scripts/chain-guard.sh"
MS="$HERE/../scripts/manifest-set.sh"
[ -x "$CG" ] && [ -x "$MS" ] || { echo "archverify_ac4: helper scripts not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/archverify-ac4.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_STATE_DIR="$T/state"
export BUILD_MANIFEST="$BUILD_STATE_DIR/manifest.json"
mkdir -p "$BUILD_STATE_DIR/intent"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}
patch() { local slug="$1" json="$2" f; f="$(mktemp "$T/patch.XXXXXX.json")"; printf '%s' "$json" > "$f"; "$MS" "$slug" "$f"; }

# ---- the stuck state: status says shipped, file never moved ----------
STUCK="stuck-fixture"
mkdir -p "$T/build-queue"
cat > "$T/build-queue/PRD-$STUCK.md" <<EOF
# PRD: $STUCK
- Status: shipped
- build_target: shell
EOF
cat > "$BUILD_MANIFEST" <<JSON
{"prds": {"$STUCK": {"slug": "$STUCK", "status": "shipped", "build_target": "shell", "blockers": []}}}
JSON

out="$("$CG" check "$STUCK" --step-count 1 --prd-dir "$T" --skip-select-guard)"; rc=$?
expect "stuck fixture: chain-guard does NOT stop on archive-done" "! grep -q 'archive-done' <<<\"\$out\""
expect "stuck fixture: chain-guard returns a continue verdict"     "[ $rc -eq 0 ]"
expect "stuck fixture: reason is archive-incomplete"               "grep -q 'continue: stuck-fixture: archive-incomplete' <<<\"\$out\""
expect "stuck fixture: the PRD file is (still) untouched in build-queue/" \
  "[ -f '$T/build-queue/PRD-$STUCK.md' ]"

# ---- regression: a REAL archive (file actually moved) still stops on
# archive-done exactly as before this PRD. -----------------------------
DONE="done-fixture"
mkdir -p "$T/built-prds"
cat > "$T/built-prds/PRD-$DONE.md" <<EOF
# PRD: $DONE
- Status: built
- build_target: shell
EOF
cat > "$BUILD_MANIFEST" <<JSON
{"prds": {"$DONE": {"slug": "$DONE", "status": "shipped", "build_target": "shell", "blockers": []}}}
JSON

out="$("$CG" check "$DONE" --step-count 1 --prd-dir "$T" --skip-select-guard)"; rc=$?
expect "done fixture: chain-guard stops"                 "[ $rc -eq 1 ]"
expect "done fixture: stop reason is archive-done"        "grep -q 'stop: done-fixture: archive-done' <<<\"\$out\""

exit $fail
