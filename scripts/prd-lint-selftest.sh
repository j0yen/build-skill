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

mkdir -p "$tmp/build-queue" "$tmp/built-prds" "$tmp/parked" "$tmp/visions"
q="$tmp/build-queue"
b="$tmp/built-prds"
p="$tmp/parked"
v="$tmp/visions"

echo "plain vision, no loop contract." > "$v/plain.md"
cat > "$v/loopy.md" <<'EOF'
# Vision: loopy

## Loop
This vision declares a standing loop contract.
EOF

fails=0
total=0

# Findings added by the dream shift-left checks; WARN-level on any fixture that
# predates them (no `Drafted:` >= 2026-10-23), so expect_ok tolerates them.
SHIFT_IDS="seed-missing|unknown-frontmatter-key|premise-ac-not-live|live-evidence-referent-missing|live-evidence-referent-unchecked|shared-counter-preassigned|cross-repo-path-in-ac|later-event-without-blocked-on|ssh-evidence-no-path-prefix|mcp-curl-no-accept|signup-without-offboard|generator-set-member|hand-built-marker-missing|build-priority-default|live-evidence-off-host"

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
  # shift-left WARNs (seed-missing etc.) on old-style fixtures do not make a file "not OK"
  local rest; rest="$(grep -Ev "^[0-9]+\. WARN ($SHIFT_IDS):|^OK$|^$" /tmp/prd-lint-selftest.out)"
  if [ "$rc" -eq 0 ] && [ -z "$rest" ]; then
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

# ================================================= build-into-substrate-mismatch
# Real defect fixture (PRD-build-classification-self-heal, 2026-09-12): the
# actual 09-12 pair -- build_target: python-cli committed against a real
# Cargo workspace -- bounced three dispatches before a human fixed it by
# hand, because lint never read build_into's substrate. This is that exact
# frontmatter pair, not a synthetic one, per this PRD's own fixture rule.
mkdir -p "$tmp/cargo-ws" "$tmp/py-ws"
cat > "$tmp/cargo-ws/Cargo.toml" <<'EOF'
[workspace]
members = ["crates/foo"]
EOF
cat > "$tmp/py-ws/pyproject.toml" <<'EOF'
[project]
name = "example"
EOF

cat > "$q/PRD-substrate-09-12-defect.md" <<EOF
- Status: queued
- build_target: python-cli
- build_into: $tmp/cargo-ws
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-substrate-09-12-defect.md" build-into-substrate-mismatch "substrate-mismatch/fail (real 09-12 defect: python-cli vs Cargo workspace)"

cat > "$q/PRD-substrate-09-12-fixed.md" <<EOF
- Status: queued
- build_target: rust-extend
- build_into: $tmp/cargo-ws
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_clean_no_id "$q/PRD-substrate-09-12-fixed.md" failures build-into-substrate-mismatch "substrate-mismatch/pass (rust-extend vs Cargo workspace, no false positive)"

cat > "$q/PRD-substrate-rust-vs-py.md" <<EOF
- Status: queued
- build_target: rust-extend
- build_into: $tmp/py-ws
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-substrate-rust-vs-py.md" build-into-substrate-mismatch "substrate-mismatch/fail (rust-extend vs pyproject-only)"

cat > "$q/PRD-substrate-py-vs-py.md" <<EOF
- Status: queued
- build_target: python-cli
- build_into: $tmp/py-ws
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_clean_no_id "$q/PRD-substrate-py-vs-py.md" failures build-into-substrate-mismatch "substrate-mismatch/pass (python-cli vs pyproject, no false positive)"

# missing build_into path stays the pre-existing warn-only behavior
# (requirement 1: "missing path stays the existing failure") -- this
# fixture reuses PRD-into-not-found.md above and asserts the NEW check
# does not also fire a failure for it (no compounding).
expect_clean_no_id "$q/PRD-into-not-found.md" failures build-into-substrate-mismatch "substrate-mismatch/missing-path-unchanged"

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

# ================================================ deferred_ac_reasons key (PRD-build-prd-lint-deferred-reasons-key)
# Real defect (2026-09-15): PRD-mcphost-tenant-tables carries this exact
# shape -- `deferred_ac_reasons:` only, no `mock_justifications:` -- and
# bounced needs_classification three times before the lint learned this key.
cat > "$q/PRD-deferred-reasons-complete.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- deferred_acs: [10, 11]
- deferred_ac_reasons: {"10": "needs a live deploy restore drill, not a unit test.", "11": "P2 export held until table usage exists."}

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_clean_no_id "$q/PRD-deferred-reasons-complete.md" failures deferred-acs-missing-justification "deferred-acs-missing-justification/pass (deferred_ac_reasons only, real defect: mcphost-tenant-tables)"
expect_clean_no_id "$q/PRD-deferred-reasons-complete.md" failures deferred-acs-reason-missing "deferred-acs-reason-missing/pass (both ACs covered)"
expect_clean_no_id "$q/PRD-deferred-reasons-complete.md" failures deferred-acs-reasons-prose "deferred-acs-reasons-prose/pass (valid JSON object)"

cat > "$q/PRD-deferred-reasons-partial.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- deferred_acs: [10, 11]
- deferred_ac_reasons: {"10": "needs a live deploy restore drill, not a unit test."}

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-deferred-reasons-partial.md" deferred-acs-reason-missing "deferred-acs-reason-missing/fail (AC 11 uncovered)"

cat > "$q/PRD-deferred-reasons-prose.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- deferred_acs: [10, 11]
- deferred_ac_reasons: see below

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-deferred-reasons-prose.md" deferred-acs-reasons-prose "deferred-acs-reasons-prose/fail"

cat > "$q/PRD-deferred-both-keys.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- deferred_acs: [10, 11]
- mock_justifications: AC10 needs a live drill; AC11 is held pending usage.
- deferred_ac_reasons: {"10": "needs a live deploy restore drill, not a unit test.", "11": "P2 export held until table usage exists."}

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_clean_no_id "$q/PRD-deferred-both-keys.md" failures deferred-acs-missing-justification "deferred-acs-missing-justification/pass (both keys present)"

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
cat > "$q/PRD-dep-none.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Depends-on: none

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_clean_no_id "$q/PRD-dep-none.md" failures depends-on-missing "depends-on-none/pass"

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

# ================================================== real-box-ac-no-authorization
# PRD-build-operator-authorization-contract requirement 8/AC11-12: an AC
# naming a real box/real money/hcloud spend with no Operator-authorization
# key present is a WARN (not FAIL -- a PRD may legitimately describe such an
# AC and defer it pending a future authorization).
cat > "$q/PRD-realbox-warn.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a real ccx43, When `hcloud server create` runs, Then the box boots and is billed for the hour.
EOF
expect_warn "$q/PRD-realbox-warn.md" real-box-ac-no-authorization "real-box-ac-no-authorization/warn"

cat > "$q/PRD-realbox-ok.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Operator-authorization: Joe 2026-09-13T23:15:00Z "run prove" scope: one real ccx43 for prove

## Acceptance criteria

1. P0 — Given a real ccx43, When `hcloud server create` runs, Then the box boots and is billed for the hour.
EOF
expect_clean_no_id "$q/PRD-realbox-ok.md" warnings real-box-ac-no-authorization "real-box-ac-no-authorization/pass (key present)"

# ============================================================ credential-reuse-unbacked
# PRD-build-tenant-secret-continuity, AC3: a PRD claiming a credential is
# "already held" with nothing under state/secrets/<slug>/ backing it up.
cred_state="$tmp/state-scratch"
cat > "$q/PRD-cred-claim.md" <<'EOF'
- Status: building
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given the tenant key already held from a prior dispatch, When reused, Then it just works.
EOF
BUILD_STATE_DIR="$cred_state" expect_warn "$q/PRD-cred-claim.md" credential-reuse-unbacked "credential-reuse-unbacked/warn (no secret file)"

mkdir -p "$cred_state/secrets/cred-claim"
echo '{"value":"x","written_at":"2026-01-01T00:00:00Z"}' > "$cred_state/secrets/cred-claim/tenant_key.json"
BUILD_STATE_DIR="$cred_state" expect_clean_no_id "$q/PRD-cred-claim.md" warnings credential-reuse-unbacked "credential-reuse-unbacked/pass (secret file present)"
expect_clean_no_id "$q/PRD-status-ok.md" warnings credential-reuse-unbacked "credential-reuse-unbacked/pass (no claim in text)"

# ============================================================ grounding-missing
# PRD-prd-contract-lint AC5: presence-only (see the check's own comment for
# why the vocabulary itself -- wwhtbt/five-whys/failure-derived/... -- isn't
# enforced), and a WARN not a FAIL (see the check's own comment: ~45% of the
# live build-queue/ corpus at ship time predates this convention -- a FAIL
# would have stranded roughly half the queue into needs_classification the
# instant this shipped).
cat > "$q/PRD-grounding-missing.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_warn "$q/PRD-grounding-missing.md" grounding-missing "grounding-missing/warn"

cat > "$q/PRD-grounding-ok.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Grounding: wwhtbt — visions/plain.md leaf 1 (fixture)

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_clean_no_id "$q/PRD-grounding-ok.md" warnings grounding-missing "grounding-missing/pass"

# ============================================================ ac-heading-inflation
# PRD-prd-contract-lint AC8 / real 2026-07-02 incident shape: numbered ACs
# followed by an h3 (or bold-only) pseudo-heading that reuses `1.`/`2.` for
# something else. verified-completed.sh's own awk never closes its AC block
# on that heading (only a real `## ` does), so it counts the reused numbers
# as phantom ACs -- see verified-completed-ac-count-h3-inflation memory.
cat > "$q/PRD-ac-inflation-h3.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Grounding: wwhtbt — visions/plain.md leaf 1 (fixture)

## Acceptance criteria

1. P0 — Given a, When b, Then c.
2. P0 — Given d, When e, Then f.

