#!/usr/bin/env bash
# scripts/skill-single-source-selftest.sh — the one entrypoint for
# PRD-build-skill-instruction-single-source's fixture coverage
# (test_prefix: skillsrc; R6/AC9 names this file). Exercises
# archive-gate.sh (AC1-AC4), gate-launch.sh's R3 refusal (AC4),
# skill-prose-lint.sh (AC6/AC7/AC10), the shipped docs/operator.md itself
# (AC5/AC8 — PRD-build-branch-contract-split moved the canonical section
# out of SKILL.md and into docs/operator.md's full-procedure appendix;
# this selftest's file targets and the AC5 heading-level check moved with
# it), and prompt-file coverage (AC8). Every fixture builds its own
# throwaway git repo + state dir under $TMPDIR and tears it down on exit
# — nothing here touches the running skill's production state/journal or
# a real fleet repo (BUILD_STATE_DIR/journal overrides are exported per
# fixture below; run-selftests.sh's own isolation wraps this further when
# invoked through it).
#
# Usage: skill-single-source-selftest.sh
# Exit: 0 all green ("PASS" printed) | 1 one or more failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
ARCHIVE_GATE="$HERE/archive-gate.sh"
GATE_LAUNCH="$HERE/gate-launch.sh"
LINT="$HERE/skill-prose-lint.sh"

for f in "$ARCHIVE_GATE" "$GATE_LAUNCH" "$LINT"; do
  [ -x "$f" ] || { echo "skill-single-source-selftest: missing/non-executable: $f" >&2; exit 2; }
done

