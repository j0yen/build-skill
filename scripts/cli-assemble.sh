#!/usr/bin/env bash
# cli-assemble.sh — assemble CLI dispatcher from per-subcommand sidecar files
#
# Usage:
#   cli-assemble.sh <repo_path>
#
# Reads all src/register/*.register files in alphabetical order and writes
# the generated enum variants and match arms into src/main.rs between the
# anchor comments:
#   // @build:subcommands-start ... // @build:subcommands-end
#
# This is the second step of the two-step merge-safe workflow:
#   1. cli-register.sh   (per-branch: creates one new sidecar file)
#   2. cli-assemble.sh   (post-integrate: rewrites the dispatcher block)
#
# If src/main.rs has no @build:subcommands-start anchor, this script exits 0
# (no-op for repos that haven't adopted the convention).
#
# Exit codes:
#   0  — success (assembled or no-op)
#   1  — usage error
#   2  — repo path not found

set -euo pipefail

die() { local code="$1"; shift; echo "cli-assemble: $*" >&2; exit "$code"; }

[ $# -lt 1 ] && { echo "usage: cli-assemble.sh <repo_path>" >&2; exit 1; }
REPO="$1"
[ -d "$REPO" ] || die 2 "repo path not found: $REPO"

MAINRS="$REPO/src/main.rs"
REGISTER_DIR="$REPO/src/register"

# No-op if main.rs doesn't have the anchors (back-compat)
[ -f "$MAINRS" ] || { echo "cli-assemble: no src/main.rs — no-op" >&2; exit 0; }
grep -qF "// @build:subcommands-start" "$MAINRS" || {
    echo "cli-assemble: no @build:subcommands-start anchor in main.rs — no-op" >&2
    exit 0
}

# No sidecar files: clear the generated block
if [ ! -d "$REGISTER_DIR" ] || [ -z "$(ls "$REGISTER_DIR"/*.register 2>/dev/null)" ]; then
    echo "cli-assemble: no .register sidecars found — clearing generated block" >&2
fi

# Collect subcommands from sidecar files (alphabetical order)
enum_variants=""
match_arms=""

for sidecar in $(ls "$REGISTER_DIR"/*.register 2>/dev/null | sort); do
    subcmd=""
    module=""
    while IFS='=' read -r key val; do
        case "$key" in
            subcmd) subcmd="$val" ;;
            module) module="$val" ;;
        esac
    done < <(grep -v '^#' "$sidecar")
    [ -z "$subcmd" ] || [ -z "$module" ] && continue
    enum_variants="${enum_variants}    ${subcmd},\n"
    match_arms="${match_arms}        Command::${subcmd} => ${module}::run(&args),\n"
done

# Rewrite the block between the anchors in main.rs
tmp="$(mktemp "${MAINRS}.assemble.XXXXXXXX")"
awk -v enum_v="$enum_variants" -v match_a="$match_arms" '
    /\/\/ @build:subcommands-start/ {
        print
        skip=1
        # Print generated variants (enum or match arms depending on position)
        printf "%s", enum_v
        next
    }
    /\/\/ @build:subcommands-end/ { skip=0; print; next }
    skip { next }
    { print }
' "$MAINRS" > "$tmp"
mv "$tmp" "$MAINRS"
echo "cli-assemble: assembled dispatcher in $MAINRS" >&2
exit 0
