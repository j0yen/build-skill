#!/usr/bin/env bash
# prd-lint-selftest.sh — regression coverage for prd-lint.sh (PRD-build-prd-lint).
# One fixture pair (failing + passing) per check id, plus the three real
# 2026-09-03/04 defects that motivated this tool, reproduced as fixtures.
# Exits 0 on success, non-zero (with a FAIL line per miss) otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$HERE/prd-lint.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/build-queue" "$tmp/built-prds" "$tmp/visions"
q="$tmp/build-queue"
b="$tmp/built-prds"
v="$tmp/visions"

echo "plain vision, no loop contract." > "$v/plain.md"
cat > "$v/loopy.md" <<'EOF'
# Vision: loopy

## Loop
This vision declares a standing loop contract.
EOF

fails=0
total=0

json_of() { "$LINT" --format json "$1" 2>/dev/null; }

has_id() { # $1=json $2=field(failures|warnings) $3=id
  printf '%s' "$1" | python3 -c "
import json, sys
d = json.load(sys.stdin)[0]
ids = [x['id'] for x in d.get('$2', [])]
sys.exit(0 if '$3' in ids else 1)
"
}

expect_fail() { # $1=path $2=id $3=label
  total=$((total+1))
  local out; out="$(json_of "$1")"
  if has_id "$out" failures "$2"; then
    echo "ok: $3 -> FAIL $2"
  else
    echo "FAIL: $3 expected failure id $2, got: $out"
    fails=$((fails+1))
  fi
}

expect_warn() { # $1=path $2=id $3=label
  total=$((total+1))
  local out; out="$(json_of "$1")"
  if has_id "$out" warnings "$2"; then
    echo "ok: $3 -> WARN $2"
  else
    echo "FAIL: $3 expected warning id $2, got: $out"
    fails=$((fails+1))
  fi
}

expect_ok() { # $1=path $2=label
  total=$((total+1))
  "$LINT" "$1" >/tmp/prd-lint-selftest.out 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ] && grep -q '^OK$' /tmp/prd-lint-selftest.out; then
    echo "ok: $2 -> OK"
  else
    echo "FAIL: $2 expected OK/exit0, got exit=$rc: $(cat /tmp/prd-lint-selftest.out)"
    fails=$((fails+1))
  fi
}

expect_clean_no_id() { # $1=path $2=field $3=id $4=label -- id must be ABSENT
  total=$((total+1))
  local out; out="$(json_of "$1")"
  if has_id "$out" "$2" "$3"; then
    echo "FAIL: $4 unexpectedly has $2 id $3: $out"
    fails=$((fails+1))
  else
    echo "ok: $4 -> no $3"
  fi
}

# ============================================================ status-missing
cat > "$q/PRD-status-missing.md" <<'EOF'
build_target: shell
Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-status-missing.md" status-missing "status-missing/fail"

cat > "$q/PRD-status-ok.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_clean_no_id "$q/PRD-status-ok.md" failures status-missing "status-missing/pass"

# ====================================================== build-target-missing
cat > "$q/PRD-target-missing.md" <<'EOF'
- Status: queued
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-target-missing.md" build-target-missing "build-target-missing/fail"
expect_clean_no_id "$q/PRD-status-ok.md" failures build-target-missing "build-target-missing/pass"

# ====================================================== build-target-unknown
cat > "$q/PRD-target-unknown.md" <<'EOF'
- Status: queued
- build_target: cobol-cli
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-target-unknown.md" build-target-unknown "build-target-unknown/fail"
expect_clean_no_id "$q/PRD-status-ok.md" failures build-target-unknown "build-target-unknown/pass"

# ============================================================ vision-missing
cat > "$q/PRD-vision-missing.md" <<'EOF'
- Status: queued
- build_target: shell

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-vision-missing.md" vision-missing "vision-missing/fail"
expect_clean_no_id "$q/PRD-status-ok.md" failures vision-missing "vision-missing/pass"

# ========================================================== vision-not-found
cat > "$q/PRD-vision-not-found.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/does-not-exist.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-vision-not-found.md" vision-not-found "vision-not-found/fail"
expect_clean_no_id "$q/PRD-status-ok.md" failures vision-not-found "vision-not-found/pass"

# ========================================================= build-into-missing
cat > "$q/PRD-into-missing.md" <<'EOF'
- Status: queued
- build_target: rust-extend
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-into-missing.md" build-into-missing "build-into-missing/fail"

