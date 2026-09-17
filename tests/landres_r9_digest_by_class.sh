#!/usr/bin/env bash
# landres_r9_digest_by_class.sh —
# PRD-build-land-conflict-resolver R9 (P1, "the daily digest / day ledger
# ... reports conflicts resolved by class"): given a ledger with records
# across all three classes and both source resolutions, When
# scripts/land-conflicts-digest.sh runs, Then it prints one line with the
# right per-class/per-resolution counts; When it runs against an empty or
# missing ledger, Then every count is 0 (no error); When a record falls
# outside the --days window, Then it is excluded from the count.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIGEST="$HERE/../scripts/land-conflicts-digest.sh"
[ -x "$DIGEST" ] || { echo "FAIL: $DIGEST not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LEDGER="$WORK/land-conflicts.jsonl"
NOW="2026-09-17T20:00:00Z"

fail=0

# --- empty/missing ledger -> all zero, no error -------------------------
out_missing="$(LAND_CONFLICTS_DIGEST_NOW="$NOW" "$DIGEST" "$WORK/nope.jsonl" 2>&1)"; rc_missing=$?
if [ "$rc_missing" -eq 0 ] && [ "$out_missing" = "land-conflicts: generated=0 regen=0 append_only=0 union=0 source=0 coder=0 unresolved=0" ]; then
  echo "ok  R9: missing ledger digests to all-zero, exit 0"
else
  echo "FAIL: missing-ledger digest expected all-zero/rc=0, got rc=$rc_missing out='$out_missing'" >&2
  fail=1
fi

# --- populated ledger, today's window -----------------------------------
cat >"$LEDGER" <<EOF
{"ts": "2026-09-17T18:00:00Z", "repo": "mcphost", "slug": "s1", "file": "agent/intent-card.json", "class": "generated", "resolution": "regen", "wall_seconds": 3}
{"ts": "2026-09-17T18:05:00Z", "repo": "mcphost", "slug": "s2", "file": "agent/intent-card.json", "class": "generated", "resolution": "regen", "wall_seconds": 2}
{"ts": "2026-09-17T18:10:00Z", "repo": "mcphost", "slug": "s3", "file": "CHANGELOG.md", "class": "append_only", "resolution": "union", "wall_seconds": 1}
{"ts": "2026-09-17T18:15:00Z", "repo": "mcphost", "slug": "s4", "file": "src/db.rs", "class": "source", "resolution": "coder", "wall_seconds": 240}
{"ts": "2026-09-17T18:20:00Z", "repo": "mcphost", "slug": "s5", "file": "src/handler.rs", "class": "source", "resolution": "unresolved", "wall_seconds": 900}
EOF
# a record from yesterday -- excluded by the default 1-day window
echo '{"ts": "2026-09-16T12:00:00Z", "repo": "mcphost", "slug": "old", "file": "CHANGELOG.md", "class": "append_only", "resolution": "union", "wall_seconds": 1}' >>"$LEDGER"

out="$(LAND_CONFLICTS_DIGEST_NOW="$NOW" "$DIGEST" "$LEDGER" 2>&1)"; rc=$?
expected="land-conflicts: generated=2 regen=2 append_only=1 union=1 source=2 coder=1 unresolved=1"
if [ "$rc" -eq 0 ] && [ "$out" = "$expected" ]; then
  echo "ok  R9: populated ledger digests to expected per-class/resolution counts, yesterday's record excluded"
else
  echo "FAIL: expected '$expected' rc=0, got rc=$rc out='$out'" >&2
  fail=1
fi

# --- --days 2 window includes yesterday's record too ---------------------
out_2d="$(LAND_CONFLICTS_DIGEST_NOW="$NOW" "$DIGEST" --days 2 "$LEDGER" 2>&1)"; rc_2d=$?
expected_2d="land-conflicts: generated=2 regen=2 append_only=2 union=2 source=2 coder=1 unresolved=1"
if [ "$rc_2d" -eq 0 ] && [ "$out_2d" = "$expected_2d" ]; then
  echo "ok  R9: --days 2 widens the window to include yesterday's record"
else
  echo "FAIL: expected '$expected_2d' rc=0, got rc=$rc_2d out='$out_2d'" >&2
  fail=1
fi

exit $fail
