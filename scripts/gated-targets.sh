#!/usr/bin/env bash
# gated-targets.sh — registry of repos any rust-extend PRD in the corpus
# declares as its `build_into` (PRD-build-cross-repo-commit-gate
# requirement 1).
#
# A shell/hooks/config PRD that commits into one of these repos, when its
# OWN build_into is a DIFFERENT repo, is a cross-repo write: the loop
# commit that mints it never ran through the target repo's own
# rust-extend gate at all (the 2026-09-16 incident this PRD's grounding
# names — a build-skill shell PRD wrote `.buildloop/ci-equivalent.toml`
# straight into mcphost, landed through a green-CI PR, and turned every
# mcphost branch's vti-plan red because the commit was unrouted in
# agent/proof-lanes.toml). worktree-extend.sh's `land` and
# main-push-gate.sh both consult this registry to decide whether a commit
# needs the target repo's branch gate before it can land/push — this
# script is only the REGISTRY lookup; it never runs a gate itself.
#
# Usage:
#   gated-targets.sh list [--explain]
#       One realpath per line, deduped, sorted — every distinct build_into
#       of a rust-extend PRD across build-queue/, built-prds/, parked/
#       (read from the manifest CACHE, never re-scanning the PRD corpus
#       itself — the manifest already carries build_into per PRD, see
#       build-contract.md).
#       --explain (P2, requirement 7): `<path>  <slug1>,<slug2>,...`
#       instead of a bare path — which PRDs make each path gated.
#   gated-targets.sh is-gated <path>
#       Exit 0 iff realpath(<path>) is one of the above; 1 otherwise.
#       <path> need not exist locally (never a crash) — this is the same
#       "build_into commonly lives on a different fleet host" case
#       prd-lint.sh's build-into-not-found check already tolerates.
#
# Manifest source: $BUILD_MANIFEST (default <skill-dir>/state/manifest.json,
# same convention as manifest-set.sh/chain-guard.sh).
#
# Caching (P1, requirement 5): the parsed target set is cached at
# state/gated-targets-cache.json (override: $GATED_TARGETS_CACHE), keyed
# on the manifest file's own mtime+size. A cache whose key still matches
# the CURRENT manifest is reused without re-parsing the whole corpus (a
# hit); any mismatch, or no cache file yet, recomputes and rewrites it (a
# miss). Every call journals exactly one `gated-targets  cache  hit|miss`
# line (scripts/lib/journal.sh) so "the manifest is parsed once per tick"
# (AC6) is auditable from the journal instead of merely asserted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
MANIFEST="${BUILD_MANIFEST:-$STATE_DIR/manifest.json}"
CACHE="${GATED_TARGETS_CACHE:-$STATE_DIR/gated-targets-cache.json}"

# shellcheck source=lib/journal.sh
source "$HERE/lib/journal.sh"

die() { echo "gated-targets: $2" >&2; exit "$1"; }

usage() { echo "usage: gated-targets.sh {list [--explain]|is-gated <path>}" >&2; }

[ -f "$MANIFEST" ] || die 2 "no manifest at $MANIFEST"
command -v jq >/dev/null 2>&1 || die 2 "jq not on \$PATH"
command -v python3 >/dev/null 2>&1 || die 2 "python3 not on \$PATH"

# _cache_key -> "<mtime>:<size>" of $MANIFEST, the cache invalidation key.
_cache_key() {
  local mtime size
  mtime="$(stat -c %Y "$MANIFEST" 2>/dev/null || stat -f %m "$MANIFEST" 2>/dev/null)"
  size="$(stat -c %s "$MANIFEST" 2>/dev/null || stat -f %z "$MANIFEST" 2>/dev/null)"
  printf '%s:%s\n' "$mtime" "$size"
}

# _compute -> (re)writes $CACHE as {key, targets:[{path, slugs:[...]}]}.
# jq pulls the raw (slug, build_into) pairs for rust-extend PRDs; python3
# does the realpath-resolution + grouping (jq itself has no realpath).
_compute() {
  local key; key="$(_cache_key)"
  jq -n --slurpfile m "$MANIFEST" '
    ($m[0].prds // {}) as $prds
    | [ $prds | to_entries[]
        | select(.value.build_target == "rust-extend")
        | select(.value.build_into != null)
        | {slug: .key, path: .value.build_into} ]
  ' > "$CACHE.raw.$$"
  python3 - "$CACHE.raw.$$" "$CACHE" "$key" <<'PY'
import json, os, sys

raw_path, out_path, key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(raw_path, encoding="utf-8") as fh:
    raw = json.load(fh)

groups = {}
for r in raw:
    p = r.get("path")
    if not p:
        continue
    try:
        rp = os.path.realpath(p)
    except Exception:
        rp = p
    groups.setdefault(rp, set()).add(r["slug"])

targets = [{"path": p, "slugs": sorted(s)} for p, s in sorted(groups.items())]
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump({"key": key, "targets": targets}, fh)
PY
  rm -f "$CACHE.raw.$$"
}

# _ensure_cache -> journals hit/miss, (re)computing $CACHE if stale/absent.
_ensure_cache() {
  local want; want="$(_cache_key)"
  if [ -f "$CACHE" ]; then
    local have; have="$(jq -r '.key // empty' "$CACHE" 2>/dev/null)"
    if [ "$have" = "$want" ]; then
      journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  gated-targets  cache  hit  (key=$want)"
      return 0
    fi
  fi
  mkdir -p "$STATE_DIR"
  _compute
  journal_line "$(date -u +%Y-%m-%dT%H:%M:%SZ)  gated-targets  cache  miss  (key=$want)"
}

cmd_list() {
  local explain=false
  [ "${1:-}" = "--explain" ] && explain=true
  _ensure_cache
  if $explain; then
    jq -r '.targets[] | "\(.path)  \(.slugs | join(","))"' "$CACHE"
  else
    jq -r '.targets[].path' "$CACHE"
  fi
}

cmd_is_gated() {
  local path="${1:-}"
  [ -n "$path" ] || die 2 "usage: is-gated <path>"
  _ensure_cache
  local rp
  rp="$(realpath -q "$path" 2>/dev/null || realpath "$path" 2>/dev/null || printf '%s' "$path")"
  jq -e --arg p "$rp" 'any(.targets[]; .path == $p)' "$CACHE" >/dev/null 2>&1
}

case "${1:-}" in
  list)      shift; cmd_list "$@" ;;
  is-gated)  shift; cmd_is_gated "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