cat > "$q/PRD-into-ok.md" <<'EOF'
- Status: queued
- build_target: rust-extend
- build_into: /tmp
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_clean_no_id "$q/PRD-into-ok.md" failures build-into-missing "build-into-missing/pass"

# ======================================================= build-into-not-found
cat > "$q/PRD-into-not-found.md" <<'EOF'
- Status: queued
- build_target: shell
- build_into: /no/such/dir/anywhere
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_warn "$q/PRD-into-not-found.md" build-into-not-found "build-into-not-found/warn"
expect_clean_no_id "$q/PRD-into-ok.md" warnings build-into-not-found "build-into-not-found/pass"

# =========================================================== deferred-acs-prose
# Real defect (2026-09-03): PRD-mcphost-code-tools.md carried this exact line.
cat > "$q/PRD-deferred-prose.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- deferred_acs: P1 items 15 (warm pool, <50ms p50 overhead on repeat
  calls) and 16 (host.tool_run debug RPC that skips the calls row) are
  not implemented -- no P0 acceptance criterion depends on them.

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-deferred-prose.md" deferred-acs-prose "deferred-acs-prose/fail (real defect: mcphost-code-tools)"

cat > "$q/PRD-deferred-list.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- deferred_acs: [15, 16]
- mock_justifications: AC15 is a P1 perf target with no warm pool shipped; AC16 is a deferred debug RPC.

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_clean_no_id "$q/PRD-deferred-list.md" failures deferred-acs-prose "deferred-acs-prose/pass"

# ============================================ deferred-acs-missing-justification
cat > "$q/PRD-deferred-nojust.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- deferred_acs: [3, 4]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-deferred-nojust.md" deferred-acs-missing-justification "deferred-acs-missing-justification/fail"
expect_clean_no_id "$q/PRD-deferred-list.md" failures deferred-acs-missing-justification "deferred-acs-missing-justification/pass"

# ================================================================ depends-on-missing
cat > "$q/PRD-dep-missing.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Depends-on: PRD-nonexistent.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-dep-missing.md" depends-on-missing "depends-on-missing/fail"

cat > "$q/PRD-dep-target.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a target PRD, When linted, Then it is clean.
EOF
cat > "$q/PRD-dep-ok.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Depends-on: PRD-dep-target.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_clean_no_id "$q/PRD-dep-ok.md" failures depends-on-missing "depends-on-missing/pass"

# ================================================================== depends-on-cycle
# Real incident shape (2026-09-04): PRD-mcphost-harness-live-names briefly
# declared Depends-on: PRD-mcphost-measure-comparable.md while
# measure-comparable's own remaining ACs needed the probe harness-live-names
# unblocks -- an operator dropped the edge by hand before a cycle deadlocked
# on it. Reproduced here as a literal two-PRD cycle so the mechanical check
# catches the shape without requiring a human to notice.
cat > "$q/PRD-mcphost-harness-live-names.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Depends-on: PRD-mcphost-measure-comparable.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
cat > "$q/PRD-mcphost-measure-comparable.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Depends-on: PRD-mcphost-harness-live-names.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-mcphost-harness-live-names.md" depends-on-cycle "depends-on-cycle/fail (real-shape: harness-live-names<->measure-comparable)"
expect_fail "$q/PRD-mcphost-measure-comparable.md" depends-on-cycle "depends-on-cycle/fail (other side of the cycle)"
expect_clean_no_id "$q/PRD-dep-ok.md" failures depends-on-cycle "depends-on-cycle/pass"

# ==================================================== depends-on-possible-deadlock
cat > "$q/PRD-deadlock-target.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md

## Problem statement

This text mentions PRD-deadlock-source.md by name, which should warn its
dependent about a possible deadlock even without a literal Depends-on cycle.

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
cat > "$q/PRD-deadlock-source.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Depends-on: PRD-deadlock-target.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_warn "$q/PRD-deadlock-source.md" depends-on-possible-deadlock "depends-on-possible-deadlock/warn"
expect_clean_no_id "$q/PRD-dep-ok.md" warnings depends-on-possible-deadlock "depends-on-possible-deadlock/pass"

# ================================================================== loop-missing
cat > "$q/PRD-loop-missing.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/loopy.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-loop-missing.md" loop-missing "loop-missing/fail"

