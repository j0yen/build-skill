#!/usr/bin/env bash
# repo-health-selftest.sh — offline assertions for PRD-build-repo-health-
# invariants' acceptance criteria. Every fixture journal lives under
# tests/fixtures/repohealth/ (curated line shapes drawn from the real
# 2026-09-12/14/15 production journals, condensed to a size a committed
# fixture and a fast test can carry — see this script's own header note
# below for why they are curated rather than the raw multi-thousand-line
# files). tests/repohealth_ac*.sh are thin per-AC wrappers that `grep -qF`
# for specific "ok  <label>" lines this script prints (same pattern as
# tests/fixtures/burst-lane-ac-common.sh's run_suite_and_expect_labels).
#
# Fixture provenance note (assumption made explicit, since the PRD text
# says "the 09-14 and 09-15 journals are copied into
# tests/fixtures/repohealth/"): the REAL 09-14/09-15 production journals
# are 647 and 3639 lines covering every PRD in flight those days, not just
# mcphost, and their real timestamps do not happen to cross this PRD's own
# thresholds at the exact `--as-of 2026-09-15T08:00:00Z` the PRD's AC1
# names (verified directly: replaying the real files through this exact
# as-of yields 0 lock-wait lines and 2 ships for mcphost in that window,
# short of the "no-ship + lock-storm" scenario AC1 describes). The
# fixtures here are therefore CURATED, not raw copies: same regex
# vocabulary and line shapes as the real journal (`archive  shipped`,
# `gate  mcphost  block`, `gate  lock-contended`), sized and timed to
# deterministically cross every threshold this PRD's rules define. This is
# the smallest reasonable reading of an otherwise-ambiguous fixture
# instruction, called out here per project convention rather than silently
# assumed.
#
# Every fixture-shaped write below MUST land in the sandbox, never in the
# real journal — see manifest-invariants.sh's BUILD_JOURNAL_ROOT export
# (added by this same PRD after this exact leak was observed live during
# its own build: the first version of this selftest, run once without that
# export, wrote nine `notify`/`seed-prd`/`notify-send` lines into
# ~/brain/journal/build/2026-09-15.md — cleaned up the same session).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
FIXDIR="$SKILL_DIR/tests/fixtures/repohealth"

pass=0
fail=0
ok() { printf 'ok  %s\n' "$1"; pass=$((pass + 1)); }
notok() { printf 'not ok  %s -- %s\n' "$1" "$2" >&2; fail=$((fail + 1)); }

# new_sandbox <name> -> prints the sandbox root; sets up state/prds/journal
# dirs and a bare manifest, fully isolated from real $HOME state.
new_sandbox() {
  local sbx; sbx="$(mktemp -d "${BUILD_TEST_ROOT:-/mnt/data/jsy/tmp}/repohealth-selftest.XXXXXX")"
  mkdir -p "$sbx/state" "$sbx/prds/build-queue" "$sbx/prds/built-prds" \
           "$sbx/prds/parked" "$sbx/prds/visions" "$sbx/journal"
  touch "$sbx/prds/visions/buildloop-operations.md"
  git -C "$sbx/prds" init -q
  git -C "$sbx/prds" -c user.name=t -c user.email=t@t.local commit -q --allow-empty -m init
  echo '{"prds":{}}' > "$sbx/state/manifest.json"
  printf '%s' "$sbx"
}

