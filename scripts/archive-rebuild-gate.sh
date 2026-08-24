#!/usr/bin/env bash
# archive-rebuild-gate.sh — closes /build gap #68: a re-queued PRD
# (revision > 1, i.e. a rebuild after a prior ship) could re-pass the
# archive gate WITHOUT doing any real work, because the legacy C2/C3
# checks ("a version-bumped commit is reachable" / "a `## v<ver>` section
# exists") are satisfied by the ORIGINAL ship's stale artifacts. A no-op
# rebuild that merely re-checks the gate self-satisfies it.
#
# This gate makes the rebuild prove it advanced the work. For a rebuild
# (revision > 1) it requires ALL of:
#
#   1. STRICTLY-GREATER VERSION — the crate's current Cargo.toml version
#      is strictly greater than `last_shipped_version` recorded in the
#      manifest at the previous ship. A stale commit at the old version
#      no longer satisfies the gate.
#   2. CHANGELOG-FOR-THIS-VERSION — CHANGELOG.md's top section is
#      `## v<current-version>` (the NEW version), not the stale one.
#   3. REBUILD_REASON — the manifest entry carries a non-empty
#      `rebuild_reason` string. A no-op re-queue has nothing to record;
#      a real rebuild states why it was re-queued (audit trail).
#
# A first build (revision <= 1) is N/A and always passes. Legacy entries
# with no `last_shipped_version` recorded are treated as INDETERMINATE on
# check #1 (a warning, not a hard pass) but still MUST satisfy #2 and #3 —
# the field is populated going forward by the archive action.
#
# Version/changelog checks apply to cargo crates (rust-extend / rust-cli /
# rust-lib). kernel-extend enforces only the rebuild_reason audit (#3).
#
# Usage:
#   archive-rebuild-gate.sh <slug> [--format text|json]
#
# Exit codes:
#   0   pass (see [rebuild-gate] on stderr: na | ok | ok-indeterminate)
#   1   FAIL — a rebuild did not prove it advanced the work (mutations: none)
#   2   usage / resolution error
#
# stderr ends with: [rebuild-gate] <verdict>: <detail>

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
MANIFEST="${MANIFEST:-$SKILL_DIR/state/manifest.json}"
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"

log() { printf '%s\n' "archive-rebuild-gate: $*" >&2; }
die() { printf '%s\n' "archive-rebuild-gate: $*" >&2; exit 2; }

slug=""
format=text
while [ "$#" -gt 0 ]; do
  case "$1" in
    --format)   format="${2:-}"; shift 2 ;;
    --format=*) format="${1#--format=}"; shift ;;
    -h|--help)  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    -*)         die "unknown flag $1" ;;
    *)          [ -z "$slug" ] && slug="$1" || die "unexpected arg $1"; shift ;;
  esac
done

[ -n "$slug" ]     || die "slug required (usage: archive-rebuild-gate.sh <slug>)"
[ -x "$JQ" ]       || die "jq not at $JQ"
[ -r "$MANIFEST" ] || die "$MANIFEST not readable"

entry="$("$JQ" -c --arg s "$slug" '.prds[]? | select(.slug==$s)' "$MANIFEST")"
[ -n "$entry" ] || die "no manifest entry for slug '$slug'"

revision="$("$JQ" -r '.revision // 1' <<<"$entry")"
build_target="$("$JQ" -r '.build_target // ""' <<<"$entry")"
repo="$("$JQ" -r '.output_repo_path // .build_into // ""' <<<"$entry")"
last_shipped="$("$JQ" -r '.last_shipped_version // ""' <<<"$entry")"
rebuild_reason="$("$JQ" -r 'if (.rebuild_reason == null) then "" else .rebuild_reason end' <<<"$entry")"

emit() {  # emit <verdict> <detail...>
  local verdict="$1"; shift
  local detail="$*"
  if [ "$format" = json ]; then
    "$JQ" -nc --arg s "$slug" --argjson r "$revision" \
      --arg v "$verdict" --arg d "$detail" \
      '{slug:$s, revision:$r, verdict:$v, detail:$d}'
  fi
  printf '[rebuild-gate] %s: %s\n' "$verdict" "$detail" >&2
}