### Anti-pattern audit

1. Not a real AC, just a checklist reusing numbers.
2. Same shape as the real 2026-07-02 incident.
EOF
expect_fail "$q/PRD-ac-inflation-h3.md" ac-heading-inflation "ac-heading-inflation/fail (h3)"

cat > "$q/PRD-ac-inflation-bold.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Grounding: wwhtbt — visions/plain.md leaf 1 (fixture)

## Acceptance criteria

1. P0 — Given a, When b, Then c.

**Anti-pattern audit.**

1. Not a real AC either.
EOF
expect_fail "$q/PRD-ac-inflation-bold.md" ac-heading-inflation "ac-heading-inflation/fail (bold)"

expect_clean_no_id "$q/PRD-status-ok.md" failures ac-heading-inflation "ac-heading-inflation/pass"

# ============================================================ Superseded-by / transferred_acs / Absorbs (PRD-build-prd-superseded-by AC2-5, AC10)

# -- AC2: superseded-by-target-missing --------------------------------------
cat > "$q/PRD-sup-missing.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Superseded-by: PRD-nowhere.md
- transferred_acs: [1]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-sup-missing.md" superseded-by-target-missing "superseded-by-target-missing/fail"

# -- superseded-by-target-parked --------------------------------------------
cat > "$p/PRD-sup-parked-target.md" <<'EOF'
- Status: parked
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a, When b, Then c.
2. P0 — Given d, When e, Then f.
EOF
cat > "$q/PRD-sup-parked.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Superseded-by: PRD-sup-parked-target.md
- transferred_acs: [1]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-sup-parked.md" superseded-by-target-parked "superseded-by-target-parked/fail"

# -- superseded-by-cycle -----------------------------------------------------
cat > "$q/PRD-sup-cycle-a.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Superseded-by: PRD-sup-cycle-b.md
- transferred_acs: [1]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
cat > "$q/PRD-sup-cycle-b.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Superseded-by: PRD-sup-cycle-a.md
- transferred_acs: [1]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-sup-cycle-a.md" superseded-by-cycle "superseded-by-cycle/fail"

# -- AC3: transferred-ac-unmapped --------------------------------------------
cat > "$q/PRD-abs-succ-partial.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Absorbs: PRD-sup-unmapped.md [9:15]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
15. P0 — Given a, When b, Then c.
EOF
cat > "$q/PRD-sup-unmapped.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Superseded-by: PRD-abs-succ-partial.md
- transferred_acs: [9, 10]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-sup-unmapped.md" transferred-ac-unmapped "transferred-ac-unmapped/fail"

# -- AC1 clean pairing (also proves the pass side of AC3/AC9): every
# transferred AC mapped, none unmapped -------------------------------------
cat > "$q/PRD-abs-succ-clean.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Absorbs: PRD-sup-clean.md [9:15, 10:16]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
15. P0 — Given a, When b, Then c.
16. P0 — Given a, When b, Then c.
EOF
cat > "$q/PRD-sup-clean.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Superseded-by: PRD-abs-succ-clean.md
- transferred_acs: [9, 10]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
expect_clean_no_id "$q/PRD-sup-clean.md" failures transferred-ac-unmapped "transferred-ac-unmapped/pass"
expect_clean_no_id "$q/PRD-abs-succ-clean.md" failures absorbs-ac-missing "absorbs-ac-missing/pass"

# -- AC4: transferred-live-ac-not-live ---------------------------------------
cat > "$q/PRD-abs-succ-notlive.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Absorbs: PRD-sup-live.md [9:15]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
15. P0 — Given a, When b, Then c.
EOF
cat > "$q/PRD-sup-live.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Superseded-by: PRD-abs-succ-notlive.md
- transferred_acs: [9]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
9. P0 — Given a, When b, Then c. (Live; evidence: fixture)
EOF
expect_fail "$q/PRD-sup-live.md" transferred-live-ac-not-live "transferred-live-ac-not-live/fail"

# -- AC5: absorbs-ac-missing --------------------------------------------------
cat > "$q/PRD-abs-missing.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Absorbs: PRD-sup-for-abs-missing.md [9:15]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
cat > "$q/PRD-sup-for-abs-missing.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- transferred_acs: [9]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
9. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-abs-missing.md" absorbs-ac-missing "absorbs-ac-missing/fail"

# -- AC10: absorbed-ac-cannot-defer -------------------------------------------
cat > "$q/PRD-abs-defer-conflict.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- Absorbs: PRD-sup-for-defer-conflict.md [9:15]
- deferred_acs: [15]
- mock_justifications: AC15 justified for fixture purposes only.

## Acceptance criteria

1. P0 — Given a, When b, Then c.
15. P0 — Given a, When b, Then c.
EOF
cat > "$q/PRD-sup-for-defer-conflict.md" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- transferred_acs: [9]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
9. P0 — Given a, When b, Then c.
EOF
expect_fail "$q/PRD-abs-defer-conflict.md" absorbed-ac-cannot-defer "absorbed-ac-cannot-defer/fail"

# ============================================================ directory arg / --quiet / --format pass-fail (PRD-prd-contract-lint AC1, AC7)
dirtest="$tmp/dirtest"
mkdir -p "$dirtest/visions"
cp "$v/plain.md" "$dirtest/visions/plain.md"
cp "$q/PRD-grounding-ok.md" "$dirtest/PRD-dir-ok.md"
cp "$q/PRD-ac-inflation-h3.md" "$dirtest/PRD-dir-fail.md"

total=$((total+1))
out="$("$LINT" --format json "$dirtest" 2>/dev/null)"
if printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if len(d)==2 else 1)" 2>/dev/null; then
  echo "ok: directory-arg -> expands to its 2 PRD-*.md files"
else
  echo "FAIL: directory-arg expected 2 results, got: $out"
  fails=$((fails+1))
fi

total=$((total+1))
out="$("$LINT" --quiet "$dirtest" 2>/dev/null)"
n_lines="$(printf '%s\n' "$out" | grep -c '^FAIL ')"
n_pass_lines="$(printf '%s\n' "$out" | grep -c '^PASS ')"
if [ "$n_lines" -eq 1 ] && [ "$n_pass_lines" -eq 0 ]; then
  echo "ok: --quiet -> one FAIL line, no PASS lines, over a mixed directory"
else
  echo "FAIL: --quiet expected 1 FAIL line and 0 PASS lines, got: $out"
  fails=$((fails+1))
fi

total=$((total+1))
out="$("$LINT" --format pass-fail "$dirtest/PRD-dir-ok.md" 2>/dev/null)"
if [ "${out%%: *}" = "PASS $dirtest/PRD-dir-ok.md" ] || [ "$out" = "PASS $dirtest/PRD-dir-ok.md" ]; then
  echo "ok: format pass-fail -> 'PASS <file>' on a clean file"
else
  echo "FAIL: format pass-fail expected 'PASS <file>', got: $out"
  fails=$((fails+1))
fi

total=$((total+1))
out="$("$LINT" --format pass-fail "$dirtest/PRD-dir-fail.md" 2>/dev/null)"
case "$out" in
  "FAIL $dirtest/PRD-dir-fail.md:"*"ac-heading-inflation"*)
    echo "ok: format pass-fail -> 'FAIL <file>: <finding>...' on a failing file" ;;
  *)
    echo "FAIL: format pass-fail expected 'FAIL <file>: ...ac-heading-inflation...', got: $out"
    fails=$((fails+1)) ;;
esac

# ============================================================ --contract override (PRD-prd-contract-lint P2)
contract_file="$tmp/mini-contract.md"
cat > "$contract_file" <<'EOF'
| `build_target` | `widget-only` (test contract, not the real one) | yes | anything else -> needs_classification |
EOF
total=$((total+1))
out="$("$LINT" --format json --contract "$contract_file" "$q/PRD-grounding-ok.md" 2>/dev/null)"
if has_id "$out" failures build-target-unknown; then
  echo "ok: --contract override -> shell now fails against a restricted test contract"
else
  echo "FAIL: --contract override expected build-target-unknown, got: $out"
  fails=$((fails+1))
fi

# ==================================================== key-parity (PRD-build-prd-lint-deferred-reasons-key requirement 6)
# Every literal frontmatter key scan-prds.sh's own PRD-parsing function
# declares (its wide `local ...` line, plus every --arg/--argjson name it
# feeds to jq) must be either a key prd-lint.sh specifically checks the
# shape of, or named in the allowlist below with a one-line reason -- so a
# key one script parses and the other has never heard of (the exact
# `deferred_ac_reasons` defect this PRD fixes) fails THIS selftest instead
# of silently stranding some future PRD the same way.
SCAN_PRDS="$HERE/scan-prds.sh"

# Keys prd-lint.sh actually validates the shape of -- kept in sync BY HAND
# with prd-lint.sh's own fm.get("...")/"..." in fm checks, same
# duplicate-and-comment convention prd-lint.sh itself uses for
# RUST_SUBSTRATE_TARGETS mirroring substrate-probe.sh.
KNOWN_LINT_KEYS="status build_target build_into deferred_acs mock_justifications deferred_ac_reasons depends_on vision loop operator_authorization grounding superseded_by transferred_acs absorbs foreign_surface_ok foreign_surface_reasons"