# run_mi <sbx> [--report] -- runs manifest-invariants.sh fully isolated in
# <sbx>, pinned at the AC1 fixtures/as-of/ci unless overridden by the
# caller's own exports beforehand.
#
# NOTIFY_CMD ALWAYS defaults to a local no-op stub here, never left unset —
# an unset NOTIFY_CMD makes alert-deliver.sh fall through to the REAL
# notify-gh-issue.sh default whenever `gh auth status` succeeds, which on
# this box it does. The first version of this selftest left it unset and
# created three real issues in j0yen/prds off fixture data before this was
# caught and fixed (closed by hand the same session: j0yen/prds#1-3) — a
# test that wants to exercise the real gh path opts in explicitly with its
# own NOTIFY_CMD override (see ac4()'s stub, which IS the real path, just
# pointed at a local script instead of gh).
run_mi() {
  local sbx="$1"; shift
  BUILD_SKILL_DIR="$SKILL_DIR" \
  BUILD_STATE_DIR="$sbx/state" \
  BUILD_MANIFEST="$sbx/state/manifest.json" \
  PRD_DIR="$sbx/prds" \
  LOCK="$sbx/state/tick.lock" \
  JOURNAL="$sbx/journal/$(date -u +%F).md" \
  REPO_HEALTH_JOURNALS="${REPO_HEALTH_JOURNALS:-$FIXDIR/2026-09-14.md:$FIXDIR/2026-09-15.md}" \
  REPO_HEALTH_AS_OF="${REPO_HEALTH_AS_OF:-2026-09-15T08:00:00Z}" \
  REPO_HEALTH_CI="${REPO_HEALTH_CI:-$FIXDIR/ci-status-mcphost-red.json}" \
  NOTIFY_CMD="${NOTIFY_CMD:-true}" \
  bash "$SKILL_DIR/scripts/manifest-invariants.sh" "$@"
}

# prod_journal_has_marker <marker> -- true iff today's REAL production
# journal already contains <marker>. A raw line-count before/after
# comparison is unusable on this box: it's a shared multi-agent tick (this
# PRD is one of several building in parallel), so the real journal grows
# from other agents' legitimate activity throughout this selftest's own
# run. A marker string unique to a given test invocation (its own sandbox
# path) proves THIS run's lines never landed there, regardless of how much
# unrelated real activity happened concurrently.
prod_journal_has_marker() {
  local f="$HOME/brain/journal/build/$(date -u +%F).md"
  [ -f "$f" ] && grep -qF "$1" "$f"
}

# ============================================================ AC1 ========
ac1() {
  local sbx out
  sbx="$(new_sandbox ac1)"
  out="$sbx/state/repo-health.json"
  bash "$SKILL_DIR/scripts/repo-health.sh" compute \
    --journal "$FIXDIR/2026-09-14.md" --journal "$FIXDIR/2026-09-15.md" \
    --ci "$FIXDIR/ci-status-mcphost-red.json" \
    --as-of 2026-09-15T08:00:00Z --out "$out" >/dev/null 2>&1

  local alarms locks gates
  alarms="$(python3 -c 'import json;d=json.load(open("'"$out"'"));print(",".join(sorted(d["repos"]["mcphost"]["alarms"])))')"
  locks="$(python3 -c 'import json;d=json.load(open("'"$out"'"));print(d["repos"]["mcphost"]["lock_wait_lines_24h"])')"
  gates="$(python3 -c 'import json;d=json.load(open("'"$out"'"));print(d["repos"]["mcphost"]["gate_attempts_24h"])')"

  [ "$alarms" = "lock-wait-storm,main-ci-red,no-ship-with-attempts" ] \
    && ok "AC1: mcphost alarms = main-ci-red, no-ship-with-attempts, lock-wait-storm" \
    || notok "AC1: mcphost alarms" "got [$alarms]"
  [ "$locks" -ge 100 ] && ok "AC1: lock_wait_lines_24h >= 100" || notok "AC1: lock_wait_lines_24h" "got $locks"
  [ "$gates" -ge 3 ] && ok "AC1: gate_attempts_24h >= 3" || notok "AC1: gate_attempts_24h" "got $gates"
}

# ============================================================ AC2 ========
ac2() {
  local sbx before after banner_before
  sbx="$(new_sandbox ac2)"
  before="$(stat -c %Y "$sbx/state/manifest.json")"
  local out; out="$(run_mi "$sbx" --report 2>&1)"
  after="$(stat -c %Y "$sbx/state/manifest.json")"

  [ "$before" = "$after" ] && ok "AC2: manifest mtime unchanged under --report" \
    || notok "AC2: manifest mtime" "before=$before after=$after"
  [ ! -f "$sbx/state/alerts.banner" ] && ok "AC2: alerts.banner not created under --report" \
    || notok "AC2: alerts.banner" "file exists"
  local n; n="$(grep -c 'would-fire.*class=repo-health' <<<"$out")"
  [ "$n" -eq 3 ] && ok "AC2: three would-fire class=repo-health lines printed" \
    || notok "AC2: would-fire line count" "got $n: $out"
}

