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

if [ "$fails" -ne 0 ]; then echo "SELFTEST FAILED ($fails)"; exit 1; fi
echo "SELFTEST PASSED"