fail=0
expect() { # <label> <shell-cond-string>
  local label="$1" cond="$2"
  if eval "$cond"; then
    echo "ok  $label"
  else
    echo "FAIL $label" >&2
    fail=1
  fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/skillsrc-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

new_repo() { # <name> -> path, a fresh git repo with one commit
  local d="$T/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  echo "$d"
}

stub_gate_launch() { # writes a stub gate-launch.sh into $1 that logs its argv
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
echo "STUB-GATE-LAUNCH-ARGS: $*"
printf '%s\n' "$*" >> "${STUB_GATE_LAUNCH_LOG:?}"
exit "${STUB_GATE_LAUNCH_RC:-0}"
EOF
  chmod +x "$1"
}

# ---------------------------------------------------------------------------
# AC1 (R6a) — push_via_branch=true, landing record exists -> pinned form
# ---------------------------------------------------------------------------
echo "== AC1: existing landing record launches the pinned form =="
repo_a="$(new_repo repo-a)"
slug_a=slug-a
repo_slug_a="$(basename "$repo_a")"
export BUILD_STATE_DIR="$T/state-a"
mkdir -p "$BUILD_STATE_DIR/landings/$repo_slug_a"
cat > "$BUILD_STATE_DIR/branch-protection.json" <<EOF
{"$repo_slug_a": {"push_via_branch": true}}
EOF
cat > "$BUILD_STATE_DIR/landings/$repo_slug_a/$slug_a.json" <<'EOF'
{"pr_url":"https://github.com/j0yen/x/pull/1","pr_number":1,"head_sha":"aaa","merge_sha":"bbb","armed_at":"2026-09-17T00:00:00Z"}
EOF
export ARCHIVE_GATE_GATE_LAUNCH="$T/stub-gate-launch-a.sh"
stub_gate_launch "$ARCHIVE_GATE_GATE_LAUNCH"
export STUB_GATE_LAUNCH_LOG="$T/log-a.txt" STUB_GATE_LAUNCH_RC=0
export ARCHIVE_GATE_JOURNAL="$T/journal-a.md"
out_a="$("$ARCHIVE_GATE" "$repo_a" "$slug_a" --wait 2>&1)"; rc_a=$?
expect "AC1: exit code is the stub's (0)" "[ $rc_a -eq 0 ]"
expect "AC1: stub recorded --scope main --slug $slug_a --pinned-landing" \
  "grep -qE -- '--scope main .*--slug '\"$slug_a\"' .*--pinned-landing' '$T/log-a.txt'"
expect "AC1: archive-gate printed the command it ran" "grep -q 'archive-gate:' <<<\"$out_a\""
unset ARCHIVE_GATE_GATE_LAUNCH STUB_GATE_LAUNCH_LOG STUB_GATE_LAUNCH_RC ARCHIVE_GATE_JOURNAL BUILD_STATE_DIR

# ---------------------------------------------------------------------------
# AC2 (R6b) — push_via_branch=true, no record, stub gh returns a merged PR
# -> record reconstructed then the pinned form is launched
# ---------------------------------------------------------------------------
echo "== AC2: missing record reconstructed from a merged loop/<slug> PR =="
repo_b="$(new_repo repo-b)"
slug_b=slug-b
repo_slug_b="$(basename "$repo_b")"
export BUILD_STATE_DIR="$T/state-b"
mkdir -p "$BUILD_STATE_DIR"
cat > "$BUILD_STATE_DIR/branch-protection.json" <<EOF
{"$repo_slug_b": {"push_via_branch": true}}
EOF
export ARCHIVE_GATE_GATE_LAUNCH="$T/stub-gate-launch-b.sh"
stub_gate_launch "$ARCHIVE_GATE_GATE_LAUNCH"
export STUB_GATE_LAUNCH_LOG="$T/log-b.txt" STUB_GATE_LAUNCH_RC=0
export ARCHIVE_GATE_JOURNAL="$T/journal-b.md"
export ARCHIVE_GATE_GH="$T/stub-gh-b.sh"
cat > "$ARCHIVE_GATE_GH" <<'EOF'
#!/usr/bin/env bash
echo '{"number":7,"url":"https://github.com/j0yen/x/pull/7","state":"MERGED","mergeCommit":{"oid":"ccc111"},"headRefOid":"ddd222"}'
exit 0
EOF
chmod +x "$ARCHIVE_GATE_GH"
out_b="$("$ARCHIVE_GATE" "$repo_b" "$slug_b" --wait 2>&1)"; rc_b=$?
record_b="$BUILD_STATE_DIR/landings/$repo_slug_b/$slug_b.json"
expect "AC2: exit code is the stub's (0)" "[ $rc_b -eq 0 ]"
expect "AC2: landing record was written" "[ -f '$record_b' ]"
expect "AC2: record's merge_sha is the reconstructed one" \
  "[ \"\$(python3 -c 'import json;print(json.load(open(\"$record_b\")).get(\"merge_sha\"))')\" = ccc111 ]"
expect "AC2: record carries reconstructed_from" \
  "python3 -c 'import json,sys;d=json.load(open(\"$record_b\"));sys.exit(0 if d.get(\"reconstructed_from\") else 1)'"
expect "AC2: pinned form launched after reconstruction" \
  "grep -qE -- '--scope main .*--slug '\"$slug_b\"' .*--pinned-landing' '$T/log-b.txt'"
unset ARCHIVE_GATE_GATE_LAUNCH STUB_GATE_LAUNCH_LOG STUB_GATE_LAUNCH_RC ARCHIVE_GATE_JOURNAL ARCHIVE_GATE_GH BUILD_STATE_DIR

# ---------------------------------------------------------------------------
# AC3 (R6c) — direct-push fixture -> plain form with the landed (HEAD) sha
# ---------------------------------------------------------------------------
echo "== AC3: direct-push repo gets the plain form, no --pinned-landing =="
repo_c="$(new_repo repo-c)"
slug_c=slug-c
head_c="$(git -C "$repo_c" rev-parse HEAD)"
export BUILD_STATE_DIR="$T/state-c"
mkdir -p "$BUILD_STATE_DIR"
# No branch-protection.json entry at all -- push_via_branch_for() defaults false.
export ARCHIVE_GATE_GATE_LAUNCH="$T/stub-gate-launch-c.sh"
stub_gate_launch "$ARCHIVE_GATE_GATE_LAUNCH"
export STUB_GATE_LAUNCH_LOG="$T/log-c.txt" STUB_GATE_LAUNCH_RC=0
export ARCHIVE_GATE_JOURNAL="$T/journal-c.md"
out_c="$("$ARCHIVE_GATE" "$repo_c" "$slug_c" --wait 2>&1)"; rc_c=$?
expect "AC3: exit code is the stub's (0)" "[ $rc_c -eq 0 ]"
expect "AC3: stub recorded plain form with the landed sha, no --pinned-landing" \
  "grep -qE -- \"--head $head_c --scope main --slug $slug_c --wait\\\$\" '$T/log-c.txt'"
expect "AC3: journal line shape matches the baseline (repo slug + action)" \
  "grep -qE '^[0-9T:Z-]+  '\"$slug_c\"'  archive-gate  launch' '$T/journal-c.md'"
unset ARCHIVE_GATE_GATE_LAUNCH STUB_GATE_LAUNCH_LOG STUB_GATE_LAUNCH_RC ARCHIVE_GATE_JOURNAL BUILD_STATE_DIR

# ---------------------------------------------------------------------------
# AC4 (R6d) — a raw --scope main call against fixture (a)'s repo is refused
# ---------------------------------------------------------------------------
echo "== AC4: gate-launch.sh refuses the raw form once a landing record exists =="
FIXDIR="$SKILL_DIR/tests/fixtures/gatelaunch-fake"
export BUILD_STATE_DIR="$T/state-a"  # re-use AC1's repo-a / slug-a / record
export GATE_LAUNCH_EXTEND_GATE="$FIXDIR/extend-gate.sh"
export GATE_LAUNCH_MAIN_VERDICT_PIN_GATE="$T/fake-mvpg.sh"
export GATE_LAUNCH_JOURNAL="$T/journal-d.md"
export GATE_LAUNCH_SYSTEMD_RUN="$FIXDIR/systemd-run"
export GATE_LAUNCH_SYSTEMCTL="$FIXDIR/systemctl"
export FAKE_SYSTEMD_STATE_DIR="$T/systemd-state-d"
mkdir -p "$FAKE_SYSTEMD_STATE_DIR"
cat > "$GATE_LAUNCH_MAIN_VERDICT_PIN_GATE" <<'EOF'
#!/usr/bin/env bash
echo "mvpg called: $*"; exit 0
EOF
chmod +x "$GATE_LAUNCH_MAIN_VERDICT_PIN_GATE"
out_d="$("$GATE_LAUNCH" "$repo_a" --head deadbeef --scope main --slug "$slug_a" 2>&1)"; rc_d=$?
expect "AC4: refusal exits non-zero (6)" "[ $rc_d -eq 6 ]"
expect "AC4: refusal names archive-gate.sh" "grep -q 'archive-gate.sh' <<<\"$out_d\""
expect "AC4: no inflight marker was written (refused before launch)" \
  "[ ! -f \"$BUILD_STATE_DIR/gate-inflight/$slug_a.json\" ]"
out_d_pinned="$("$GATE_LAUNCH" "$repo_a" --head deadbeef --scope main --slug "$slug_a" --pinned-landing 2>&1)"; rc_d_pinned=$?
expect "AC4: --pinned-landing calls are unaffected" "[ $rc_d_pinned -eq 0 ]"
out_d_health="$("$GATE_LAUNCH" "$repo_a" --head deadbeef --scope main --main-health 2>&1)"; rc_d_health=$?
expect "AC4: --main-health calls are unaffected" "[ $rc_d_health -eq 0 ]"
unset BUILD_STATE_DIR GATE_LAUNCH_EXTEND_GATE GATE_LAUNCH_MAIN_VERDICT_PIN_GATE GATE_LAUNCH_JOURNAL GATE_LAUNCH_SYSTEMD_RUN GATE_LAUNCH_SYSTEMCTL FAKE_SYSTEMD_STATE_DIR

# ---------------------------------------------------------------------------
# AC5 — the shipped docs/operator.md has exactly one canonical section and
# no raw fenced-block form outside it (PRD-build-branch-contract-split
# moved the section here from SKILL.md; heading level bumped ### -> ####
# since it now nests under operator.md's own "Full tick procedure" H2)
# ---------------------------------------------------------------------------
echo "== AC5: shipped docs/operator.md has exactly one canonical section =="
expect "AC5: marker appears exactly once" \
  "[ \"\$(grep -c -- '<!-- single-source: archive-gate -->' '$SKILL_DIR/docs/operator.md')\" -eq 1 ]"
expect "AC5: heading appears exactly once" \
  "[ \"\$(grep -c -- '^#### Archive gate (single source)' '$SKILL_DIR/docs/operator.md')\" -eq 1 ]"

# ---------------------------------------------------------------------------
# AC6 (R6e) — lint passes on the shipped docs/operator.md, fails on a
# fixture copy with one raw form re-added outside the section
# ---------------------------------------------------------------------------
echo "== AC6: lint clean on shipped docs/operator.md, red on a reintroduced raw form =="
"$LINT" "$SKILL_DIR/docs/operator.md" >/dev/null 2>&1
expect "AC6: lint exits 0 on the shipped docs/operator.md" "[ $? -eq 0 ]"

bad_raw="$T/skillmd-bad-raw.md"
python3 - "$SKILL_DIR/docs/operator.md" "$bad_raw" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    lines = f.readlines()
insert_at = 1200  # well past the canonical section (ends ~line 1155)
block = ["\n", "```\n",
         "scripts/gate-launch.sh <build_into> --head <landed sha> --scope main --slug <slug> --wait\n",
         "```\n"]
lines[insert_at:insert_at] = block
with open(dst, "w") as f:
    f.writelines(lines)
PY
out_bad_raw="$("$LINT" "$bad_raw" 2>&1)"; rc_bad_raw=$?
expect "AC6: lint exits non-zero on the fixture with a raw form re-added" "[ $rc_bad_raw -ne 0 ]"
expect "AC6: lint names the offending line" "grep -qE ':1203: raw main-gate form' <<<\"$out_bad_raw\""

# ---------------------------------------------------------------------------
# AC7 (R6f) — lint fails on a fixture block using a flag the script's usage
# does not list, naming the flag and the script
# ---------------------------------------------------------------------------
echo "== AC7: lint fails on an unknown flag, naming flag + script =="
bad_flag="$T/skillmd-bad-flag.md"
python3 - "$SKILL_DIR/docs/operator.md" "$bad_flag" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    lines = f.readlines()
insert_at = 1200
block = ["\n", "```\n",
         "scripts/gate-launch.sh <build_into> --no-such-flag\n",
         "```\n"]
lines[insert_at:insert_at] = block
with open(dst, "w") as f:
    f.writelines(lines)
PY
out_bad_flag="$("$LINT" "$bad_flag" 2>&1)"; rc_bad_flag=$?
expect "AC7: lint exits non-zero" "[ $rc_bad_flag -ne 0 ]"
expect "AC7: lint names the flag" "grep -q -- '--no-such-flag' <<<\"$out_bad_flag\""
expect "AC7: lint names the script" "grep -q 'gate-launch.sh' <<<\"$out_bad_flag\""
expect "AC7: run-selftests.sh lists this selftest" \
  "grep -q 'skill-single-source-selftest.sh' '$SKILL_DIR/scripts/run-selftests.sh'"

# ---------------------------------------------------------------------------
# AC8 (R5) — no prompt-shaped file under the build skill quotes the raw
# form outside its one designated home. docs/operator.md is excluded from
# this scan — it's the canonical section's home since
# PRD-build-branch-contract-split (the same exemption SKILL.md itself
# implicitly had before that PRD, by living outside templates/+docs/).
# ---------------------------------------------------------------------------
echo "== AC8: no prompt/doc/template file quotes the raw main-gate form =="
prompt_hits="$(grep -rlE 'gate-launch\.sh .*--scope main|extend-gate\.sh .*--head' \
  --exclude=operator.md "$SKILL_DIR/templates" "$SKILL_DIR/docs" 2>/dev/null || true)"
expect "AC8: templates/ and docs/ (excl. operator.md) are clean of the raw form" "[ -z \"$prompt_hits\" ]"

# ---------------------------------------------------------------------------
# AC10 (R7) — heading renamed but marker kept still allowlists the section;
# marker removed fails naming it
# ---------------------------------------------------------------------------
echo "== AC10: marker (not heading text) controls the allowlist =="
renamed="$T/skillmd-renamed.md"
sed 's/^#### Archive gate (single source)$/#### Archive gate (renamed)/' "$SKILL_DIR/docs/operator.md" > "$renamed"
"$LINT" "$renamed" >/dev/null 2>&1
expect "AC10: renamed heading with marker kept still lints clean" "[ $? -eq 0 ]"

no_marker="$T/skillmd-no-marker.md"
grep -v -- '<!-- single-source: archive-gate -->' "$SKILL_DIR/docs/operator.md" > "$no_marker"
out_no_marker="$("$LINT" "$no_marker" 2>&1)"; rc_no_marker=$?
expect "AC10: marker removed fails the whole lint" "[ $rc_no_marker -eq 3 ]"
expect "AC10: failure names the missing marker" "grep -q 'missing marker' <<<\"$out_no_marker\""

if [ "$fail" -eq 0 ]; then
  echo "skill-single-source-selftest: PASS"
else
  echo "skill-single-source-selftest: FAIL — see above" >&2
fi
exit "$fail"
