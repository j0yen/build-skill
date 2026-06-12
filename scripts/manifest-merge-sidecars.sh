#!/usr/bin/env bash
# manifest-merge-sidecars.sh — Parent post-collection sidecar merger
#
# Usage:
#   manifest-merge-sidecars.sh [--dir <status-dir>] [--cleanup]
#
# Reads every state/status/<slug>.json sidecar, acquires manifest.lock,
# reads manifest.json once, applies each sidecar's update to the matching
# slug entry (or inserts a stub if the slug is absent), atomic-writes
# the result, then releases the lock.
#
# --cleanup  Remove all processed sidecar files after a successful merge.
#            Omit for dry-run / debugging.
#
# Exit codes:
#   0  success (0 or more sidecars merged)
#   1  error (manifest invalid, jq not found, etc.)
#
# Design notes:
#   • ONE serial locked pass handles ALL concurrent branches' sidecar.
#     This replaces N concurrent read-modify-write passes on manifest.json.
#   • Sidecar writes (in manifest-sidecar.sh) are each atomic mktemp+mv
#     on DISTINCT paths, so sibling branches never contend with each other.
#   • The manifest lock is held only for the merge itself, not for branch
#     work — so it's held milliseconds, not minutes.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Allow override via environment for testing
STATE_DIR="${STATE_DIR:-$SKILL_DIR/state}"
STATUS_DIR="${STATUS_DIR:-$STATE_DIR/status}"
MANIFEST="${MANIFEST:-$STATE_DIR/manifest.json}"
LOCK="${LOCK:-$STATE_DIR/manifest.lock}"
JQ="${JQ:-jq}"

cleanup=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup) cleanup=true ; shift ;;
    --dir)     STATUS_DIR="$2" ; shift 2 ;;
    *) echo "manifest-merge-sidecars: unknown arg '$1'" >&2 ; exit 2 ;;
  esac
done

command -v "$JQ" >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

# Collect sidecar paths
mapfile -t sidecars < <(find "$STATUS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | sort)

if [[ ${#sidecars[@]} -eq 0 ]]; then
  echo "manifest-merge-sidecars: no sidecars to merge"
  exit 0
fi

echo "manifest-merge-sidecars: merging ${#sidecars[@]} sidecar(s)"

# Validate each sidecar is parseable before acquiring the lock
for sc in "${sidecars[@]}"; do
  if ! "$JQ" -e . "$sc" >/dev/null 2>&1; then
    echo "manifest-merge-sidecars: invalid sidecar $sc, skipping" >&2
    # Remove it from the array
    sidecars=("${sidecars[@]/$sc}")
  fi
done

# Build a JSON array of all sidecar objects for bulk processing in jq
sidecar_array="$("$JQ" -s '.' "${sidecars[@]}")"

# Acquire manifest.lock (blocking, sub-second expected hold time)
exec 8>"$LOCK"
flock 8

# Validate manifest
if ! "$JQ" -e . "$MANIFEST" >/dev/null 2>&1; then
  echo "manifest-merge-sidecars: manifest.json is invalid JSON, aborting" >&2
  exit 1
fi

# Merge: for each sidecar, update the matching slug's entry in manifest.prds[]
# jq expression: walk prds array; for each entry, check if any sidecar matches
# its slug, and if so apply the sidecar fields.
tmp="$(mktemp "$STATE_DIR/.manifest-merge.XXXXXXXX")"

"$JQ" \
  --argjson sidecars "$sidecar_array" \
  '
  def apply_sidecar(sc):
    # Update fields from sidecar; only override if sidecar value is non-null
    (if sc.status != null then .status = sc.status else . end)
    | (if sc.last_action != null then .last_action = sc.last_action else . end)
    | (if sc.last_error != null then .last_error = sc.last_error
       elif (sc | has("last_error")) then .last_error = null
       else . end)
    | (if (sc.ticks_invested_delta // 0) > 0
       then .ticks_invested = ((.ticks_invested // 0) + sc.ticks_invested_delta)
       else . end)
    | (if sc.output_repo_path != null then .output_repo_path = sc.output_repo_path else . end)
    | (if sc.output_repo_url  != null then .output_repo_url  = sc.output_repo_url  else . end)
    ;

  # Build lookup: slug -> sidecar
  ([$sidecars[] | {key: .slug, value: .}] | from_entries) as $lookup |

  # Update existing prds entries
  .prds |= map(
    if $lookup[.slug] then apply_sidecar($lookup[.slug])
    else .
    end
  ) |

  # Insert stubs for slugs in sidecars not yet in manifest
  ($lookup | keys) as $sidecar_slugs |
  (.prds | map(.slug)) as $existing_slugs |
  ($sidecar_slugs - $existing_slugs) as $new_slugs |
  .prds += [
    $new_slugs[] |
    ($lookup[.]) |
    {
      slug:             .slug,
      path:             null,
      status:           (.status // "in_progress"),
      build_auto:       true,
      build_target:     null,
      revision:         1,
      last_action:      .last_action,
      last_error:       .last_error,
      output_repo_path: .output_repo_path,
      output_repo_url:  .output_repo_url,
      version_bump:     null,
      ticks_invested:   (.ticks_invested_delta // 1),
      blockers:         []
    }
  ]
  ' \
  "$MANIFEST" > "$tmp"

# Validate output
if ! "$JQ" -e . "$tmp" >/dev/null 2>&1; then
  rm -f "$tmp"
  echo "manifest-merge-sidecars: jq produced invalid JSON, aborting" >&2
  exit 1
fi

mv -f "$tmp" "$MANIFEST"
# Release manifest.lock (flock releases on fd close at script exit)

echo "manifest-merge-sidecars: manifest.json updated with ${#sidecars[@]} sidecar(s)"

if $cleanup; then
  for sc in "${sidecars[@]}"; do
    [ -f "$sc" ] && rm -f "$sc"
  done
  echo "manifest-merge-sidecars: cleaned up ${#sidecars[@]} sidecar file(s)"
fi
