#!/usr/bin/env bash
# tests/fixtures/mainpush-common.sh — shared fixture builder for the
# mainpush_ac*.sh selftests (PRD-build-main-push-gate). Builds a tiny,
# real git+cargo repo that stands in for mcphost: a bare "origin", a
# working clone with `agent/intent-card.json`, `extended-gates.toml`, and
# `.buildloop/ci-equivalent.toml` mapping `agent/intent-card.json` ->
# `cargo test --test intent_card` — a REAL, minimal (std-only, no deps)
# cargo test target so `main-push-gate.sh`'s resolved check is a genuine
# subprocess run, not a stub, and rc=101 on a failing `#[test]` is the
# real cargo convention this PRD's AC1 names.
#
# Must be sourced, not executed. Callers: tests/mainpush_ac*.sh.
set -uo pipefail

MAINPUSH_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAINPUSH_SCRIPTS="$(cd "$MAINPUSH_HERE/../scripts" && pwd)"
MAINPUSH_GATE="$MAINPUSH_SCRIPTS/main-push-gate.sh"

mainpush_fail=0
mainpush_expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    echo "ok  $label"
  else
    echo "FAIL $label ($cond)" >&2
    mainpush_fail=1
  fi
}

# mainpush_mkfixture <workdir> -> prints the working clone's path on stdout.
# Leaves a bare "origin" at <workdir>/origin.git and a clone at
# <workdir>/work, both at a GREEN gated head (card matches extended-gates.toml).
mainpush_mkfixture() {
  local root="${1:?mainpush_mkfixture: missing workdir}"
  local origin="$root/origin.git" work="$root/work"
  mkdir -p "$root"
  git init --bare -q "$origin"
  git clone -q "$origin" "$work"

  (
    cd "$work"
    git config user.name "Fixture Bot"
    git config user.email "fixture@example.invalid"

    mkdir -p agent .buildloop tests
    cat > Cargo.toml <<'EOF'
[package]
name = "mainpush-fixture"
version = "0.1.0"
edition = "2021"

[lib]
path = "src/lib.rs"
EOF
    mkdir -p src
    echo "// fixture crate" > src/lib.rs

    # A real, std-only cargo test target: fails when agent/intent-card.json's
    # prd_source basename doesn't match extended-gates.toml's prd_path value
    # -- exactly the class of drift AC1 replays (3c11214).
    cat > tests/intent_card.rs <<'EOF'
use std::fs;

fn read_field(path: &str, key: &str) -> String {
    let text = fs::read_to_string(path).unwrap_or_default();
    for line in text.lines() {
        let needle = format!("\"{key}\"");
        if let Some(idx) = line.find(&needle) {
            let rest = &line[idx + needle.len()..];
            if let Some(colon) = rest.find(':') {
                let rest = rest[colon + 1..].trim().trim_matches(',');
                let rest = rest.trim_matches('"');
                return rest.to_string();
            }
        }
    }
    String::new()
}

fn base(p: &str) -> String {
    p.rsplit('/').next().unwrap_or(p).to_string()
}

#[test]
fn intent_card_prd_source_matches_extended_gates() {
    let card_prd = read_field("agent/intent-card.json", "prd_source");
    let gates_text = fs::read_to_string("extended-gates.toml").unwrap_or_default();
    let mut gates_prd = String::new();
    for line in gates_text.lines() {
        if let Some(rest) = line.trim().strip_prefix("prd_path") {
            let rest = rest.trim().trim_start_matches('=').trim().trim_matches('"');
            gates_prd = rest.to_string();
        }
    }
    assert_eq!(
        base(&card_prd),
        base(&gates_prd),
        "intent-card.json prd_source ({card_prd}) does not match extended-gates.toml prd_path ({gates_prd})"
    );
}
EOF

    cat > agent/intent-card.json <<'EOF'
{
  "prd_source": "PRD-fixture-green.md",
  "intent_slug": "fixture-green"
}
EOF
    cat > extended-gates.toml <<'EOF'
prd_path = "PRD-fixture-green.md"
EOF
    echo "fixture PRD" > PRD-fixture-green.md

    cat > .buildloop/ci-equivalent.toml <<'EOF'
[delta]
"agent/intent-card.json" = "cargo test --test intent_card"

[default]
command = "cargo test --workspace"
EOF

    git add -A
    git commit -q -m "fixture: green gated head"
    git push -q origin HEAD:main 2>/dev/null || git push -q origin HEAD:master
  )
  echo "$work"
}

# mainpush_drift_commit <work> -> commits the 3c11214-style drift (card
# rewritten to name a DIFFERENT PRD than extended-gates.toml) on top of
# whatever HEAD currently is. Prints the new HEAD sha.
mainpush_drift_commit() {
  local work="${1:?mainpush_drift_commit: missing work dir}"
  (
    cd "$work"
    cat > agent/intent-card.json <<'EOF'
{
  "prd_source": "PRD-fixture-drifted.md",
  "intent_slug": "fixture-drifted"
}
EOF
    git add -A
    git commit -q -m "agent: refresh intent card for fixture-drifted (drift)"
  )
  git -C "$work" rev-parse HEAD
}

# mainpush_matching_commit <work> -> commits a card refresh that STILL
# matches extended-gates.toml (the green refresh case, AC2). Prints the
# new HEAD sha.
mainpush_matching_commit() {
  local work="${1:?mainpush_matching_commit: missing work dir}"
  (
    cd "$work"
    cat > agent/intent-card.json <<'EOF'
{
  "prd_source": "PRD-fixture-green.md",
  "intent_slug": "fixture-green-refreshed"
}
EOF
    git add -A
    git commit -q -m "agent: refresh intent card for fixture-green (no drift)"
  )
  git -C "$work" rev-parse HEAD
}