# scan-prds.sh-only fields with no lint shape to check -- one reason each.
declare -A PARITY_ALLOWLIST=(
  [slug]="derived from the filename, not a frontmatter key"
  [path]="filesystem path argument, not frontmatter"
  [status_line]="raw Status line text; prd-lint checks presence via 'status'"
  [build_auto]="hardcoded true since 2026-05-27 (every PRD is buildable); frontmatter value is ignored, nothing to validate"
  [build_priority]="free-form enum (high/normal/low); any value is legal per build-contract.md, no shape to validate"
  [build_version_bump]="free-form enum (patch/minor/major); any value is legal, no shape to validate"
  [deferred_acs_unparsed]="a derived flag from parsing deferred_acs, not itself a frontmatter key"
  [operator_authorization_unparsed]="a derived flag from parsing operator-authorization, not itself a frontmatter key"
  [publish]="free-form enum (j0yen/private, j0yen/public, none); no shape to validate at lint time"
  [test_prefix]="free-form scalar or list naming a test-file prefix; no shape to validate at lint time"
  [size]="file stat metadata, not frontmatter"
  [mtime]="file stat metadata, not frontmatter"
  [substrate]="computed diagnostic (substrate-probe.sh's own algorithm), not frontmatter"
  [gate_stale]="computed diagnostic, not frontmatter"
  [transferred_acs_unparsed]="a derived flag from parsing transferred_acs, not itself a frontmatter key"
  [absorbs_unparsed]="a derived flag from parsing Absorbs, not itself a frontmatter key"
  [live_acs]="derived list of the AC numbers carrying (Live, computed from the AC block, not a frontmatter key; prd-lint.sh enforces (Live through its live-ac-* checks"
)

scan_keys="$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
names = set()
# The one wide `local ...` line declaring every field this function reads
# (anchored on two fields that only appear together there) -- not every
# `local` in the file, which would also pull in unrelated loop-internal
# bash variables (in_fence, seen_target, bi_path, ...).
wide = next(
    (l for l in text.splitlines()
     if l.strip().startswith("local ") and "deferred_acs" in l and "build_target" in l),
    "",
)
for tok in wide.split():
    if tok == "local":
        continue
    name = tok.split("=")[0]
    if re.match(r"^[a-z][a-z0-9_]*$", name):
        names.add(name)
for m in re.finditer(r"--arg(?:json)?\s+([A-Za-z_][A-Za-z0-9_]*)", text):
    names.add(m.group(1))
print(" ".join(sorted(names)))
' "$SCAN_PRDS")"

total=$((total+1))
unaccounted=""
for k in $scan_keys; do
  case " $KNOWN_LINT_KEYS " in *" $k "*) continue ;; esac
  [ -n "${PARITY_ALLOWLIST[$k]+x}" ] && continue
  unaccounted="$unaccounted $k"
done
if [ -z "$unaccounted" ]; then
  echo "ok: key-parity -> every scan-prds.sh field is known to prd-lint.sh or allowlisted ($scan_keys)"
else
  echo "FAIL: key-parity -> scan-prds.sh field(s) unknown to prd-lint.sh and not allowlisted:$unaccounted"
  fails=$((fails+1))
fi

# ================================================================================ OK
cat > "$b/PRD-clean-built.md" <<'EOF'
- Status: built
- build_target: shell
- Vision: visions/plain.md
- Grounding: wwhtbt — visions/plain.md leaf 1 (fixture)

## Acceptance criteria

1. P0 — Given a clean built PRD, When linted, Then it exits 0 with OK.
EOF
expect_ok "$b/PRD-clean-built.md" "clean-from-built-prds"

# ======================================================================== ac-text-over-intent-card-cap
pad() { head -c "$1" /dev/zero | tr '\0' 'x'; }
mk_cap_prd() { # $1=file $2=pad length (Then clause carries the padding)
  cat > "$1" <<EOF2
- Status: queued
- build_target: shell
- Vision: visions/plain.md

## Acceptance criteria

1. P0 — Given a fixture, When linted, Then $(pad "$2").
EOF2
}
mk_cap_prd "$q/PRD-cap-over.md" 520
mk_cap_prd "$q/PRD-cap-under.md" 400
expect_fail "$q/PRD-cap-over.md" ac-text-over-intent-card-cap "ac-text-over-intent-card-cap/520-fail"
expect_clean_no_id "$q/PRD-cap-under.md" failures ac-text-over-intent-card-cap "ac-text-over-intent-card-cap/400-pass"
total=$((total+1))
o="$(PRD_LINT_INTENT_CARD_CAP=300 "$LINT" --format json "$q/PRD-cap-under.md" 2>/dev/null)"
if grep -q ac-text-over-intent-card-cap <<<"$o"; then
  echo "ok: ac-text-over-intent-card-cap/env-override-300 -> FAIL on 400"
else echo "FAIL: env override 300 did not flag 400-char AC"; fails=$((fails+1)); fi
total=$((total+1))
o="$(PRD_LINT_INTENT_CARD_CAP=900 "$LINT" --format json "$q/PRD-cap-over.md" 2>/dev/null)"
if grep -q ac-text-over-intent-card-cap <<<"$o"; then
  echo "FAIL: env override 900 still flagged 520-char AC"; fails=$((fails+1))
else echo "ok: ac-text-over-intent-card-cap/env-override-900 -> clean"; fi
total=$((total+1))
o="$(WM_BUILD_SRC=/nonexistent "$LINT" --format json "$q/PRD-cap-over.md" 2>/dev/null)"
if grep -q intent-card-cap-source-missing <<<"$o"; then
  echo "ok: intent-card-cap-source-missing/warn"
else echo "FAIL: missing source did not warn"; fails=$((fails+1)); fi

# ======================================================================== ac-names-foreign-surface
# PRD-build-prd-lint-cross-repo-ac. Fixture repos: A (pyproject script `alpha`,
# module alpha/digest.py), B (script `beta`), C (Cargo package/bin/src/bin),
# S (shell scripts/ + bin/); `shared-cli` is a script of both A and B. The
# corpus is $q/built-prds/parked: its build_into values are the fleet map.
SURF="$HERE/repo-surface.sh"
xa="$tmp/xrepo-A"; xb="$tmp/xrepo-B"; xc="$tmp/xrepo-C"; xs="$tmp/xrepo-S"; xe="$tmp/xrepo-empty"
mkdir -p "$xa/alpha" "$xb/src/beta" "$xc/src/bin/tool-dir" "$xs/scripts" "$xs/bin" "$xe/docs"
cat > "$xa/pyproject.toml" <<'EOF2'
[project]
name = "alpha-dist"

[project.scripts]
alpha = "alpha.cli:main"
shared-cli = "alpha.cli:shared"

[tool.other]
notascript = "x"
EOF2
: > "$xa/alpha/__init__.py"; : > "$xa/alpha/digest.py"; : > "$xa/alpha/_private.py"
mkdir -p "$xa/tests"; : > "$xa/tests/test_alpha.py"
cat > "$xb/pyproject.toml" <<'EOF2'
[project.scripts]
beta = "beta.cli:main"
"shared-cli" = "beta.cli:shared"
EOF2
: > "$xb/src/beta/__init__.py"; : > "$xb/src/beta/render.py"
cat > "$xc/Cargo.toml" <<'EOF2'
[package]
name = "gamma"
version = "0.1.0"

[[bin]]
name = "gamma-tool"
path = "src/main.rs"

[dependencies]
name = "not-a-bin"
EOF2
: > "$xc/src/main.rs"; : > "$xc/src/bin/delta.rs"; : > "$xc/src/bin/tool-dir/main.rs"
: > "$xs/scripts/sigma.sh"; : > "$xs/scripts/notes.txt"; : > "$xs/bin/omega"

# -- repo-surface.sh (AC 5): generated, nothing typed
total=$((total+1))
out_a="$("$SURF" "$xa")"
if [ "$out_a" = "$(printf 'alpha\ndigest\nshared-cli')" ]; then
  echo "ok: repo-surface/python -> scripts + root-package modules, no __init__/_private/tests, no [project] name"
else echo "FAIL: repo-surface/python got: $out_a"; fails=$((fails+1)); fi
total=$((total+1))
out_b="$("$SURF" "$xb" | tr '\n' ' ')"
if [ "$out_b" = "beta render shared-cli " ]; then
  echo "ok: repo-surface/python-src-layout -> quoted script key + src/<pkg> module"
else echo "FAIL: repo-surface/src-layout got: $out_b"; fails=$((fails+1)); fi
total=$((total+1))
out_c="$("$SURF" "$xc" | tr '\n' ' ')"
if [ "$out_c" = "delta gamma gamma-tool tool-dir " ]; then
  echo "ok: repo-surface/cargo -> package, [[bin]], src/bin stems and dirs"
else echo "FAIL: repo-surface/cargo got: $out_c"; fails=$((fails+1)); fi
total=$((total+1))
out_s="$("$SURF" "$xs" | tr '\n' ' ')"
if [ "$out_s" = "omega sigma " ]; then
  echo "ok: repo-surface/shell -> scripts/*.sh stems + bin/* names"
else echo "FAIL: repo-surface/shell got: $out_s"; fails=$((fails+1)); fi
total=$((total+1))
out_e="$("$SURF" "$xe")"; rc_e=$?
if [ -z "$out_e" ] && [ "$rc_e" -eq 0 ] && [ -z "$("$SURF" "$tmp/no-such-dir")" ]; then
  echo "ok: repo-surface/no markers (and a missing dir) -> empty output, exit 0"
else echo "FAIL: repo-surface/empty got rc=$rc_e out=$out_e"; fails=$((fails+1)); fi
total=$((total+1))
if ! grep -qE 'mtproof|synthorg|mcphost|alpha|beta' "$SURF"; then
  echo "ok: repo-surface.sh types no repo or token (generated, not a list)"
else echo "FAIL: repo-surface.sh names a repo/token literally"; fails=$((fails+1)); fi
# cache: a git checkout is cached by path+HEAD and a second read is identical
total=$((total+1))
xg="$tmp/xrepo-git"; mkdir -p "$xg"; cp -r "$xb/." "$xg/"
git -C "$xg" init -q 2>/dev/null && git -C "$xg" add -A && git -C "$xg" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
cache_t="$tmp/xcache"
g1="$(PRD_LINT_CACHE="$cache_t" "$SURF" "$xg")"; g2="$(PRD_LINT_CACHE="$cache_t" "$SURF" "$xg")"
if [ -n "$g1" ] && [ "$g1" = "$g2" ] && [ "$(ls "$cache_t/surface" | wc -l)" -eq 1 ]; then
  echo "ok: repo-surface/cache -> one HEAD-keyed file, second read identical"