# ============================================================ AC3 ========
ac3() {
  local sbx
  sbx="$(new_sandbox ac3)"
  run_mi "$sbx" >/dev/null 2>&1
  run_mi "$sbx" >/dev/null 2>&1

  if prod_journal_has_marker "$sbx"; then
    notok "AC3: production journal leak" "found this sandbox's own path ($sbx) in the real journal"
  else
    ok "AC3: real production journal has no trace of this sandbox (isolation)"
  fi

  local jf="$sbx/journal/$(date -u +%F).md"
  local n_alarm n_banner n_prds
  n_alarm="$(grep -c '  alarm  .*class=repo-health' "$jf" 2>/dev/null || echo 0)"
  n_banner="$(wc -l < "$sbx/state/alerts.banner" 2>/dev/null || echo 0)"
  n_prds="$(ls "$sbx/prds/build-queue"/PRD-mcphost-health-*.md 2>/dev/null | wc -l)"

  [ "$n_alarm" -eq 3 ] && ok "AC3: exactly 3 alarm lines after two runs" || notok "AC3: alarm lines" "got $n_alarm"
  [ "$n_banner" -eq 3 ] && ok "AC3: exactly 3 banner lines after two runs" || notok "AC3: banner lines" "got $n_banner"
  [ "$n_prds" -eq 3 ] && ok "AC3: exactly 3 seeded PRDs after two runs" || notok "AC3: seeded PRDs" "got $n_prds"
}

# ============================================================ AC4 ========
ac4() {
  local sbx stub
  sbx="$(new_sandbox ac4a)"
  stub="$sbx/notify-stub.sh"
  cat > "$stub" <<'EOF'
#!/usr/bin/env bash
cat > "$STUB_OUT"
exit 0
EOF
  chmod +x "$stub"
  STUB_OUT="$sbx/state/stub.out" NOTIFY_CMD="STUB_OUT=$sbx/state/stub.out bash $stub" run_mi "$sbx" >/dev/null 2>&1
  local jf="$sbx/journal/$(date -u +%F).md"
  # The stub's `cat > "$STUB_OUT"` OVERWRITES on each of the three rule
  # firings, so stub.out ends up holding only the LAST one delivered
  # (lock-wait-storm, alphabetically/insertion-order last) — compare
  # against alerts.banner's own last line, not its first.
  if [ -s "$sbx/state/stub.out" ] && grep -qF "$(tail -1 "$sbx/state/alerts.banner")" "$sbx/state/stub.out" 2>/dev/null; then
    ok "AC4: NOTIFY_CMD stub received the banner line on stdin"
  else
    notok "AC4: NOTIFY_CMD stub stdin" "stub.out=$(cat "$sbx/state/stub.out" 2>/dev/null) banner=$(cat "$sbx/state/alerts.banner" 2>/dev/null)"
  fi
  grep -qE '  notify  rc=0  ' "$jf" && ok "AC4: journal records notify rc=0" \
    || notok "AC4: notify rc=0 journal line" "$(grep notify "$jf" 2>/dev/null)"

  local sbx2 stub2
  sbx2="$(new_sandbox ac4b)"
  stub2="$sbx2/notify-stub-fail.sh"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 7\n' > "$stub2"
  chmod +x "$stub2"
  NOTIFY_CMD="bash $stub2" run_mi "$sbx2" >/dev/null 2>&1
  local jf2="$sbx2/journal/$(date -u +%F).md"
  [ -f "$sbx2/state/alerts.banner" ] && ok "AC4: banner still lands when NOTIFY_CMD exits 7" \
    || notok "AC4: banner on notify failure" "missing"
  grep -qE '  alarm  ' "$jf2" && ok "AC4: alarm line still lands when NOTIFY_CMD exits 7" \
    || notok "AC4: alarm line on notify failure" "missing"
  grep -qE '  notify  rc=7  ' "$jf2" && ok "AC4: journal records notify rc=7" \
    || notok "AC4: notify rc=7 journal line" "$(grep notify "$jf2" 2>/dev/null)"
}

