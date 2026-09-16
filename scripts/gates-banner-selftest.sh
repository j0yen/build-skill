#!/usr/bin/env bash
# gates-banner-selftest.sh — PRD-build-gate-red-alarm-invariant AC8-AC9
# (test_prefix: gatered).
#
#   AC8 — unreachable RedBaron (fake ssh always fails), no cache: prints
#     exactly `GATES: unknown (redbaron unreachable)`, exits 0, finishes
#     well under 6s.
#   AC9 — a fresh cache with red=5: the banner's first line is the
#     summary line, and the output includes `RED GATES PRESENT`.
#
# Plus two supporting cases (not separately numbered ACs, but the same
# mechanism AC8/AC9 depend on): a successful ssh fetch populates the
# cache, and a second call within the 10-minute TTL reuses that cache
# without invoking ssh again.
#
# Isolated: every case sets its own GATES_BANNER_CACHE/HOSTNAME/SSH_BIN
# under a disposable tempdir — never touches the real ~/.cache or a real
# ssh binary.
#
# Run: bash scripts/gates-banner-selftest.sh   (exit 0 = all pass)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GB="$HERE/gates-banner.sh"
[ -x "$GB" ] || { echo "selftest: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gates-banner-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label ($cond)" >&2; FAIL=$((FAIL+1)); fi
}

# ============================================================================
# AC8 — unreachable, no cache.
# ============================================================================
D="$T/ac8"; mkdir -p "$D/bin" "$D/cache"
cat > "$D/bin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 255
EOF
chmod +x "$D/bin/ssh"
start="$(date +%s)"
out8="$(GATES_BANNER_HOSTNAME=notredbaron GATES_BANNER_CACHE="$D/cache/gate-red.summary" \
  GATES_BANNER_SSH_BIN="$D/bin/ssh" "$GB")"
rc8=$?
elapsed=$(( $(date +%s) - start ))
expect "AC8 exit 0" "[ $rc8 -eq 0 ]"
expect "AC8 exact unreachable message" "[ \"\$out8\" = 'GATES: unknown (redbaron unreachable)' ]"
expect "AC8 finishes under 6s" "[ $elapsed -lt 6 ]"

# ============================================================================
# AC9 — fresh cache, red=5.
# ============================================================================
D="$T/ac9"; mkdir -p "$D/cache"
printf '2026-09-16T15:00:00Z GATES(3h): green=0 red=5 blockers: hermetic-build x9 oldest-red=2026-09-16T11:51:16Z red_slugs: a b c d e\n3\n' \
  > "$D/cache/gate-red.summary"
out9="$(GATES_BANNER_HOSTNAME=notredbaron GATES_BANNER_CACHE="$D/cache/gate-red.summary" "$GB")"
rc9=$?
first_line="$(printf '%s\n' "$out9" | sed -n '1p')"
expect "AC9 exit 0" "[ $rc9 -eq 0 ]"
expect "AC9 first line is the summary" "[[ \"\$first_line\" == GATES\\(3h\\):*red=5* ]]"
expect "AC9 output includes RED GATES PRESENT" "[[ \"\$out9\" == *'RED GATES PRESENT'* ]]"

# ============================================================================
# Supporting — ssh success populates the cache; a second call within the
# TTL reuses it without invoking ssh (breaking ssh proves no re-fetch).
# ============================================================================
D="$T/ssh-ok"; mkdir -p "$D/bin" "$D/cache"
cat > "$D/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "2026-09-16T15:00:00Z GATES(3h): green=2 red=1 blockers: hermetic-build x1 oldest-red=2026-09-16T10:00:00Z red_slugs: mcphost-x"
echo
echo "7"
EOF
chmod +x "$D/bin/ssh"
out_first="$(GATES_BANNER_HOSTNAME=notredbaron GATES_BANNER_CACHE="$D/cache/gate-red.summary" \
  GATES_BANNER_SSH_BIN="$D/bin/ssh" "$GB")"
expect "ssh-success red=1 line present" "[[ \"\$out_first\" == *'red=1'* ]]"
expect "ssh-success shipped count from remote" "[[ \"\$out_first\" == *'PRDs shipped last 24h: 7'* ]]"
expect "ssh-success populated the cache" "[ -s '$D/cache/gate-red.summary' ]"
rm -f "$D/bin/ssh"
out_second="$(GATES_BANNER_HOSTNAME=notredbaron GATES_BANNER_CACHE="$D/cache/gate-red.summary" \
  GATES_BANNER_SSH_BIN="$D/bin/ssh" "$GB")"
expect "cache reuse: same content without ssh" "[[ \"\$out_second\" == *'red=1'* && \"\$out_second\" == *'PRDs shipped last 24h: 7'* ]]"

# ============================================================================
# shipped-count.sh, directly — the local leg gates-banner.sh calls on
# RedBaron.
# ============================================================================
D="$T/shipped"; mkdir -p "$D/journal"
TODAY="$(date -u +%F)"
recent="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
old="$(date -u -d '-30 hours' +%Y-%m-%dT%H:%M:%SZ)"
printf '%s  slugA  archive  archived  (repo=fixture)\n' "$recent" > "$D/journal/${TODAY}.md"
printf '%s  slugB  archive  archived  (repo=fixture)\n' "$old" >> "$D/journal/${TODAY}.md"
n="$(BUILD_JOURNAL_ROOT="$D/journal" "$HERE/shipped-count.sh")"
expect "shipped-count counts only the in-window archive" "[ \"\$n\" = 1 ]"

# ============================================================================
# AC11 — handoff-header.sh prints the current summary line; SKILL.md's
# Handoff section names it.
# ============================================================================
HH="$HERE/handoff-header.sh"
if [ -x "$HH" ]; then
  D="$T/ac11"; mkdir -p "$D/state"
  printf '2026-09-16T15:00:00Z GATES(3h): green=1 red=2 blockers: x x1 oldest-red=2026-09-16T10:00:00Z red_slugs: a b\n' \
    > "$D/state/gate-red.summary"
  out11="$(BUILD_STATE_DIR="$D/state" "$HH")"
  expect "AC11 prints the summary line without the write-ts" \
    "[ \"\$out11\" = 'GATES(3h): green=1 red=2 blockers: x x1 oldest-red=2026-09-16T10:00:00Z red_slugs: a b' ]"
  out11_empty="$(BUILD_STATE_DIR="$T/ac11-nofile" "$HH")"
  rc11_empty=$?
  expect "AC11 exit 0 with no summary file yet" "[ $rc11_empty -eq 0 ]"
  expect "AC11 prints nothing with no summary file yet" "[ -z \"\$out11_empty\" ]"
else
  echo "FAIL AC11: handoff-header.sh not found at $HH" >&2
  FAIL=$((FAIL + 1))
fi
SKILL_MD="$(cd "$HERE/.." && pwd)/SKILL.md"
expect "AC11 SKILL.md names handoff-header.sh in a Handoff section" \
  "grep -q '^## Handoff' '$SKILL_MD' && grep -q 'handoff-header.sh' '$SKILL_MD'"

echo "gates-banner-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