cat > "$q/PRD-loop-ok.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/loopy.md
- Loop: some-loop: some-metric

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_clean_no_id "$q/PRD-loop-ok.md" failures loop-missing "loop-missing/pass"

# ==================================================================== slug-invalid
cat > "$q/PRD-Bad_Slug.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-Bad_Slug.md" slug-invalid "slug-invalid/fail"
expect_clean_no_id "$q/PRD-status-ok.md" failures slug-invalid "slug-invalid/pass"

# ============================================================= ac-section-missing
cat > "$q/PRD-ac-section-missing.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md

## Not the right heading

Nothing acceptance-shaped here.
EOF
expect_fail "$q/PRD-ac-section-missing.md" ac-section-missing "ac-section-missing/fail"
expect_clean_no_id "$q/PRD-status-ok.md" failures ac-section-missing "ac-section-missing/pass"

# ================================================================ ac-legacy-format
cat > "$q/PRD-ac-legacy.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

AC-1: Given a, When b, Then c.
EOF
expect_fail "$q/PRD-ac-legacy.md" ac-legacy-format "ac-legacy-format/fail"
expect_clean_no_id "$q/PRD-status-ok.md" failures ac-legacy-format "ac-legacy-format/pass"

# ==================================================================== ac-no-lines
cat > "$q/PRD-ac-no-lines.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. Given a, When b, Then c (no P-level prefix).
EOF
expect_fail "$q/PRD-ac-no-lines.md" ac-no-lines "ac-no-lines/fail"
expect_clean_no_id "$q/PRD-status-ok.md" failures ac-no-lines "ac-no-lines/pass"

# =================================================================== ac-missing-gwt
cat > "$q/PRD-ac-missing-gwt.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — A thing happens and nothing else follows.
EOF
expect_fail "$q/PRD-ac-missing-gwt.md" ac-missing-gwt "ac-missing-gwt/fail"
expect_clean_no_id "$q/PRD-status-ok.md" failures ac-missing-gwt "ac-missing-gwt/pass"

# Wrapped multi-line AC (common in this workspace) must still be read whole.
cat > "$q/PRD-ac-wrapped.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a long precondition that wraps across a line, When the
   action described on this continuation line happens, Then the
   outcome on this third line is asserted.
EOF
expect_clean_no_id "$q/PRD-ac-wrapped.md" failures ac-missing-gwt "ac-missing-gwt/pass (wrapped AC)"

# ==================================================================== pinned-sha-in-ac
# Real defect (2026-09-03): PRD-mcphost-gate-green.md AC4 pinned a rollback
# base to the crate's first commit (`--base 9315032`); cycles 14-17 thrashed
# because no later squash could revert-clean against that fixed a root.
cat > "$q/PRD-pinned-sha.md" <<'EOF'
- Status: queued
- build_target: rust-extend
- build_into: /tmp
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given the shipped HEAD, When `autobuilder rollback-plan --project . --base 9315032` runs, Then every commit in range is revert-clean and the verdict is `pass`.
EOF
expect_warn "$q/PRD-pinned-sha.md" pinned-sha-in-ac "pinned-sha-in-ac/warn (real defect: mcphost-gate-green AC4)"

cat > "$q/PRD-pinned-sha-ok.md" <<'EOF'
- Status: queued
- build_target: rust-extend
- build_into: /tmp
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given tags v0.5.1 and v0.5.4, When `autobuilder rollback-plan --project . --base v0.5.1` runs, Then every commit in range is revert-clean and the verdict is `pass`.
EOF
expect_clean_no_id "$q/PRD-pinned-sha-ok.md" warnings pinned-sha-in-ac "pinned-sha-in-ac/pass"

# ======================================================================== home-path-in-ac
cat > "$q/PRD-home-path.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given /home/jsy/wintermute/build-skill exists, When linted, Then it warns.
EOF
expect_warn "$q/PRD-home-path.md" home-path-in-ac "home-path-in-ac/warn"
expect_clean_no_id "$q/PRD-status-ok.md" warnings home-path-in-ac "home-path-in-ac/pass"

# ================================================================================ OK
cat > "$b/PRD-clean-built.md" <<'EOF'
- Status: built
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a clean built PRD, When linted, Then it exits 0 with OK.
EOF
expect_ok "$b/PRD-clean-built.md" "clean-from-built-prds"

# --------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  echo "SELFTEST FAILED ($fails/$total checks)"
  exit 1
fi
echo "SELFTEST PASSED ($total checks)"