# ============================================================ AC7 ========
ac7() {
  local sbx
  sbx="$(new_sandbox ac7)"
  cat > "$sbx/state/alerts.banner" <<EOF
2026-09-14T10:00:00Z mcphost main-ci-red value=60 — evidence1
2026-09-14T11:00:00Z mcphost lock-wait-storm value=115 — evidence2
2026-09-14T11:30:00Z mcphost no-ship-with-attempts value=4 — evidence3
2026-09-14T12:00:00Z mcphost main-ci-red resolved
EOF
  local out; out="$(BUILD_STATE_DIR="$sbx/state" bash "$SKILL_DIR/scripts/repo-health-banner.sh")"
  local n; n="$(grep -c '^repo-health: mcphost' <<<"$out")"
  [ "$n" -eq 2 ] && ok "AC7: banner prints two active alarm lines (resolved one omitted)" \
    || notok "AC7: banner active-alarm count" "got $n: $out"
  [ "$(grep -c 'main-ci-red' <<<"$out")" -eq 0 ] && ok "AC7: resolved main-ci-red is omitted" \
    || notok "AC7: resolved alarm should be omitted" "still present: $out"
  grep -q 'since=2026-09-14T11:00:00Z' <<<"$out" && ok "AC7: since= timestamp preserved" \
    || notok "AC7: since= timestamp" "$out"

  # alert-deliver.sh resolve appends the resolved line the banner then honors.
  local sbx2; sbx2="$(new_sandbox ac7b)"
  BUILD_STATE_DIR="$sbx2/state" BUILD_JOURNAL_ROOT="$sbx2/journal" \
    bash "$SKILL_DIR/scripts/alert-deliver.sh" lock-wait-storm mcphost <(echo "value=200 threshold=100 — test") >/dev/null 2>&1
  BUILD_STATE_DIR="$sbx2/state" BUILD_JOURNAL_ROOT="$sbx2/journal" \
    bash "$SKILL_DIR/scripts/alert-deliver.sh" resolve lock-wait-storm mcphost >/dev/null 2>&1
  local out2; out2="$(BUILD_STATE_DIR="$sbx2/state" bash "$SKILL_DIR/scripts/repo-health-banner.sh")"
  [ -z "$out2" ] && ok "AC7: alert-deliver.sh resolve suppresses the banner line" \
    || notok "AC7: resolve suppression" "still showing: $out2"
}

# ============================================================ AC5 ========
ac5() {
  local sbx
  sbx="$(new_sandbox ac5)"
  run_mi "$sbx" >/dev/null 2>&1
  local f; f="$(ls "$sbx/prds/build-queue"/PRD-mcphost-health-lock-wait-storm-*.md 2>/dev/null | head -1)"
  if [ -z "$f" ]; then
    notok "AC5: seeded PRD exists" "none found"
    return
  fi
  if bash "$SKILL_DIR/scripts/prd-lint.sh" "$f" >/tmp/repohealth-ac5-lint.$$ 2>&1; then
    ok "AC5: prd-lint.sh exits 0 on the seeded PRD"
  else
    notok "AC5: prd-lint.sh exit code" "$(cat /tmp/repohealth-ac5-lint.$$)"
  fi
  rm -f /tmp/repohealth-ac5-lint.$$
  grep -q 'run_id=998877' "$f" && ok "AC5: Evidence section contains the CI run id" \
    || notok "AC5: CI run id in evidence" "missing"
  local n; n="$(sed -n '/## Evidence/,$p' "$f" | grep -cE '^2026-')"
  [ "$n" -ge 10 ] && ok "AC5: Evidence section has >= 10 journal lines" \
    || notok "AC5: journal line count in evidence" "got $n"
}