# First build — gate is N/A.
if [ "${revision:-1}" -le 1 ] 2>/dev/null; then
  emit na "revision=$revision (first build) — rebuild gate not applicable"
  exit 0
fi

# ---- Rebuild (revision > 1): prove the work advanced --------------------
declare -a fails=()
declare -a warns=()

is_cargo=false
case "$build_target" in
  rust-extend|rust-cli|rust-lib) is_cargo=true ;;
esac

cur_ver=""
if [ "$is_cargo" = true ]; then
  if [ -n "$repo" ] && [ -r "$repo/Cargo.toml" ]; then
    # First [package] version key.
    cur_ver="$(awk '
      /^\[package\]/ { inpkg=1; next }
      /^\[/ && inpkg   { inpkg=0 }
      inpkg && /^[[:space:]]*version[[:space:]]*=/ {
        gsub(/.*=[[:space:]]*"?/,""); gsub(/".*/,""); print; exit }
    ' "$repo/Cargo.toml")"
  fi
  [ -n "$cur_ver" ] || fails+=("cannot read current crate version from $repo/Cargo.toml")
fi

# ---- Check 1: strictly-greater version ----------------------------------
if [ "$is_cargo" = true ] && [ -n "$cur_ver" ]; then
  if [ -z "$last_shipped" ]; then
    warns+=("no last_shipped_version recorded — version-advancement unverifiable (legacy entry); checks 2+3 still enforced")
  else
    # Strict semver-ish compare via python3 (handles X.Y.Z and pre-release-free).
    greater="$(python3 - "$cur_ver" "$last_shipped" <<'PY'
import sys
def parse(v):
    v=v.strip().lstrip("v")
    out=[]
    for p in v.split("."):
        n=""
        for ch in p:
            if ch.isdigit(): n+=ch
            else: break
        out.append(int(n) if n else 0)
    while len(out)<3: out.append(0)
    return tuple(out[:3])
cur,last=parse(sys.argv[1]),parse(sys.argv[2])
print("yes" if cur>last else "no")
PY
)"
    if [ "$greater" != "yes" ]; then
      fails+=("version not advanced: current v$cur_ver is not strictly greater than last_shipped v$last_shipped (no-op re-queue)")
    fi
  fi
fi

# ---- Check 2: changelog entry for the current version -------------------
if [ "$is_cargo" = true ] && [ -n "$cur_ver" ]; then
  cl="$repo/CHANGELOG.md"
  if [ ! -r "$cl" ]; then
    fails+=("CHANGELOG.md missing at $repo")
  else
    # Top-most `## v<ver>` heading must equal the current version.
    top_ver="$(awk '/^##[[:space:]]+v?[0-9]/ { gsub(/^##[[:space:]]+v?/,""); gsub(/[[:space:]].*/,""); print; exit }' "$cl")"
    if [ "$top_ver" != "$cur_ver" ]; then
      fails+=("CHANGELOG top entry is v${top_ver:-<none>}, not the current v$cur_ver — rebuild did not prepend a new changelog section")
    fi
  fi
fi

# ---- Check 3: rebuild_reason present ------------------------------------
case "$rebuild_reason" in
  ""|None|none|null)
    fails+=("rebuild_reason not recorded — a re-queue (revision=$revision) must state why it rebuilt") ;;
esac

# ---- Verdict ------------------------------------------------------------
if [ "${#fails[@]}" -gt 0 ]; then
  detail="$(printf '%s; ' "${fails[@]}")"; detail="${detail%; }"
  emit fail "rev=$revision $detail"
  exit 1
fi

if [ "${#warns[@]}" -gt 0 ]; then
  detail="$(printf '%s; ' "${warns[@]}")"; detail="${detail%; }"
  emit ok-indeterminate "rev=$revision $detail"
  exit 0
fi

emit ok "rev=$revision advanced to v${cur_ver:-?}, changelog matches, rebuild_reason recorded"
exit 0
