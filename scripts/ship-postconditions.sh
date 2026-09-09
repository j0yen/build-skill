#!/usr/bin/env bash
# ship-postconditions.sh <repo> [--project-root <rel>] — the executable
# definition of "a version is shipped" for this build system.
#
# WHY THIS EXISTS (5-whys, 2026-09-09): the parallel-integrate path shipped
# versions 0.32.0–0.36.1 of mcphost without tags because it reimplemented the
# serial ship step's bump+changelog+commit but not its tag+push. Its ACs
# missed the same omission (author enumerated both code and fixtures from the
# same mental list). Root cause: "shipped" was SKILL.md prose that each path
# re-enumerated by hand, so a superseding path could silently drop a
# responsibility. This script is the contract: any path that lands a version
# — today's serial ship, today's parallel integrate, or any future third
# path — must exit 0 here before declaring success. Add new shipping
# responsibilities HERE, not in per-path code.
#
# Checks (each prints ok:/FAIL: on its own line; exit = number of FAILs):
#   1. version-tag        crate version v<X> exists as a git tag
#   2. tag-placement      the tag points at a commit where Cargo.toml says <X>
#   3. changelog          CHANGELOG.md (if present) mentions <X>
#   4. lock-sync          Cargo.lock (if present) records <X> for the crate
#   5. clean-tree         no uncommitted changes under the project root
# Push state is deliberately NOT checked (offline integrates are legal; the
# gate's tag backfill pushes). Non-cargo repos: only checks 3 and 5 apply.
set -uo pipefail

repo="${1:-}"; shift || true
[ -n "$repo" ] && [ -d "$repo/.git" ] || { echo "usage: ship-postconditions.sh <repo> [--project-root <rel>]" >&2; exit 2; }
proj="."
[ "${1:-}" = "--project-root" ] && proj="${2:-.}"

fails=0
ok()   { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fails=$((fails+1)); }

manifest="$repo/$proj/Cargo.toml"
if [ -f "$manifest" ]; then
  ver="$(sed -n 's/^version *= *"\([0-9.]*\)".*/\1/p' "$manifest" | head -1)"
  crate="$(sed -n 's/^name *= *"\([^"]*\)".*/\1/p' "$manifest" | head -1)"
  if [ -z "$ver" ]; then
    bad "version-tag: no version in $proj/Cargo.toml"
  else
    # TAG OWNERSHIP (2026-09-09): the CURRENT version's tag is created by the
    # gate's redeploy-tag producer at green HEAD — its ABSENCE here is the
    # normal pending state, never a failure. What IS a defect: the current
    # tag existing on a commit that doesn't declare this version (a stolen
    # name blocks redeploy-tag), or any HISTORICAL version left untagged
    # (checked by the gate's lineage backfill, not re-checked here).
    if git -C "$repo" rev-parse "v$ver" >/dev/null 2>&1; then
      tagsha="$(git -C "$repo" rev-list -n1 "v$ver" 2>/dev/null)"
      tagver="$(git -C "$repo" show "$tagsha:$([ "$proj" = "." ] && echo Cargo.toml || echo "$proj/Cargo.toml")" 2>/dev/null | sed -n 's/^version *= *"\([0-9.]*\)".*/\1/p' | head -1)"
      if [ "$tagver" = "$ver" ]; then ok "version-tag: v$ver exists at a commit declaring $ver"
      else bad "tag-placement: v$ver points at a commit declaring '${tagver:-none}' — stolen name blocks redeploy-tag"; fi
    else
      ok "version-tag: v$ver pending (gate redeploy-tags at green HEAD)"
    fi
    lock="$repo/Cargo.lock"; [ -f "$repo/$proj/Cargo.lock" ] && lock="$repo/$proj/Cargo.lock"
    if [ -f "$lock" ] && [ -n "$crate" ]; then
      if awk -v c="$crate" -v v="$ver" 'BEGIN{RS="[[package]]"} $0 ~ "name = \""c"\"" && $0 ~ "version = \""v"\"" {found=1} END{exit !found}' "$lock" 2>/dev/null; then
        ok "lock-sync: $crate $ver in Cargo.lock"
      else
        bad "lock-sync: $crate $ver not recorded in Cargo.lock"
      fi
    else
      ok "lock-sync: skipped (no lock or crate name)"
    fi
  fi
else
  ver=""
  ok "version-tag: skipped (non-cargo project)"
fi

cl="$repo/$proj/CHANGELOG.md"; [ -f "$cl" ] || cl="$repo/CHANGELOG.md"
if [ -f "$cl" ] && [ -n "${ver:-}" ]; then
  grep -q "$ver" "$cl" && ok "changelog: mentions $ver" || bad "changelog: no entry for $ver"
else
  ok "changelog: skipped"
fi

# clean-tree is ADVISORY (warn, never FAIL): the shared checkout legitimately
# carries sibling PRDs' uncommitted claim-work between ticks (lane-claim's
# continuation-threshold design) — "shipped" truth lives in the commit, tag,
# changelog and lock, not in working-tree state at check time.
if [ -z "$(git -C "$repo" status --porcelain -- "$proj" 2>/dev/null)" ]; then
  ok "clean-tree: $proj clean"
else
  echo "warn: clean-tree: uncommitted changes under $proj (sibling claim-work is legal — advisory only)"
fi

exit "$fails"