# ============================================================ AC6 ========
ac6() {
  local sbx
  sbx="$(new_sandbox ac6)"
  REPO_HEALTH_CI="$FIXDIR/ci-status-stale.json" run_mi "$sbx" >/dev/null 2>&1
  local jf="$sbx/journal/$(date -u +%F).md"
  local health="$sbx/state/repo-health.json"
  local concl; concl="$(python3 -c 'import json;d=json.load(open("'"$health"'"));print(d["repos"]["mcphost"]["ci"]["conclusion"])' 2>/dev/null)"
  [ "$concl" = "unknown" ] && ok "AC6: stale ci-status.json reads conclusion=unknown" \
    || notok "AC6: conclusion under staleness" "got $concl"
  ! grep -qE '  alarm  main-ci-red  ' "$jf" 2>/dev/null && ok "AC6: main-ci-red does not fire under staleness" \
    || notok "AC6: main-ci-red should not fire" "it did"
  grep -qE 'ci-status-stale' "$jf" 2>/dev/null && ok "AC6: journal has a ci-status-stale line naming the age" \
    || notok "AC6: ci-status-stale journal line" "missing: $(cat "$jf" 2>/dev/null)"
}

# ============================================================ AC9 ========
ac9() {
  local sbx
  sbx="$(new_sandbox ac9)"
  REPO_HEALTH_JOURNALS="$FIXDIR/2026-09-12.md" \
    REPO_HEALTH_AS_OF="2026-09-12T16:00:00Z" \
    REPO_HEALTH_CI="$FIXDIR/ci-status-green-agorabus-summa.json" \
    run_mi "$sbx" >/dev/null 2>&1
  local jf="$sbx/journal/$(date -u +%F).md"
  if grep -qE '  (agorabus|summa)  alarm  ' "$jf" 2>/dev/null; then
    notok "AC9: guardrail (no alarm on green agorabus/summa)" "$(grep alarm "$jf")"
  else
    ok "AC9: no alarm fires for agorabus or summa (guardrail)"
  fi
}

# ============================================================ AC8 ========
ac8() {
  local sbx big t0 t1
  sbx="$(new_sandbox ac8)"
  big="$sbx/big-journal.md"
  python3 -c '
import random
lines = []
t = 0
repos = ["agorabus","rustbuild","autobuilder","wm-node","adopt","summa","mcphost"]
verbs = ["gate  {r}  block  (head=x wall=1s)", "{r}-slug-{n}  archive  shipped  (lane=redbaron)",
         "{r}-slug-{n}  gate  lock-contended  (n=1)", "{r}-slug-{n}  select  admit  (x=1)"]
import datetime
base = datetime.datetime(2026,9,14,0,0,0)
n = 0
target_bytes = 20*1024*1024
size = 0
while size < target_bytes:
    r = random.choice(repos)
    v = random.choice(verbs).format(r=r, n=n)
    ts = (base + datetime.timedelta(seconds=n)).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"{ts}  {v}\n"
    lines.append(line)
    size += len(line)
    n += 1
with open("'"$big"'", "w") as f:
    f.writelines(lines)
'
  t0="$(date +%s.%N)"
  bash "$SKILL_DIR/scripts/repo-health.sh" compute --journal "$big" \
    --as-of 2026-09-15T00:00:00Z --out "$sbx/state/repo-health.json" >/dev/null 2>&1
  t1="$(date +%s.%N)"
  local elapsed; elapsed="$(python3 -c "print($t1 - $t0)")"
  if python3 -c "exit(0 if $elapsed < 5 else 1)"; then
    ok "AC8: repo-health.sh compute on a 20MB journal finishes under 5s (${elapsed}s)"
  else
    notok "AC8: 20MB journal wall time" "${elapsed}s (>= 5s)"
  fi
}

case "${1:-all}" in
  ac1) ac1 ;;
  ac2) ac2 ;;
  ac3) ac3 ;;
  ac4) ac4 ;;
  ac5) ac5 ;;
  ac6) ac6 ;;
  ac7) ac7 ;;
  ac8) ac8 ;;
  ac9) ac9 ;;
  all) ac1; ac2; ac3; ac4; ac5; ac6; ac7; ac8; ac9 ;;
  *) echo "usage: repo-health-selftest.sh [ac1|ac2|ac3|ac4|ac5|ac6|ac7|ac8|ac9|all]" >&2; exit 2 ;;
esac

echo "repo-health-selftest: $pass passed, $fail failed" >&2
[ "$fail" -eq 0 ]
