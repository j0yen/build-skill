#!/usr/bin/env bash
# manifest-reconcile-selftest.sh — hermetic acceptance harness for
# manifest-reconcile.sh (PRD-build-manifest-reconcile). Builds throwaway
# PRD trees + manifests under a tempdir (never touches the real
# ~/Documents/PRDs or state/manifest.json) and asserts AC1-AC6.
#
# Run: bash scripts/manifest-reconcile-selftest.sh   (exit 0 = all pass)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RC="$HERE/manifest-reconcile.sh"
JQ="${JQ:-$(command -v jq || echo /usr/bin/jq)}"
PASS=0; FAIL=0
ck() { if eval "$2"; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); fi; }

status_of() { "$JQ" -r --arg s "$1" '.prds[$s].status // "null"' "$2"; }
field_of()  { "$JQ" -r --arg s "$1" --arg k "$2" '.prds[$s][$k] // "null"' "$3"; }

new_fixture() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/reconcile-selftest.XXXXXX")"
  mkdir -p "$T/prds/build-queue" "$T/prds/built-prds" "$T/prds/parked" "$T/state"
}

run_rc() { # [extra args...]
  PRD_DIR="$T/prds" BUILD_STATE_DIR="$T/state" BUILD_MANIFEST="$T/state/manifest.json" \
    bash "$RC" "$@"
}

# ---- AC1: file Status: built, manifest queued -> becomes built, nothing
# else in the entry changes -----------------------------------------------
new_fixture
cat > "$T/prds/build-queue/PRD-ac1.md" <<'EOF'
- Status: built
EOF
cat > "$T/state/manifest.json" <<EOF
{"prds": {"ac1": {"slug":"ac1","status":"queued","build_target":"shell","ticks_invested":3}}}
EOF
out="$(run_rc)"
ck "AC1 status becomes built" '[ "$(status_of ac1 "$T/state/manifest.json")" = built ]'
ck "AC1 table shows the change" 'grep -q "ac1" <<<"$out" && grep -q "built" <<<"$out"'
ck "AC1 unrelated field untouched" '[ "$(field_of ac1 ticks_invested "$T/state/manifest.json")" = 3 ]'
rm -rf "$T"

# ---- AC2: file in built-prds/, entry in_progress -> archived -------------
new_fixture
cat > "$T/prds/built-prds/PRD-ac2.md" <<'EOF'
- Status: queued
EOF
cat > "$T/state/manifest.json" <<EOF
{"prds": {"ac2": {"slug":"ac2","status":"in_progress"}}}
EOF
run_rc >/dev/null
ck "AC2 status becomes archived" '[ "$(status_of ac2 "$T/state/manifest.json")" = archived ]'
rm -rf "$T"

# ---- AC3: extend PRD, build_into set, entry lacks output_repo_path -------
new_fixture
cat > "$T/prds/build-queue/PRD-ac3.md" <<'EOF'
- Status: queued
- build_target: rust-extend
- build_into: /tmp/reconcile-ac3-repo
EOF
cat > "$T/state/manifest.json" <<EOF
{"prds": {"ac3": {"slug":"ac3","status":"queued","build_target":"rust-extend","build_into":"/tmp/reconcile-ac3-repo"}}}
EOF
run_rc >/dev/null
ck "AC3 output_repo_path derived" '[ "$(field_of ac3 output_repo_path "$T/state/manifest.json")" = /tmp/reconcile-ac3-repo ]'
rm -rf "$T"

# ---- AC4: orphan entry -> vanished with timestamp; dropped after 7 days --
new_fixture
old_ts="$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=8)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
cat > "$T/state/manifest.json" <<EOF
{"prds": {"ac4-fresh": {"slug":"ac4-fresh","status":"queued"},
          "ac4-old": {"slug":"ac4-old","status":"vanished","vanished_since":"$old_ts"}}}
EOF
run_rc >/dev/null
ck "AC4 orphan marked vanished" '[ "$(status_of ac4-fresh "$T/state/manifest.json")" = vanished ]'
ck "AC4 timestamp set" '[ "$(field_of ac4-fresh vanished_since "$T/state/manifest.json")" != null ]'
run_rc >/dev/null   # second run: 7+ day old vanished entry drops
ck "AC4 old vanished entry dropped" '[ "$(status_of ac4-old "$T/state/manifest.json")" = null ]'
rm -rf "$T"

# ---- AC5: --dry-run prints the table, manifest byte-identical afterwards
new_fixture
cat > "$T/prds/build-queue/PRD-ac5.md" <<'EOF'
- Status: built
EOF
cat > "$T/state/manifest.json" <<EOF
{"prds": {"ac5": {"slug":"ac5","status":"queued"}}}
EOF
cp "$T/state/manifest.json" "$T/state/manifest.json.before"
out="$(run_rc --dry-run)"
ck "AC5 dry-run prints table" 'grep -q "ac5" <<<"$out"'
ck "AC5 dry-run manifest byte-identical" 'cmp -s "$T/state/manifest.json" "$T/state/manifest.json.before"'
rm -rf "$T"

# ---- AC6 (partial — the tick-wiring half is exercised in SKILL.md, not
# here): summary line carries reconciled: n -----------------------------
new_fixture
cat > "$T/prds/build-queue/PRD-ac6a.md" <<'EOF'
- Status: built
EOF
cat > "$T/prds/build-queue/PRD-ac6b.md" <<'EOF'
- Status: queued
EOF
cat > "$T/state/manifest.json" <<EOF
{"prds": {"ac6a": {"slug":"ac6a","status":"queued"}, "ac6b": {"slug":"ac6b","status":"queued"}}}
EOF
out="$(run_rc)"
ck "AC6 reconciled count line present" 'grep -qE "^reconciled: 1$" <<<"$out"'
rm -rf "$T"

# ---- extra: blockers cleared when Blocked: line gone ---------------------
new_fixture
cat > "$T/prds/build-queue/PRD-unblk.md" <<'EOF'
- Status: blocked
EOF
cat > "$T/state/manifest.json" <<EOF
{"prds": {"unblk": {"slug":"unblk","status":"blocked","blockers":["waiting on X"]}}}
EOF
run_rc >/dev/null
ck "blockers cleared when Blocked: line absent" '[ "$(field_of unblk blockers "$T/state/manifest.json")" = "[]" ]'
rm -rf "$T"

# ---- extra: parked/ directory maps to status=parked ----------------------
new_fixture
cat > "$T/prds/parked/PRD-shelf.md" <<'EOF'
- Status: queued
EOF
cat > "$T/state/manifest.json" <<EOF
{"prds": {"shelf": {"slug":"shelf","status":"queued"}}}
EOF
run_rc >/dev/null
ck "parked/ maps to status=parked" '[ "$(status_of shelf "$T/state/manifest.json")" = parked ]'
rm -rf "$T"

# ---- extra: scan-prds.sh --reconcile delegates and agrees ----------------
new_fixture
cat > "$T/prds/build-queue/PRD-delegate.md" <<'EOF'
- Status: built
EOF
cat > "$T/state/manifest.json" <<EOF
{"prds": {"delegate": {"slug":"delegate","status":"queued"}}}
EOF
out="$(PRD_DIR="$T/prds" BUILD_STATE_DIR="$T/state" BUILD_MANIFEST="$T/state/manifest.json" bash "$HERE/scan-prds.sh" --reconcile --dry-run)"
ck "scan-prds.sh --reconcile delegates" 'grep -q "delegate" <<<"$out"'
rm -rf "$T"

echo "----"
echo "manifest-reconcile-selftest: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
