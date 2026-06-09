#!/usr/bin/env bash
# lib-register.sh — append-only lib.rs module + re-export registration helper
#
# Usage:
#   lib-register.sh <repo_path> <module_name> [<pub_use_line>...]
#
# Appends (idempotently) at the // @build:modules end-of-list anchor:
#   pub mod <module_name>;
#
# And, for each <pub_use_line> argument, appends at the // @build:reexports
# end-of-list anchor:
#   pub use <module_name>::{...};
#
# On first call in a repo that lacks the anchor comments, seeds both anchors
# in-place at the end of the existing `pub mod` block (and after the existing
# `pub use` block). Second run detects the anchors and does not re-seed.
#
# Exit codes:
#   0  — success (appended or already registered — no-op)
#   1  — usage / argument error
#   2  — lib.rs not found or is not writable
#   3  — lib.rs has no recognizable `pub mod` block; cannot seed (use opt-in
#          anchors manually, or convert the crate to the convention first)
#
# The module / re-export anchor approach ensures two branches adding *different*
# modules produce non-overlapping diffs at the end of their respective regions,
# which git auto-merges cleanly.
#
# This is the lib.rs analogue of cli-register.sh (// @build:subcommands).
# See SKILL.md "Worktree isolation" section for when to use it.

set -euo pipefail

ANCHOR_MOD="// @build:modules"
ANCHOR_REEX="// @build:reexports"

die() { local code="$1"; shift; echo "lib-register: $*" >&2; exit "$code"; }

usage() {
    cat >&2 <<'EOF'
usage: lib-register.sh <repo_path> <module_name> [<pub_use_line>...]

Arguments:
  repo_path     Absolute path to the git repo root (must contain src/lib.rs)
  module_name   Rust module name to register (e.g. "probe")
  pub_use_line  (optional, repeatable) pub use lines to append, e.g.:
                  "probe::{ProbeReport, Severity}"
                These are appended verbatim as:
                  pub use probe::{ProbeReport, Severity};

Examples:
  # Register a module only (no re-exports):
  lib-register.sh /home/jsy/wintermute/mylib probe

  # Register a module and its public types:
  lib-register.sh /home/jsy/wintermute/mylib probe "probe::{ProbeReport, Severity}"

Exit codes: 0=ok/noop  1=usage  2=lib.rs missing/unwritable  3=no pub mod block
EOF
    exit 1
}

# ── arg check ────────────────────────────────────────────────────────────────
[ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] && usage
[ $# -lt 2 ] && usage

REPO="$1"
MOD="$2"
shift 2
REEX_ARGS=("$@")   # remaining args are pub_use paths

# ── locate lib.rs ─────────────────────────────────────────────────────────────
LIBRS="$REPO/src/lib.rs"
[ -f "$LIBRS" ] || die 2 "lib.rs not found: $LIBRS"
[ -w "$LIBRS" ] || die 2 "lib.rs not writable: $LIBRS"

# ── seed anchors if missing ───────────────────────────────────────────────────
has_mod_anchor()  { grep -qxF "$ANCHOR_MOD"  "$LIBRS"; }
has_reex_anchor() { grep -qxF "$ANCHOR_REEX" "$LIBRS"; }

seed_anchor_mod() {
    # Insert // @build:modules after the last consecutive `pub mod ...;` line.
    # We find the last line number of any `pub mod ...;` line in the file and
    # insert the anchor right after it (using a temp-file swap, not sed -i).
    local last_mod_line
    last_mod_line=$(grep -n '^\s*pub mod ' "$LIBRS" | tail -1 | cut -d: -f1) || true
    if [ -z "$last_mod_line" ]; then
        # No pub mod block at all — cannot seed safely.
        die 3 "lib.rs has no 'pub mod' block; cannot seed $ANCHOR_MOD. Add the anchor manually or adopt the convention first."
    fi
    local tmp; tmp="$(mktemp "${LIBRS}.seed.XXXXXXXX")"
    awk -v line="$last_mod_line" -v anchor="$ANCHOR_MOD" '
        NR == line { print; print anchor; next }
        { print }
    ' "$LIBRS" > "$tmp"
    mv "$tmp" "$LIBRS"
    echo "lib-register: seeded $ANCHOR_MOD after line $last_mod_line" >&2
}

seed_anchor_reex() {
    # Insert // @build:reexports after the last consecutive `pub use ...;` line.
    # If there is no pub use block yet, insert it right after the @build:modules
    # anchor (which must already exist at this point).
    local last_reex_line
    last_reex_line=$(grep -n '^\s*pub use ' "$LIBRS" | tail -1 | cut -d: -f1) || true
    local tmp; tmp="$(mktemp "${LIBRS}.seed.XXXXXXXX")"
    if [ -n "$last_reex_line" ]; then
        awk -v line="$last_reex_line" -v anchor="$ANCHOR_REEX" '
            NR == line { print; print anchor; next }
            { print }
        ' "$LIBRS" > "$tmp"
        echo "lib-register: seeded $ANCHOR_REEX after line $last_reex_line" >&2
    else
        # No pub use lines at all; insert anchor right after @build:modules.
        local mod_anchor_line
        mod_anchor_line=$(grep -n "^${ANCHOR_MOD}$" "$LIBRS" | tail -1 | cut -d: -f1)
        awk -v line="$mod_anchor_line" -v anchor="$ANCHOR_REEX" '
            NR == line { print; print ""; print anchor; next }
            { print }
        ' "$LIBRS" > "$tmp"
        echo "lib-register: seeded $ANCHOR_REEX after $ANCHOR_MOD (no pub use block yet)" >&2
    fi
    mv "$tmp" "$LIBRS"
}

if ! has_mod_anchor; then
    seed_anchor_mod
fi

# Only seed reexports anchor if caller will use it, or pre-seed for consistency.
# We always seed it so future callers don't need a separate seed pass.
if ! has_reex_anchor; then
    seed_anchor_reex
fi

# ── append pub mod (idempotent) ───────────────────────────────────────────────
MOD_LINE="pub mod ${MOD};"
if grep -qxF "$MOD_LINE" "$LIBRS"; then
    echo "lib-register: $MOD_LINE already present — no-op" >&2
else
    # Insert MOD_LINE just before the anchor line (so anchor stays at end of block).
    local_tmp="$(mktemp "${LIBRS}.mod.XXXXXXXX")"
    awk -v anchor="$ANCHOR_MOD" -v modline="$MOD_LINE" '
        $0 == anchor { print modline }
        { print }
    ' "$LIBRS" > "$local_tmp"
    mv "$local_tmp" "$LIBRS"
    echo "lib-register: appended: $MOD_LINE" >&2
fi

# ── append pub use lines (idempotent) ─────────────────────────────────────────
for reex in "${REEX_ARGS[@]+"${REEX_ARGS[@]}"}"; do
    REEX_LINE="pub use ${reex};"
    if grep -qxF "$REEX_LINE" "$LIBRS"; then
        echo "lib-register: $REEX_LINE already present — no-op" >&2
    else
        local_tmp="$(mktemp "${LIBRS}.reex.XXXXXXXX")"
        awk -v anchor="$ANCHOR_REEX" -v reexline="$REEX_LINE" '
            $0 == anchor { print reexline }
            { print }
        ' "$LIBRS" > "$local_tmp"
        mv "$local_tmp" "$LIBRS"
        echo "lib-register: appended: $REEX_LINE" >&2
    fi
done

exit 0
