#!/usr/bin/env bash
# tests/mainpin_gate_red_summary_pinned_r9.sh —
# PRD-build-main-verdict-pinned-to-landing R9/AC11: gate-red-summary.sh
# must recognize extend-gate.sh's own "gate <crate> <outcome> (...)"
# journal shape for a pinned main-scope run (trailing " pinned=landing")
# and a bare-HEAD main-health run (trailing " main-health") — a shape it
# never parsed before this PRD (it only knew gate-then-land/verify-gate-
# red/archive lines).
#
#   Case A (AC11) — slugX gate-blocks at M1, then passes at M1 later ->
#     red_slugs must NOT show slugX@M1 (latest verdict at M1 is pass).
#   Case B (AC11) — slugX blocks at M1 (stays red) and separately passes
#     at a DIFFERENT M2 -> red_slugs shows slugX@<M1 sha7> (the M1 block),
#     never attributed away by the M2 pass ("a block at some other HEAD
#     is never attributed to S" reads the other direction too: a pass at
#     a different M never clears a block at this M).
#   Case C (R6) — a main-health block at head N -> red_slugs shows
#     "<repo>@<N sha7> main-health", keyed by repo, not the main-health
#     sentinel slug alone.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
GRS="$SKILL_DIR/scripts/gate-red-summary.sh"
[ -x "$GRS" ] || { echo "FAIL: $GRS not executable" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not on PATH" >&2; exit 1; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    echo "ok  $label"
  else
    echo "FAIL $label ($cond)" >&2
    fail=1
  fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/mainpin-gate-red-summary-r9.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------
# Case A — block then pass at the SAME M -> not red.
# ---------------------------------------------------------------------
D="$T/a"; mkdir -p "$D/journal" "$D/state"
cat > "$D/journal/2026-01-01.md" <<'EOF'
2026-01-01T00:00:00Z  gate  mcphost  block  (scope=main slug=slugX head=deadbeef1234567890 base=v1 summary blocking=ci-checks wall=10s lock_wait=0s cargo=burst:0/local:1 routed=1/1 route=local) pinned=landing
2026-01-01T00:05:00Z  gate  mcphost  pass  (scope=main slug=slugX head=deadbeef1234567890 base=v1 summary blocking=none wall=10s lock_wait=0s cargo=burst:0/local:1 routed=1/1 route=local) pinned=landing
EOF
outA="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" "$GRS" --now 2026-01-01T01:00:00Z --window-h 2)"
rcA=$?
expect "A exit 0" "[ $rcA -eq 0 ]"
expect "A green=1 red=0" "[[ \"\$outA\" == *'green=1 red=0'* ]]"
expect "A red_slugs empty (no slugX@ entry)" "[[ \"\$outA\" != *'slugX@'* ]]"

# ---------------------------------------------------------------------
# Case B — block at M1 stays red; pass at a DIFFERENT M2 for the same
# slug must not clear the M1 block.
# ---------------------------------------------------------------------
D="$T/b"; mkdir -p "$D/journal" "$D/state"
cat > "$D/journal/2026-01-01.md" <<'EOF'
2026-01-01T00:00:00Z  gate  mcphost  block  (scope=main slug=slugX head=1111111aaaaaaaaaaaa base=v1 summary blocking=ci-checks wall=10s lock_wait=0s cargo=burst:0/local:1 routed=1/1 route=local) pinned=landing
2026-01-01T00:05:00Z  gate  mcphost  pass  (scope=main slug=slugX head=2222222bbbbbbbbbbbb base=v1 summary blocking=none wall=10s lock_wait=0s cargo=burst:0/local:1 routed=1/1 route=local) pinned=landing
EOF
outB="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" "$GRS" --now 2026-01-01T01:00:00Z --window-h 2)"
rcB=$?
expect "B exit 0" "[ $rcB -eq 0 ]"
expect "B green=1 red=1" "[[ \"\$outB\" == *'green=1 red=1'* ]]"
expect "B red_slugs names slugX@1111111 (M1)" "[[ \"\$outB\" == *'slugX@1111111'* ]]"
expect "B red_slugs never names slugX@2222222 (M2, the pass)" "[[ \"\$outB\" != *'slugX@2222222'* ]]"
jsonB="$(cat "$D/state/gate-red.json")"
expect "B json red_slugs=[slugX@1111111]" "[ \"\$(printf '%s' \"\$jsonB\" | jq -c .red_slugs)\" = '[\"slugX@1111111\"]' ]"

# ---------------------------------------------------------------------
# Case C — a main-health block at head N -> "<repo>@<N7> main-health".
# ---------------------------------------------------------------------
D="$T/c"; mkdir -p "$D/journal" "$D/state"
cat > "$D/journal/2026-01-01.md" <<'EOF'
2026-01-01T00:00:00Z  gate  mcphost  block  (scope=main slug=main-health head=3333333cccccccccccc base=v1 summary blocking=ci-checks wall=10s lock_wait=0s cargo=burst:0/local:1 routed=1/1 route=local) main-health
EOF
outC="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" "$GRS" --now 2026-01-01T01:00:00Z --window-h 2)"
rcC=$?
expect "C exit 0" "[ $rcC -eq 0 ]"
expect "C red=1" "[[ \"\$outC\" == *'red=1'* ]]"
expect "C red_slugs names mcphost@3333333 main-health" "[[ \"\$outC\" == *'mcphost@3333333 main-health'* ]]"
expect "C red_slugs never names the main-health sentinel alone" "[[ \"\$outC\" != *'main-health@'* ]]"

# ---------------------------------------------------------------------
# Case D — this PRD's shape must not disturb an ordinary gate-then-land/
# archive-shaped fixture (byte-identical regression against the
# pre-existing classifier, mixed in the same window).
# ---------------------------------------------------------------------
D="$T/d"; mkdir -p "$D/journal" "$D/state"
cat > "$D/journal/2026-01-01.md" <<'EOF'
2026-01-01T00:00:00Z  gate-then-land  slug1  gate-block attempt=1 blockers=a
2026-01-01T00:05:00Z  slug3  archive  archived  (repo=fixture)
2026-01-01T00:10:00Z  gate  mcphost  block  (scope=main slug=slugX head=4444444dddddddddddd base=v1 summary blocking=ci-checks wall=10s lock_wait=0s cargo=burst:0/local:1 routed=1/1 route=local) pinned=landing
EOF
outD="$(BUILD_JOURNAL_ROOT="$D/journal" BUILD_STATE_DIR="$D/state" "$GRS" --now 2026-01-01T01:00:00Z --window-h 2)"
expect "D green=1 red=2 (slug1 + slugX@M, unaffected by each other)" "[[ \"\$outD\" == *'green=1 red=2'* ]]"
expect "D names slug1" "[[ \"\$outD\" == *'slug1'* ]]"
expect "D names slugX@4444444" "[[ \"\$outD\" == *'slugX@4444444'* ]]"

echo "mainpin_gate_red_summary_pinned_r9: done (fail=$fail)"
exit "$fail"