else echo "FAIL: repo-surface/cache g1=$g1 g2=$g2 files=$(ls "$cache_t/surface" 2>&1)"; fails=$((fails+1)); fi

# -- corpus naming A, B and C as build_into (the fleet map)
# (its own corpus tree, so an unrelated fixture's build_into cannot reach it)
xq="$tmp/xc1/build-queue"; xbp="$tmp/xc1/built-prds"; xpk="$tmp/xc1/parked"
mkdir -p "$xq" "$xbp" "$xpk" "$tmp/xc1/visions"
cp "$v/plain.md" "$tmp/xc1/visions/plain.md"
cat > "$xbp/PRD-xrepo-corpus-b.md" <<EOF2
- Status: built
- build_target: python-cli
- build_into: $xb
- Vision: visions/plain.md
EOF2
cat > "$xpk/PRD-xrepo-corpus-c.md" <<EOF2
- Status: parked
- build_target: rust-cli
- build_into: $xc
- Vision: visions/plain.md
EOF2
mk_xrepo_prd() { # $1=file $2=AC 2 body (after "P0 — ") $3=extra frontmatter lines (optional)
  cat > "$1" <<EOF2
- Status: queued
- build_target: python-cli
- build_into: $xa
- Vision: visions/plain.md
- Grounding: failure-derived — run 614 (fixture)
${3:-}

## Acceptance criteria

1. P0 — Given a fixture, When \`alpha run\` is invoked, Then it exits 0.
2. P0 — $2
EOF2
}
mk_xrepo_prd "$xq/PRD-xrepo-foreign.md" 'Given a digest, When `beta render` runs, Then it prints the table.'
mk_xrepo_prd "$xq/PRD-xrepo-own.md" 'Given a digest, When `alpha render` runs, Then it prints the table.'
expect_fail "$xq/PRD-xrepo-foreign.md" ac-names-foreign-surface "ac-names-foreign-surface/beta-in-A-prd-fail"
expect_ok "$xq/PRD-xrepo-own.md" "ac-names-foreign-surface/alpha-in-A-prd-pass"
total=$((total+1))
o="$("$LINT" --format pass-fail "$xq/PRD-xrepo-foreign.md" 2>/dev/null)"
if grep -q "ac-names-foreign-surface: AC 2 names 'beta' (surface of $xb)" <<<"$o" && ! grep -q "AC 1 names" <<<"$o"; then
  echo "ok: ac-names-foreign-surface/message names AC 2, beta, and the owning repo B"
else echo "FAIL: ac-names-foreign-surface message got: $o"; fails=$((fails+1)); fi

# module stems, .py-stripped: `render.py` is B's module; `digest.py` is A's own
mk_xrepo_prd "$xq/PRD-xrepo-stem-foreign.md" 'Given a table, When `render.py --json` runs, Then it prints JSON.'
mk_xrepo_prd "$xq/PRD-xrepo-stem-own.md" 'Given a table, When `digest.py --json` runs, Then it prints JSON.'
expect_fail "$xq/PRD-xrepo-stem-foreign.md" ac-names-foreign-surface "ac-names-foreign-surface/foreign-module-stem-fail"
expect_ok "$xq/PRD-xrepo-stem-own.md" "ac-names-foreign-surface/own-module-stem-pass"
# Cargo and shell surfaces are foreign too
mk_xrepo_prd "$xq/PRD-xrepo-cargo-foreign.md" 'Given a build, When `gamma-tool --check` runs, Then it exits 0.'
expect_fail "$xq/PRD-xrepo-cargo-foreign.md" ac-names-foreign-surface "ac-names-foreign-surface/cargo-bin-in-python-prd-fail"
# a token in BOTH surfaces never fails (shared-cli is a script of A and of B)
mk_xrepo_prd "$xq/PRD-xrepo-shared.md" 'Given a fixture, When `shared-cli sync` runs, Then it exits 0.'
expect_ok "$xq/PRD-xrepo-shared.md" "ac-names-foreign-surface/token-in-both-surfaces-pass"

# (Live; evidence: ...) is exempt (AC 3): live probes run anything
mk_xrepo_prd "$xq/PRD-xrepo-live.md" 'Given the deployed host, When the digest renders, Then it lists every row (Live; evidence: `ssh orch '"'"'beta render'"'"'` prints the table)'
expect_ok "$xq/PRD-xrepo-live.md" "ac-names-foreign-surface/foreign-token-only-in-Live-evidence-pass"
mk_xrepo_prd "$xq/PRD-xrepo-live-prefix.md" 'Given a digest, When `beta render` runs, Then it prints the table (Live; evidence: `ssh orch alpha` prints it)'
expect_fail "$xq/PRD-xrepo-live-prefix.md" ac-names-foreign-surface "ac-names-foreign-surface/foreign-token-BEFORE-Live-tail-fail"

# foreign_surface_ok + foreign_surface_reasons (AC 4)
mk_xrepo_prd "$xq/PRD-xrepo-ok-reason.md" 'Given a digest, When `beta render` runs, Then it prints the table.' \
'- foreign_surface_ok: [2]
- foreign_surface_reasons: {"2": "fixture CLI, not subject"}'
mk_xrepo_prd "$xq/PRD-xrepo-ok-noreason.md" 'Given a digest, When `beta render` runs, Then it prints the table.' \
'- foreign_surface_ok: [2]'
mk_xrepo_prd "$xq/PRD-xrepo-ok-prose.md" 'Given a digest, When `beta render` runs, Then it prints the table.' \
'- foreign_surface_ok: see below'
expect_ok "$xq/PRD-xrepo-ok-reason.md" "foreign-surface-ok/list+reason-pass"
expect_fail "$xq/PRD-xrepo-ok-noreason.md" foreign-surface-reason-missing "foreign-surface-reason-missing/fail"
expect_clean_no_id "$xq/PRD-xrepo-ok-reason.md" failures foreign-surface-reason-missing "foreign-surface-reason-missing/pass"
expect_fail "$xq/PRD-xrepo-ok-prose.md" foreign-surface-ok-prose "foreign-surface-ok-prose/fail"
expect_clean_no_id "$xq/PRD-xrepo-ok-reason.md" failures foreign-surface-ok-prose "foreign-surface-ok-prose/pass"
# an exemption names only its own AC: a second foreign AC still fails
mk_xrepo_prd "$xq/PRD-xrepo-ok-other.md" 'Given a digest, When `beta render` runs, Then it prints the table.' \
'- foreign_surface_ok: [1]
- foreign_surface_reasons: {"1": "unrelated"}'
expect_fail "$xq/PRD-xrepo-ok-other.md" ac-names-foreign-surface "foreign-surface-ok/exempts-only-the-listed-AC"

# WARN foreign-surface-repo-missing: a corpus build_into absent on this host
# is never a fail, and is reported once per run (own corpus tree, so the
# warning cannot reach the OK fixtures above)
mkdir -p "$tmp/xc2/build-queue" "$tmp/xc2/visions"
cp "$v/plain.md" "$tmp/xc2/visions/plain.md"
cat > "$tmp/xc2/build-queue/PRD-xrepo-gone.md" <<EOF2
- Status: queued
- build_target: python-cli
- build_into: $tmp/xrepo-gone-not-on-this-host
- Vision: visions/plain.md
EOF2
mk_xrepo_prd "$tmp/xc2/build-queue/PRD-xrepo-missing.md" 'Given a digest, When `beta render` runs, Then it prints the table.'
expect_warn "$tmp/xc2/build-queue/PRD-xrepo-missing.md" foreign-surface-repo-missing "foreign-surface-repo-missing/warn"
expect_clean_no_id "$tmp/xc2/build-queue/PRD-xrepo-missing.md" failures ac-names-foreign-surface "foreign-surface-repo-missing/never-a-fail (B unknown here)"
expect_clean_no_id "$xq/PRD-xrepo-own.md" warnings foreign-surface-repo-missing "foreign-surface-repo-missing/pass (no absent repo)"
# WARN foreign-surface-source-missing: the generator cannot run -> warn, not a fail
total=$((total+1))
o="$(REPO_SURFACE_SH=/nonexistent "$LINT" --format json "$xq/PRD-xrepo-foreign.md" 2>/dev/null)"
if has_id "$o" warnings foreign-surface-source-missing && ! has_id "$o" failures ac-names-foreign-surface; then
  echo "ok: foreign-surface-source-missing/warn (check skipped, not failed)"
else echo "FAIL: missing repo-surface.sh got: $o"; fails=$((fails+1)); fi

# --explain (R5)
total=$((total+1))
o="$("$LINT" --explain ac-names-foreign-surface 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'foreign_surface_ok: \[3\]' <<<"$o" && grep -q 'foreign_surface_reasons: {' <<<"$o" \
   && grep -q '614' <<<"$o" && grep -q 'mtproof' <<<"$o"; then
  echo "ok: --explain ac-names-foreign-surface -> rule, exemption example, run 614"
else echo "FAIL: --explain ac-names-foreign-surface rc=$rc: $o"; fails=$((fails+1)); fi

# scan-prds.sh emits both keys (R4); absent -> [] / {}
total=$((total+1))
mkdir -p "$tmp/xscan/build-queue"
cp "$xq/PRD-xrepo-ok-reason.md" "$xq/PRD-xrepo-own.md" "$tmp/xscan/build-queue/"
sj="$(PRD_DIR="$tmp/xscan" BUILD_STATE_DIR="$tmp/xscan/state" "$HERE/scan-prds.sh" 2>/dev/null)"
got="$(printf '%s' "$sj" | python3 -c '
import json, sys
d = {p["slug"]: p for p in json.load(sys.stdin)}
a, b = d["xrepo-ok-reason"], d["xrepo-own"]
print(a["foreign_surface_ok"], a["foreign_surface_reasons"], b["foreign_surface_ok"], b["foreign_surface_reasons"])
' 2>&1)"
if [ "$got" = "[2] {'2': 'fixture CLI, not subject'} [] {}" ]; then
  echo "ok: scan-prds.sh emits foreign_surface_ok / foreign_surface_reasons"
else echo "FAIL: scan-prds.sh foreign_surface keys got: $got"; fails=$((fails+1)); fi

# ================================================================ shift-left (/dream Stage 1)
# Every new FAIL applies only to Drafted >= the contract cutoff (2026-10-23);
# the same finding on an older PRD is a WARN. One fail + one pass fixture per id,
# plus fixtures shaped like runs 798, 966, 1004 and migration 0131.
sl="$tmp/shiftleft"; mkdir -p "$sl/q"
git init -q --bare -b main "$sl/origin.git"
git clone -q "$sl/origin.git" "$sl/repo" 2>/dev/null
( cd "$sl/repo" && git checkout -q -b main 2>/dev/null; mkdir -p scripts && echo ok > scripts/real-proof.sh \
  && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init && git push -q origin main ) >/dev/null 2>&1
SLR="$sl/repo"

# mk_sl <file> <drafted|-> <seed|-> <extra header lines> <AC lines...>
mk_sl() {
  local f="$1" dr="$2" seed="$3" extra="$4"; shift 4
  {
    echo "- Status: queued"; echo "- build_target: shell"; echo "- build_into: $SLR"
    echo "- Vision: visions/plain.md"; echo "- Grounding: wwhtbt — visions/plain.md leaf 1 (fixture)"
    [ "$dr" != "-" ] && echo "- Drafted: $dr"
    [ "$seed" != "-" ] && echo "- Seed: $seed"
    [ -n "$extra" ] && printf '%b\n' "$extra"
    echo; echo "## Acceptance criteria"; echo
    local n=1; for ac in "$@"; do echo "$n. $ac"; n=$((n+1)); done
  } > "$f"
}
NEW=2026-10-23; OLD=2026-10-01; SEED="chain:2026-10-22-a:fam-1"
GOODAC="P0 — Given a fixture, When linted, Then it passes."

# seed-missing
mk_sl "$sl/q/PRD-sl-seed-fail.md" $NEW - "" "$GOODAC"
expect_fail "$sl/q/PRD-sl-seed-fail.md" seed-missing "seed-missing/new-PRD-fail"
mk_sl "$sl/q/PRD-sl-seed-old.md" $OLD - "" "$GOODAC"
expect_warn "$sl/q/PRD-sl-seed-old.md" seed-missing "seed-missing/old-PRD-warn-only"
expect_clean_no_id "$sl/q/PRD-sl-seed-old.md" failures seed-missing "seed-missing/old-PRD-not-fail"
mk_sl "$sl/q/PRD-sl-seed-bad.md" $NEW "somewhere:else" "" "$GOODAC"
expect_fail "$sl/q/PRD-sl-seed-bad.md" seed-missing "seed-missing/bad-form-fail"
for s in "$SEED" "traffic:abc123" "joe:2026-10-22"; do
  mk_sl "$sl/q/PRD-sl-seed-ok.md" $NEW "$s" "" "$GOODAC"
  expect_clean_no_id "$sl/q/PRD-sl-seed-ok.md" failures seed-missing "seed-missing/pass ($s)"
  expect_clean_no_id "$sl/q/PRD-sl-seed-ok.md" warnings seed-missing "seed-missing/pass-warn ($s)"
done

# premise-ac-not-live (run 966: a precondition only a human produces)
mk_sl "$sl/q/PRD-sl-premise-fail.md" $NEW "$SEED" "" \
  "P0 — Given a human has pushed a commit to prod and orch has run the chain, When linted, Then the digest names it."
expect_fail "$sl/q/PRD-sl-premise-fail.md" premise-ac-not-live "premise-ac-not-live/run-966-shape-fail"
mk_sl "$sl/q/PRD-sl-premise-ssh.md" $NEW "$SEED" "" \
  "P0 — Given the box answers on ssh orch, When linted, Then it passes."
expect_fail "$sl/q/PRD-sl-premise-ssh.md" premise-ac-not-live "premise-ac-not-live/ssh-fail"
mk_sl "$sl/q/PRD-sl-premise-url.md" $NEW "$SEED" "" \
  "P0 — Given https://mcphost.dev/health is up, When linted, Then it passes."
expect_fail "$sl/q/PRD-sl-premise-url.md" premise-ac-not-live "premise-ac-not-live/public-https-fail"
mk_sl "$sl/q/PRD-sl-premise-old.md" $OLD "$SEED" "" \
  "P0 — Given a human has pushed a commit to prod, When linted, Then it passes."
expect_warn "$sl/q/PRD-sl-premise-old.md" premise-ac-not-live "premise-ac-not-live/old-PRD-warn-only"
mk_sl "$sl/q/PRD-sl-premise-live.md" $NEW "$SEED" "" \
  "P0 — Given prod is serving, When linted, Then it passes. (Live; evidence: curl -s https://mcphost.dev/health)"
expect_clean_no_id "$sl/q/PRD-sl-premise-live.md" failures premise-ac-not-live "premise-ac-not-live/live-tail-pass"
mk_sl "$sl/q/PRD-sl-premise-local.md" $NEW "$SEED" "" \
  "P0 — Given a server on http://localhost:8080 and http://127.0.0.1:1, When linted, Then it passes."
expect_clean_no_id "$sl/q/PRD-sl-premise-local.md" failures premise-ac-not-live "premise-ac-not-live/localhost-pass"

# live-evidence-referent-missing (run 798: proof.sh named in the evidence, no AC writes it)
mk_sl "$sl/q/PRD-sl-referent-fail.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: bash scripts/proof.sh --live)"
expect_fail "$sl/q/PRD-sl-referent-fail.md" live-evidence-referent-missing "referent-missing/run-798-shape-fail"
mk_sl "$sl/q/PRD-sl-referent-old.md" $OLD "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: bash scripts/proof.sh --live)"
expect_warn "$sl/q/PRD-sl-referent-old.md" live-evidence-referent-missing "referent-missing/old-PRD-warn-only"
mk_sl "$sl/q/PRD-sl-referent-exists.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: bash scripts/real-proof.sh)"
expect_clean_no_id "$sl/q/PRD-sl-referent-exists.md" failures live-evidence-referent-missing "referent-missing/exists-at-origin-pass"
mk_sl "$sl/q/PRD-sl-referent-deliv.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it writes scripts/proof.sh as a new script." \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: bash scripts/proof.sh --live)"
expect_clean_no_id "$sl/q/PRD-sl-referent-deliv.md" failures live-evidence-referent-missing "referent-missing/other-AC-deliverable-pass"
# working-tree-only file must NOT count (never read the local working tree)
echo x > "$SLR/scripts/untracked-only.sh"
mk_sl "$sl/q/PRD-sl-referent-wt.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: bash scripts/untracked-only.sh)"
expect_fail "$sl/q/PRD-sl-referent-wt.md" live-evidence-referent-missing "referent-missing/working-tree-only-fail"
# build_into absent -> unchecked WARN, no FAIL
sed "s#^- build_into: .*#- build_into: /no/such/dir/anywhere#" "$sl/q/PRD-sl-referent-fail.md" > "$sl/q/PRD-sl-referent-nobi.md"
expect_warn "$sl/q/PRD-sl-referent-nobi.md" live-evidence-referent-unchecked "referent-unchecked/build_into-absent-warn"
expect_clean_no_id "$sl/q/PRD-sl-referent-nobi.md" failures live-evidence-referent-missing "referent-unchecked/no-fail"

# shared-counter-preassigned (migration 0131 collision)
for txt in "adds migration 0131 for the new table" "creates 0131_add_table.sql" "ships m0131" "ships V131__add_table.sql"; do
  mk_sl "$sl/q/PRD-sl-mig-fail.md" $NEW "$SEED" "" "P0 — Given a fixture, When linted, Then it $txt."
  expect_fail "$sl/q/PRD-sl-mig-fail.md" shared-counter-preassigned "shared-counter-preassigned/fail ($txt)"
done
mk_sl "$sl/q/PRD-sl-mig-old.md" $OLD "$SEED" "" "P0 — Given a fixture, When linted, Then it adds migration 0131."
expect_warn "$sl/q/PRD-sl-mig-old.md" shared-counter-preassigned "shared-counter-preassigned/old-PRD-warn-only"
mk_sl "$sl/q/PRD-sl-mig-ok.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it adds a migration using the next free migration number at land time."
expect_clean_no_id "$sl/q/PRD-sl-mig-ok.md" failures shared-counter-preassigned "shared-counter-preassigned/next-free-pass"

# cross-repo-path-in-ac (WARN)
mk_sl "$sl/q/PRD-sl-xrepo-fail.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it edits /home/jsy/wintermute/otherrepo/src/lib.rs."
expect_warn "$sl/q/PRD-sl-xrepo-fail.md" cross-repo-path-in-ac "cross-repo-path-in-ac/fail"
mk_sl "$sl/q/PRD-sl-xrepo-ok.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it edits src/lib.rs under $SLR/src."
expect_clean_no_id "$sl/q/PRD-sl-xrepo-ok.md" warnings cross-repo-path-in-ac "cross-repo-path-in-ac/own-repo-pass"

# hand-built-marker-missing: build_into basename wm-build needs `Direct-build: hand`
HBM='- Direct-build: hand (permanent rule 2026-10-05; wm-build never builds wm-build)'
mk_sl "$sl/q/PRD-sl-hand-fail.md" $NEW "$SEED" "" "$GOODAC"
sed -i "s#^- build_into: .*#- build_into: $sl/wm-build#" "$sl/q/PRD-sl-hand-fail.md"
expect_fail "$sl/q/PRD-sl-hand-fail.md" hand-built-marker-missing "hand-built-marker-missing/new-PRD-fail"
mk_sl "$sl/q/PRD-sl-hand-old.md" $OLD "$SEED" "" "$GOODAC"
sed -i "s#^- build_into: .*#- build_into: $sl/wm-build#" "$sl/q/PRD-sl-hand-old.md"
expect_warn "$sl/q/PRD-sl-hand-old.md" hand-built-marker-missing "hand-built-marker-missing/old-PRD-warn-only"
expect_clean_no_id "$sl/q/PRD-sl-hand-old.md" failures hand-built-marker-missing "hand-built-marker-missing/old-PRD-not-fail"
mk_sl "$sl/q/PRD-sl-hand-ok.md" $NEW "$SEED" "$HBM" "$GOODAC"
sed -i "s#^- build_into: .*#- build_into: $sl/wm-build#" "$sl/q/PRD-sl-hand-ok.md"
expect_clean_no_id "$sl/q/PRD-sl-hand-ok.md" failures hand-built-marker-missing "hand-built-marker-missing/marker-pass"
expect_clean_no_id "$sl/q/PRD-sl-hand-ok.md" warnings hand-built-marker-missing "hand-built-marker-missing/marker-pass-warn"
mk_sl "$sl/q/PRD-sl-hand-other.md" $NEW "$SEED" "" "$GOODAC"
expect_clean_no_id "$sl/q/PRD-sl-hand-other.md" failures hand-built-marker-missing "hand-built-marker-missing/other-repo-pass"
# fixture shaped like the queued wm-build PRDs (landing-train, box-per-run: real build_into + marker, Drafted 2026-10-10)
mk_sl "$sl/q/PRD-sl-hand-real.md" 2026-10-10 - "$HBM\n- build_priority: high" "$GOODAC"
sed -i "s#^- build_into: .*#- build_into: /home/jsy/wintermute/wm-build#" "$sl/q/PRD-sl-hand-real.md"
expect_clean_no_id "$sl/q/PRD-sl-hand-real.md" failures hand-built-marker-missing "hand-built-marker-missing/real-queued-wm-build-shape-no-fail"
sed -i '/^- Direct-build:/d' "$sl/q/PRD-sl-hand-real.md"
expect_clean_no_id "$sl/q/PRD-sl-hand-real.md" failures hand-built-marker-missing "hand-built-marker-missing/real-shape-unmarked-still-only-warn"

# build-priority-default (WARN): queued grounded wants high; creative must not be high
mk_sl "$sl/q/PRD-sl-bp-fail.md" $NEW "$SEED" "" "$GOODAC"
expect_warn "$sl/q/PRD-sl-bp-fail.md" build-priority-default "build-priority-default/queued-no-priority-warns"
mk_sl "$sl/q/PRD-sl-bp-normal.md" $NEW "$SEED" "- build_priority: normal" "$GOODAC"
expect_warn "$sl/q/PRD-sl-bp-normal.md" build-priority-default "build-priority-default/queued-normal-warns"
mk_sl "$sl/q/PRD-sl-bp-creative.md" $NEW "$SEED" "- build_priority: high" "$GOODAC"
sed -i 's/^- Grounding: .*/- Grounding: creative/' "$sl/q/PRD-sl-bp-creative.md"
expect_warn "$sl/q/PRD-sl-bp-creative.md" build-priority-default "build-priority-default/creative-high-warns"
mk_sl "$sl/q/PRD-sl-bp-ok.md" $NEW "$SEED" "- build_priority: high" "$GOODAC"
expect_clean_no_id "$sl/q/PRD-sl-bp-ok.md" warnings build-priority-default "build-priority-default/queued-high-pass"
mk_sl "$sl/q/PRD-sl-bp-creative-low.md" $NEW "$SEED" "- build_priority: low" "$GOODAC"
sed -i 's/^- Grounding: .*/- Grounding: creative/' "$sl/q/PRD-sl-bp-creative-low.md"
expect_clean_no_id "$sl/q/PRD-sl-bp-creative-low.md" warnings build-priority-default "build-priority-default/creative-low-pass"
for st in blocked building parked built; do
  mk_sl "$sl/q/PRD-sl-bp-$st.md" $NEW "$SEED" "" "$GOODAC"
  sed -i "s/^- Status: queued/- Status: $st/" "$sl/q/PRD-sl-bp-$st.md"
  expect_clean_no_id "$sl/q/PRD-sl-bp-$st.md" warnings build-priority-default "build-priority-default/status-$st-never-warns"
done
mk_sl "$sl/q/PRD-sl-bp-caps.md" $NEW "$SEED" "" "$GOODAC"
sed -i "s/^- Status: queued/- Status: Queued/" "$sl/q/PRD-sl-bp-caps.md"
expect_warn "$sl/q/PRD-sl-bp-caps.md" build-priority-default "build-priority-default/status-case-insensitive"

# later-event-without-blocked-on (WARN)
mk_sl "$sl/q/PRD-sl-later-fail.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes after the next chain run. (Live; evidence: echo ok)"
expect_warn "$sl/q/PRD-sl-later-fail.md" later-event-without-blocked-on "later-event-without-blocked-on/fail"
mk_sl "$sl/q/PRD-sl-later-ok.md" $NEW "$SEED" "- Blocked-on: chain run after merge" \
  "P0 — Given a fixture, When linted, Then it passes after the next chain run. (Live; evidence: echo ok)"
expect_clean_no_id "$sl/q/PRD-sl-later-ok.md" warnings later-event-without-blocked-on "later-event-without-blocked-on/blocked-on-pass"

# unknown-frontmatter-key (WARN)
mk_sl "$sl/q/PRD-sl-key-fail.md" $NEW "$SEED" "- Frobnicator: yes" "$GOODAC"
expect_warn "$sl/q/PRD-sl-key-fail.md" unknown-frontmatter-key "unknown-frontmatter-key/fail"
mk_sl "$sl/q/PRD-sl-key-ok.md" $NEW "$SEED" "- Falsifier: none\n- Absorbs: nothing" "$GOODAC"
expect_clean_no_id "$sl/q/PRD-sl-key-ok.md" warnings unknown-frontmatter-key "unknown-frontmatter-key/known-keys-pass"
mk_sl "$sl/q/PRD-sl-key-families.md" $NEW "$SEED" "- Seed families: a:b:c, d-e" "$GOODAC"
expect_clean_no_id "$sl/q/PRD-sl-key-families.md" warnings unknown-frontmatter-key "unknown-frontmatter-key/seed-families-known"

# fleet rule: ssh-evidence-no-path-prefix
mk_sl "$sl/q/PRD-sl-ssh-fail.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: ssh redbaron 'wm-build explain foo')"
expect_fail "$sl/q/PRD-sl-ssh-fail.md" ssh-evidence-no-path-prefix "ssh-evidence-no-path-prefix/fail"
mk_sl "$sl/q/PRD-sl-ssh-old.md" $OLD "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: ssh redbaron 'wm-build explain foo')"
expect_warn "$sl/q/PRD-sl-ssh-old.md" ssh-evidence-no-path-prefix "ssh-evidence-no-path-prefix/old-PRD-warn-only"
mk_sl "$sl/q/PRD-sl-ssh-ok.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: ssh redbaron 'export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH; wm-build explain foo')"
expect_clean_no_id "$sl/q/PRD-sl-ssh-ok.md" failures ssh-evidence-no-path-prefix "ssh-evidence-no-path-prefix/prefixed-pass"

# fleet rule: mcp-curl-no-accept (run 1004: prod /mcp curl without the Accept pair)
mk_sl "$sl/q/PRD-sl-mcp-fail.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: curl -s -X POST https://mcphost.dev/mcp -d '{}')"
expect_fail "$sl/q/PRD-sl-mcp-fail.md" mcp-curl-no-accept "mcp-curl-no-accept/run-1004-shape-fail"
mk_sl "$sl/q/PRD-sl-mcp-old.md" $OLD "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: curl -s -X POST https://mcphost.dev/mcp -d '{}')"
expect_warn "$sl/q/PRD-sl-mcp-old.md" mcp-curl-no-accept "mcp-curl-no-accept/old-PRD-warn-only"
mk_sl "$sl/q/PRD-sl-mcp-ok.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: curl -s -H 'Accept: application/json, text/event-stream' https://mcphost.dev/mcp -d '{}')"
expect_clean_no_id "$sl/q/PRD-sl-mcp-ok.md" failures mcp-curl-no-accept "mcp-curl-no-accept/accept-pair-pass"

# fleet rule: signup-without-offboard
mk_sl "$sl/q/PRD-sl-signup-fail.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: python3 probe.py signup then call a tool)"
expect_fail "$sl/q/PRD-sl-signup-fail.md" signup-without-offboard "signup-without-offboard/fail"
mk_sl "$sl/q/PRD-sl-signup-old.md" $OLD "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: python3 probe.py signup then call a tool)"
expect_warn "$sl/q/PRD-sl-signup-old.md" signup-without-offboard "signup-without-offboard/old-PRD-warn-only"
mk_sl "$sl/q/PRD-sl-signup-ok.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it passes. (Live; evidence: python3 probe.py signup then self_offboard in finally)"
expect_clean_no_id "$sl/q/PRD-sl-signup-ok.md" failures signup-without-offboard "signup-without-offboard/offboard-pass"

# fleet rule: live-evidence-off-host (480 AC 7 / 491 AC 6: a Live AC pins a client "on orch"
# and its evidence is a home path on orch, which the live judge never reads)
OHEV1='~/.local/state/mcphost-live/osreach-ac06-results.jsonl'
OHEV2='~/.local/state/mcphost-live/osmatch-ac07-results.jsonl'
OH6="P1 — Given the pinned Claude Code on orch, When it reaches the host over the OS-level path, Then every probe row is ok. (Live; evidence: cat $OHEV1)"
OH7="P1 — Given the pinned Claude Code on orch, When it matches the OS-level tool, Then every probe row is ok. (Live; evidence: cat $OHEV2)"
mk_sl "$sl/q/PRD-sl-oh-491.md" $NEW "$SEED" "" "$OH6"
expect_fail "$sl/q/PRD-sl-oh-491.md" live-evidence-off-host "live-evidence-off-host/491-AC6-verbatim-fail"
mk_sl "$sl/q/PRD-sl-oh-480.md" $NEW "$SEED" "" "$OH7"
expect_fail "$sl/q/PRD-sl-oh-480.md" live-evidence-off-host "live-evidence-off-host/480-AC7-verbatim-fail"
# the ssh escape is NOT accepted while accepted_prefixes is empty
mk_sl "$sl/q/PRD-sl-oh-ssh.md" $NEW "$SEED" "" "${OH6/cat $OHEV1/ssh orch cat $OHEV1}"
expect_fail "$sl/q/PRD-sl-oh-ssh.md" live-evidence-off-host "live-evidence-off-host/ssh-orch-prefix-still-fail (accepted_prefixes empty)"
mk_sl "$sl/q/PRD-sl-oh-sshwrong.md" $NEW "$SEED" "" "${OH6/cat $OHEV1/ssh carbon cat $OHEV1}"
expect_fail "$sl/q/PRD-sl-oh-sshwrong.md" live-evidence-off-host "live-evidence-off-host/ssh-other-host-fail"
mk_sl "$sl/q/PRD-sl-oh-abs.md" $NEW "$SEED" "" "${OH6/cat $OHEV1/cat /var/lib/mcphost-live/osreach-ac06-results.jsonl}"
expect_fail "$sl/q/PRD-sl-oh-abs.md" live-evidence-off-host "live-evidence-off-host/absolute-path-evidence-fail"
mk_sl "$sl/q/PRD-sl-oh-home.md" $NEW "$SEED" "" "${OH6/cat $OHEV1/cat \$HOME/.local/state/x.jsonl}"
expect_fail "$sl/q/PRD-sl-oh-home.md" live-evidence-off-host "live-evidence-off-host/HOME-var-evidence-fail"
# aliases, case-insensitive, possessive
mk_sl "$sl/q/PRD-sl-oh-alias.md" $NEW "$SEED" "" \
  "P1 — Given the Hub's pinned client, When it runs, Then it logs. (Live; evidence: cat /home/jsy/log.jsonl)"
expect_fail "$sl/q/PRD-sl-oh-alias.md" live-evidence-off-host "live-evidence-off-host/alias-hub-possessive-fail"
mk_sl "$sl/q/PRD-sl-oh-alias2.md" $NEW "$SEED" "" \
  "P1 — Given the pinned client on the Laptop, When it runs, Then it logs. (Live; evidence: cat ~/log.jsonl)"
expect_fail "$sl/q/PRD-sl-oh-alias2.md" live-evidence-off-host "live-evidence-off-host/alias-laptop-on-the-fail"
# passes: evidence on the build host (no host named), prod host, non-path evidence, URL evidence
mk_sl "$sl/q/PRD-sl-oh-nohost.md" $NEW "$SEED" "" \
  "P1 — Given a pinned client, When it runs, Then every probe row is ok. (Live; evidence: cat $OHEV1)"
expect_clean_no_id "$sl/q/PRD-sl-oh-nohost.md" failures live-evidence-off-host "live-evidence-off-host/no-host-named-pass"
expect_clean_no_id "$sl/q/PRD-sl-oh-nohost.md" warnings live-evidence-off-host "live-evidence-off-host/no-host-named-no-warn"
mk_sl "$sl/q/PRD-sl-oh-prod.md" $NEW "$SEED" "" \
  "P1 — Given the pinned client on prod, When it runs, Then every probe row is ok. (Live; evidence: cat $OHEV1)"
expect_clean_no_id "$sl/q/PRD-sl-oh-prod.md" failures live-evidence-off-host "live-evidence-off-host/prod-host-pass"
mk_sl "$sl/q/PRD-sl-oh-nopath.md" $NEW "$SEED" "" \
  "P1 — Given the pinned Claude Code on orch, When it runs, Then it answers. (Live; evidence: wm-build live probe osreach --json)"
expect_clean_no_id "$sl/q/PRD-sl-oh-nopath.md" failures live-evidence-off-host "live-evidence-off-host/no-path-evidence-pass"
mk_sl "$sl/q/PRD-sl-oh-url.md" $NEW "$SEED" "" \
  "P1 — Given the pinned client on orch, When it runs, Then prod answers. (Live; evidence: curl -s -H 'Accept: application/json, text/event-stream' https://mcphost.dev/mcp -d '{}')"
expect_clean_no_id "$sl/q/PRD-sl-oh-url.md" failures live-evidence-off-host "live-evidence-off-host/url-path-not-a-file-pass"
# a named build host is WARN only, even on a new PRD
mk_sl "$sl/q/PRD-sl-oh-build.md" $NEW "$SEED" "" \
  "P1 — Given the pinned client on ryzen7, When it runs, Then every probe row is ok. (Live; evidence: cat $OHEV1)"
expect_warn "$sl/q/PRD-sl-oh-build.md" live-evidence-off-host "live-evidence-off-host/named-build-host-warn"
expect_clean_no_id "$sl/q/PRD-sl-oh-build.md" failures live-evidence-off-host "live-evidence-off-host/named-build-host-never-fail"
# rollout: Drafted before the cutoff -> WARN; no Drafted line -> FAIL (fail closed)
mk_sl "$sl/q/PRD-sl-oh-old.md" 2026-10-20 "$SEED" "" "$OH6"
expect_warn "$sl/q/PRD-sl-oh-old.md" live-evidence-off-host "live-evidence-off-host/Drafted-10-20-warn-only"
expect_clean_no_id "$sl/q/PRD-sl-oh-old.md" failures live-evidence-off-host "live-evidence-off-host/Drafted-10-20-not-fail"
mk_sl "$sl/q/PRD-sl-oh-nodraft.md" - "$SEED" "" "$OH6"
expect_fail "$sl/q/PRD-sl-oh-nodraft.md" live-evidence-off-host "live-evidence-off-host/missing-Drafted-fails-closed"

# live-evidence-off-host no-drift: the lint's in-memory set (--print-live-hosts) must equal the
# contract row's clauses byte for byte; every file lives under a mktemp root this test created.
oh_row() { # $1=contract -> the row's backticked clauses joined by one space
  python3 - "$1" <<'PYR'
import re, sys
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("| `live-evidence-off-host` |"):
        cell = re.split(r"(?<!\\)\|", line.strip())[1:-1][2]
        print(" ".join(re.findall(r"`([^`]*)`", cell)))
        break
PYR
}
oh_drift() { # $1=contract -> 0 when the lint's set equals the row, 1 on drift
  [ -n "$(oh_row "$1")" ] && [ "$("$LINT" --print-live-hosts --contract "$1")" = "$(oh_row "$1")" ]
}
REAL_CONTRACT="$HERE/../build-contract.md"
total=$((total+1))
if oh_drift "$REAL_CONTRACT"; then echo "ok: live-evidence-off-host/no-drift (lint set == build-contract.md row)"
else echo "FAIL: live-evidence-off-host no-drift: row='$(oh_row "$REAL_CONTRACT")' lint='$("$LINT" --print-live-hosts)'"; fails=$((fails+1)); fi
total=$((total+1))
if [ "$("$LINT" --print-live-hosts)" = "$(oh_row "$REAL_CONTRACT")" ] && grep -q 'accepted_prefixes=$' <<<"$(oh_row "$REAL_CONTRACT")"; then
  echo "ok: live-evidence-off-host/accepted_prefixes starts empty"
else echo "FAIL: accepted_prefixes not empty in the real contract row"; fails=$((fails+1)); fi
# mutate a COPY: the lint follows the copy, so the copy drifts from the real row; the comparison must catch that
ohd="$(mktemp -d)"
sed 's/off_host=carbon,orch/off_host=carbon,orch,newhost/' "$REAL_CONTRACT" > "$ohd/contract.md"
total=$((total+1))
if oh_drift "$ohd/contract.md" && [ "$("$LINT" --print-live-hosts --contract "$ohd/contract.md")" != "$("$LINT" --print-live-hosts)" ] \
   && ! [ "$("$LINT" --print-live-hosts)" = "$(oh_row "$ohd/contract.md")" ]; then
  echo "ok: live-evidence-off-host/no-drift test fails when the row and the lint set differ"
else echo "FAIL: live-evidence-off-host drift not detected"; fails=$((fails+1)); fi
# a lint whose set is stale against the row (simulated: row edited after the set was captured)
stale="$("$LINT" --print-live-hosts)"
total=$((total+1))
if [ "$stale" != "$(oh_row "$ohd/contract.md")" ]; then echo "ok: live-evidence-off-host/stale set != edited row"
else echo "FAIL: stale set equals edited row"; fails=$((fails+1)); fi
# a row edit really changes the verdict: with newhost off-host, an AC "on newhost" fails; against the real row it is clean
mk_sl "$sl/q/PRD-sl-oh-newhost.md" $NEW "$SEED" "" \
  "P1 — Given the pinned client on newhost, When it runs, Then it logs. (Live; evidence: cat $OHEV1)"
total=$((total+1))
o1="$("$LINT" --format json --contract "$ohd/contract.md" "$sl/q/PRD-sl-oh-newhost.md" 2>/dev/null)"
if has_id "$o1" failures live-evidence-off-host; then echo "ok: live-evidence-off-host/contract row edit changes the verdict"
else echo "FAIL: contract edit not honoured: $o1"; fails=$((fails+1)); fi
expect_clean_no_id "$sl/q/PRD-sl-oh-newhost.md" failures live-evidence-off-host "live-evidence-off-host/unlisted-host-passes-against-real-row"
# accepted_prefixes widening is the one-line contract change (on a copy): ssh orch then passes
sed 's/`accepted_prefixes=`/`accepted_prefixes=ssh <host> `/' "$REAL_CONTRACT" > "$ohd/widened.md"
total=$((total+1))
o2="$("$LINT" --format json --contract "$ohd/widened.md" "$sl/q/PRD-sl-oh-ssh.md" 2>/dev/null)"
if ! has_id "$o2" failures live-evidence-off-host; then echo "ok: live-evidence-off-host/widened accepted_prefixes admits ssh <host> (copy only)"
else echo "FAIL: widened prefix not honoured: $o2"; fails=$((fails+1)); fi
total=$((total+1))
o3="$("$LINT" --format json --contract "$ohd/widened.md" "$sl/q/PRD-sl-oh-sshwrong.md" 2>/dev/null)"
if has_id "$o3" failures live-evidence-off-host; then echo "ok: live-evidence-off-host/widened prefix is host-bound (ssh carbon for orch still fails)"
else echo "FAIL: widened prefix not host-bound: $o3"; fails=$((fails+1)); fi
rm -rf "$ohd"
total=$((total+1))
o="$("$LINT" --explain live-evidence-off-host 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '491' <<<"$o" && grep -q 'accepted_prefixes' <<<"$o"; then echo "ok: --explain live-evidence-off-host"; else echo "FAIL: --explain live-evidence-off-host rc=$rc: $o"; fails=$((fails+1)); fi

# fleet rule: generator-set-member (WARN; build_into basename must be the repo in generator_sets)
mkdir -p "$sl/mcphost"; ( cd "$sl/mcphost" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m i ) >/dev/null 2>&1
mk_sl "$sl/q/PRD-sl-gen-fail.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it adds a new member to ERROR_CODES by hand."
sed -i "s#^- build_into: .*#- build_into: $sl/mcphost#" "$sl/q/PRD-sl-gen-fail.md"
expect_warn "$sl/q/PRD-sl-gen-fail.md" generator-set-member "generator-set-member/fail"
mk_sl "$sl/q/PRD-sl-gen-ok.md" $NEW "$SEED" "" \
  "P0 — Given a fixture, When linted, Then it adds a new member to ERROR_CODES via the error_registry generator."
sed -i "s#^- build_into: .*#- build_into: $sl/mcphost#" "$sl/q/PRD-sl-gen-ok.md"
expect_clean_no_id "$sl/q/PRD-sl-gen-ok.md" warnings generator-set-member "generator-set-member/names-generator-pass"

# live-ac-referent-args (run 491 AC 6: placeholder run_id handed to host_import dry_run); ERROR on any Drafted date
LREF_FAIL='P0 — Given AC 1 and AC 5, the pinned Claude Code on orch (2.1.293 as of 2026-10-22), prod /mcp and a disposable `synthorg` tenant, When it calls `host_import` with `dry_run: true` and AC 1'"'"'s synthesized required arguments, then `host_doctor`, Then 2 `tool_result` blocks, none "Structured content does not match" or `is_error` (Live; evidence: `~/.local/state/mcphost-live/osreach-ac06-results.jsonl` printing `tool_results=2 mismatch=0 is_error=0 unreached=<n> cap=<m>`)'
LREF_PASS='P0 — Given the pinned Claude Code on orch, prod /mcp and a disposable `synthorg` tenant, When it calls `host_export` and captures the `run_id` it returns, then calls `host_import` with `dry_run: true` and that `run_id`, then `host_doctor`, Then 3 `tool_result` blocks, none "Structured content does not match", is_error=0 on all three (Live; evidence: `~/.local/state/mcphost-live/osreach-ac06b-results.jsonl` printing `tool_results=3 mismatch=0 is_error=0 export_run_id=<id> unreached=<n> cap=<m>`)'
mk_sl "$sl/q/PRD-sl-lref-fail.md" $NEW "$SEED" "" "$GOODAC" "$GOODAC" "$GOODAC" "$GOODAC" "$GOODAC" "$LREF_FAIL"
expect_fail "$sl/q/PRD-sl-lref-fail.md" live-ac-referent-args "live-ac-referent-args/case-a-run-491-ac6-fail"
total=$((total+1))
lref_json="$(json_of "$sl/q/PRD-sl-lref-fail.md")"
if printf '%s' "$lref_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)[0]
ok = [f for f in d['failures'] if f['id'] == 'live-ac-referent-args' and 'AC 6 ' in f['message'] and 'no schema access' in f['message']]
sys.exit(0 if ok else 1)
"; then
  echo "ok: live-ac-referent-args/case-a names AC 6 and says phrase-detected"
else echo "FAIL: live-ac-referent-args message does not name AC 6 / phrase-detected: $lref_json"; fails=$((fails+1)); fi
mk_sl "$sl/q/PRD-sl-lref-old.md" $OLD "$SEED" "" "$LREF_FAIL"
expect_fail "$sl/q/PRD-sl-lref-old.md" live-ac-referent-args "live-ac-referent-args/error-not-warn-on-old-PRD"
mk_sl "$sl/q/PRD-sl-lref-pass.md" $NEW "$SEED" "" "$GOODAC" "$GOODAC" "$GOODAC" "$GOODAC" "$GOODAC" "$LREF_PASS"
expect_clean_no_id "$sl/q/PRD-sl-lref-pass.md" failures live-ac-referent-args "live-ac-referent-args/case-b-successor-shape-pass"
mk_sl "$sl/q/PRD-sl-lref-literal.md" $NEW "$SEED" "" \
  'P0 — Given prod /mcp, When it calls `host_import` with `run_id: "x"`, Then the call answers. (Live; evidence: `~/.local/state/mcphost-live/lref-c.jsonl` printing `ok=1`)'
expect_fail "$sl/q/PRD-sl-lref-literal.md" live-ac-referent-args "live-ac-referent-args/case-c-literal-run_id-fail"
mk_sl "$sl/q/PRD-sl-lref-nonlive.md" $NEW "$SEED" "" \
  'P0 — Given a fixture, When the lint is called with AC 1'"'"'s synthesized required arguments, Then it exits 0.'
expect_clean_no_id "$sl/q/PRD-sl-lref-nonlive.md" failures live-ac-referent-args "live-ac-referent-args/case-d-non-Live-AC-pass"
mk_sl "$sl/q/PRD-sl-lref-givenac.md" $NEW "$SEED" "" \
  'P0 — Given AC 1, When it calls `host_import` with AC 1'"'"'s placeholder arguments, Then the call answers. (Live; evidence: `~/.local/state/mcphost-live/lref-e.jsonl` printing `ok=1`)'
expect_fail "$sl/q/PRD-sl-lref-givenac.md" live-ac-referent-args "live-ac-referent-args/case-e-given-AC-N-alone-fail"
mk_sl "$sl/q/PRD-sl-lref-gap.md" $NEW "$SEED" "" \
  'P0 — Given prod /mcp, When it calls `host_import` with `tenant: "acme"`, Then the call answers. (Live; evidence: `~/.local/state/mcphost-live/lref-f.jsonl` printing `ok=1`)'
expect_clean_no_id "$sl/q/PRD-sl-lref-gap.md" failures live-ac-referent-args "live-ac-referent-args/case-f-known-gap-non-id-key-not-caught"
mk_sl "$sl/q/PRD-sl-lref-captured.md" $NEW "$SEED" "" "$GOODAC" "$GOODAC" "$GOODAC" "$GOODAC" \
  'P0 — Given AC 5, prod /mcp, When it calls `host_import` with `dry_run: true` and the `run_id` captured in AC 5'"'"'s evidence, Then the call answers. (Live; evidence: `~/.local/state/mcphost-live/lref-g.jsonl` printing `ok=1`)'
expect_clean_no_id "$sl/q/PRD-sl-lref-captured.md" failures live-ac-referent-args "live-ac-referent-args/case-g-captured-value-in-other-AC-pass"
mk_sl "$sl/q/PRD-sl-lref-url.md" $NEW "$SEED" "" \
  'P0 — Given prod /mcp, When it calls `host_import` with `url: "https://example.org/x.json"`, Then the call answers. (Live; evidence: `~/.local/state/mcphost-live/lref-h.jsonl` printing `ok=1`)'
expect_clean_no_id "$sl/q/PRD-sl-lref-url.md" failures live-ac-referent-args "live-ac-referent-args/real-url-literal-pass"
mk_sl "$sl/q/PRD-sl-lref-urlph.md" $NEW "$SEED" "" \
  'P0 — Given prod /mcp, When it calls `host_import` with `url: "x"`, Then the call answers. (Live; evidence: `~/.local/state/mcphost-live/lref-i.jsonl` printing `ok=1`)'
expect_fail "$sl/q/PRD-sl-lref-urlph.md" live-ac-referent-args "live-ac-referent-args/bare-placeholder-url-fail"

# --explain covers the new ids; contract rows are the source (no strings in code)
total=$((total+1))
o="$("$LINT" --explain premise-ac-not-live 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '966' <<<"$o"; then echo "ok: --explain premise-ac-not-live"; else echo "FAIL: --explain premise-ac-not-live rc=$rc: $o"; fails=$((fails+1)); fi

total=$((total+1))
o="$("$LINT" --explain hand-built-marker-missing 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Direct-build: hand' <<<"$o"; then echo "ok: --explain hand-built-marker-missing"; else echo "FAIL: --explain hand-built-marker-missing rc=$rc: $o"; fails=$((fails+1)); fi
total=$((total+1))
o="$("$LINT" --explain build-priority-default 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'creative' <<<"$o"; then echo "ok: --explain build-priority-default"; else echo "FAIL: --explain build-priority-default rc=$rc: $o"; fails=$((fails+1)); fi

# --------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  echo "SELFTEST FAILED ($fails/$total checks)"
  exit 1
fi
echo "SELFTEST PASSED ($total checks)"
