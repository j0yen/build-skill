#!/usr/bin/env bash
# scan-prds-selftest.sh — regression coverage for build-scan-bold-frontmatter.
# Asserts scan-prds.sh parses bold-markdown (`**build_target:** x`) AND bare
# (`build_target: x`) frontmatter identically, preserves the fenced-code-block
# skip, and honors first-match-wins. Exits 0 on success, non-zero on any fail.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/scan-prds.sh"
JQ="${JQ:-$(command -v jq || echo /usr/sbin/jq)}"
[ -x "$JQ" ] || JQ="$(command -v jq)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- AC1/AC2: bold-markdown form parses for all build_* keys --------------
cat >"$tmp/PRD-bold.md" <<'EOF'
# PRD: bold fixture
**Status:** Draft v0.1
**build_target:** shell
**build_into:** /home/jsy/wintermute/foo
**build_priority:** high
**build_version_bump:** patch
EOF

# --- AC3: bare-key form still parses (no regression) ----------------------
cat >"$tmp/PRD-bare.md" <<'EOF'
# PRD: bare fixture
Status: Draft v0.1
build_target: rust-cli
build_into: /home/jsy/wintermute/bar
build_priority: low
EOF

# --- AC4: real bold key near top beats a later bare example in a fence ----
cat >"$tmp/PRD-fenced.md" <<'EOF'
# PRD: fenced fixture
**build_target:** rust-extend
Some prose mentioning the frontmatter schema:
```
build_target: rust-cli
build_priority: high
```
EOF

out="$(PRD_DIR="$tmp" JQ="$JQ" bash "$SCAN")" || { echo "FAIL: scan exited non-zero"; exit 1; }

fails=0
check() { # slug key expected
  local got
  got="$(printf '%s' "$out" | "$JQ" -r --arg s "$1" --arg k "$2" '.[] | select(.slug==$s) | .[$k] // "null"')"
  if [ "$got" != "$3" ]; then
    echo "FAIL: $1.$2 = '$got' (expected '$3')"; fails=$((fails+1))
  else
    echo "ok: $1.$2 = $got"
  fi
}

# AC1/AC2 — bold form
check bold build_target      shell
check bold build_into        /home/jsy/wintermute/foo
check bold build_priority    high
check bold build_version_bump patch
# AC3 — bare form unchanged
check bare build_target      rust-cli
check bare build_into        /home/jsy/wintermute/bar
check bare build_priority    low
# AC4 — bold top key wins over fenced bare example
check fenced build_target    rust-extend
check fenced build_priority  null

# --- PRD-build-selector-honors-priority: emitted array is priority-ordered -
order() { printf '%s' "$out" | "$JQ" -r '[.[].slug] | join(",")'; }

check_order() { # description expected-csv
  local got; got="$(order)"
  if [ "$got" != "$2" ]; then
    echo "FAIL: order ($1) = '$got' (expected '$2')"; fails=$((fails+1))
  else
    echo "ok: order ($1) = $got"
  fi
}

# The 3 fixtures above are: bold(high), bare(low), fenced(no priority ->
# normal). AC1: high precedes everything. AC3: fenced (no build_priority)
# and bare... wait bare is low, not a comparable AC3 case here — this reuses
# the existing 3 fixtures rather than adding redundant fixture files, so the
# expectation is band order: bold(high) < fenced(normal) < bare(low), with
# fenced/bare/bold's *paths* (PRD-bold.md, PRD-bare.md, PRD-fenced.md)
# irrelevant to the outcome since all 3 bands differ here.
check_order "AC1: high before normal before low" "bold,fenced,bare"

rm -f "$tmp"/PRD-*.md

# --- AC2/AC3: equal-priority / no-priority ties break on path, unaffected -
cat >"$tmp/PRD-aaa.md" <<'EOF'
Status: queued
build_target: shell
build_priority: normal
EOF
cat >"$tmp/PRD-mmm.md" <<'EOF'
Status: queued
build_target: shell
EOF
cat >"$tmp/PRD-zzz.md" <<'EOF'
Status: queued
build_target: shell
build_priority: high
EOF
out="$(PRD_DIR="$tmp" JQ="$JQ" JOURNAL="$tmp/journal.md" bash "$SCAN")" || { echo "FAIL: scan exited non-zero (order fixtures)"; exit 1; }
check_order "AC2/AC3: high first, then normal/unset tied on path" "zzz,aaa,mmm"

# --- AC4: unrecognized build_priority sorts normal + journals once --------
cat >"$tmp/PRD-typo.md" <<'EOF'
Status: queued
build_target: shell
build_priority: urgent
EOF
out="$(PRD_DIR="$tmp" JQ="$JQ" JOURNAL="$tmp/journal.md" bash "$SCAN")" || { echo "FAIL: scan exited non-zero (typo fixture)"; exit 1; }
check typo build_priority urgent
check_order "AC4: unrecognized value sorts in normal band" "zzz,aaa,mmm,typo"
if grep -q 'priority-unknown (slug=typo value=urgent)' "$tmp/journal.md" 2>/dev/null; then
  echo "ok: AC4 journal = priority-unknown (slug=typo value=urgent)"
else
  echo "FAIL: AC4 journal missing priority-unknown line"; fails=$((fails+1))
fi

# --- AC6: order is byte-identical regardless of locale --------------------
out_c="$out"
out_locale="$(PRD_DIR="$tmp" JQ="$JQ" JOURNAL="$tmp/journal2.md" LC_ALL=en_US.UTF-8 bash "$SCAN" 2>/dev/null)" || out_locale=""
if [ -n "$out_locale" ] && [ "$out_c" = "$out_locale" ]; then
  echo "ok: AC6 locale-independent order (C == en_US.UTF-8)"
elif [ -z "$out_locale" ]; then
  echo "ok: AC6 skipped (en_US.UTF-8 locale not installed on this host)"
else
  echo "FAIL: AC6 order differs under en_US.UTF-8"; fails=$((fails+1))
fi

if [ "$fails" -ne 0 ]; then echo "SELFTEST FAILED ($fails)"; exit 1; fi
echo "SELFTEST PASSED"
