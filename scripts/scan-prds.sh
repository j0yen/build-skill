#!/usr/bin/env bash
# scan-prds.sh — emit JSON describing every PRD under ~/Documents/PRDs/
# (top-level only, so ARCHIVE/ and visions/ are excluded). Output shape,
# one object per PRD:
#
#   { "slug": "...", "path": "...", "build_auto": <bool>,
#     "build_target": "<string or null>",
#     "build_priority": "<string or null>",
#     "status_line": "<the PRD's 'Status:' line, or empty>",
#     "size_bytes": <int>, "mtime_iso": "YYYY-MM-DDTHH:MM:SSZ" }
#
# Frontmatter detection: if the file opens with `---\n`, parse YAML up to
# the next `---`. Otherwise, scan the first 40 lines for top-level keys
# (`build_auto:`, `Status:`, etc.) which is how the existing PRDs encode them.

set -uo pipefail

PRD_DIR="${PRD_DIR:-$HOME/wintermute/autobuilder}"

# Fast path: use vellum if available (same output format, faster + more correct).
if command -v vellum >/dev/null 2>&1; then
    exec vellum scan "${PRD_DIR}"
fi
# Fallback: bash parser (used when vellum is absent or upgrading).
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"

[ -d "$PRD_DIR" ] || { printf '[]\n'; exit 0; }
[ -x "$JQ" ] || { echo "jq not at $JQ" >&2; exit 1; }

emit_one() {
  local path="$1" slug status_line build_auto build_target build_priority build_into build_version_bump deferred_acs deferred_ac_reasons
  slug="$(basename "$path" .md)"
  slug="${slug#PRD-}"

  # build_auto is always true per user instruction 2026-05-27 — every PRD is
  # buildable, no opt-outs. The field is still emitted for backwards-compat
  # with consumers that read it, but its value is no longer parsed from the
  # file: whatever the PRD frontmatter says, we override to true.
  build_auto=true
  build_target=null
  build_priority=null
  build_into=null
  build_version_bump=null
  # Per PRD-build-deferred-acs.md AC1: PRDs may declare ground-truth ACs
  # that /build cannot mechanically verify. Defaults are empty so all
  # existing PRDs behave unchanged (no-deferral path = current behavior).
  # Only inline-list form supported here (e.g. `deferred_acs: [1, 3, 5]`);
  # block-list form lands with deferred_ac_reasons parsing in a later tick.
  deferred_acs="[]"
  deferred_ac_reasons="{}"
  status_line=""

  # Look at the first 80 lines for the keys we care about. Tolerant of
  # both YAML frontmatter and plain `**Status:**` markdown headers.
  # Skip lines inside ``` fenced code blocks so PRD examples don't poison
  # the parse. First-match-wins for build_* keys so real frontmatter
  # always beats later in-doc examples.
  local in_fence=false
  local seen_target=false seen_priority=false seen_into=false seen_bump=false seen_deferred=false
  # strip leading ws, trailing ws, trailing inline-comment (` #...`), surrounding quotes
  strip_val() {
    printf '%s' "$1" | sed -E 's/^[[:space:]]*//;s/[[:space:]]+#.*$//;s/[[:space:]]*$//;s/^"//;s/"$//'
  }
  while IFS= read -r line; do
    case "$line" in
      '```'*) [ "$in_fence" = true ] && in_fence=false || in_fence=true ; continue ;;
    esac
    [ "$in_fence" = true ] && continue
    # Normalize frontmatter keys so bare-YAML, bold-markdown, and bullet/list
    # forms all parse identically:
    #   `build_target: x`      (bare YAML — /build historic)
    #   `**build_target:** x`  (bold markdown — /dream emits this)
    #   `- build_target: x`    (bullet list — many PRD frontmatters)
    # Strip a leading list marker (`- `/`* `/`+ `) first, then rewrite a
    # leading `**key:**` to `key:`. Values and non-key lines are untouched, so
    # first-match-wins and the fenced-code-block skip above are both preserved.
    kline="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[-*+][[:space:]]+//; s/^[[:space:]]*\*\*([A-Za-z_]+):\*\*/\1:/')"
    case "$kline" in
      "build_target:"*)
        [ "$seen_target" = true ] && continue
        v="$(strip_val "$(printf '%s' "$kline" | sed -E 's/^build_target[[:space:]]*:[[:space:]]*//')")"
        [ -n "$v" ] && build_target="\"$v\""
        seen_target=true
        ;;
      "build_priority:"*)
        [ "$seen_priority" = true ] && continue
        v="$(strip_val "$(printf '%s' "$kline" | sed -E 's/^build_priority[[:space:]]*:[[:space:]]*//')")"
        [ -n "$v" ] && build_priority="\"$v\""
        seen_priority=true
        ;;
      "build_into:"*)
        [ "$seen_into" = true ] && continue
        v="$(strip_val "$(printf '%s' "$kline" | sed -E 's/^build_into[[:space:]]*:[[:space:]]*//')")"
        [ -n "$v" ] && build_into="\"$v\""
        seen_into=true
        ;;
      "build_version_bump:"*)
        [ "$seen_bump" = true ] && continue
        v="$(strip_val "$(printf '%s' "$kline" | sed -E 's/^build_version_bump[[:space:]]*:[[:space:]]*//')")"
        [ -n "$v" ] && build_version_bump="\"$v\""
        seen_bump=true
        ;;
      "deferred_acs:"*)
        # Inline-list form only: `deferred_acs: [1, 3, 5]`. Strip the
        # `deferred_acs:` prefix, then the surrounding brackets, split on
        # commas, keep digits-only tokens, join into a JSON array. Anything
        # not matching this shape parses to `[]` — same as absent.
        [ "$seen_deferred" = true ] && continue
        v="$(strip_val "$(printf '%s' "$kline" | sed -E 's/^deferred_acs[[:space:]]*:[[:space:]]*//')")"
        # require leading `[` and trailing `]` — otherwise treat as no-op
        case "$v" in
          '['*']')
            inner="${v#\[}"; inner="${inner%\]}"
            csv=""
            IFS=',' read -ra toks <<<"$inner"
            for t in "${toks[@]}"; do
              tt="$(printf '%s' "$t" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
              case "$tt" in
                ''|*[!0-9]*) continue ;;
                *) csv+="${csv:+,}$tt" ;;
              esac
            done
            deferred_acs="[$csv]"
            ;;
        esac
        seen_deferred=true
        ;;
      "**Status:**"*|"Status:"*|"**Status**"*|"## Status"*|"- Status:"*|"- **Status:**"*|"* Status:"*|"* **Status:**"*)
        # Strip a leading markdown list marker (`- ` / `* `) first, then the
        # `*`/`#` decoration, then trim — so `- Status: Draft v0.1` parses the
        # same as `**Status:** Draft v0.1`.
        [ -z "$status_line" ] && status_line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[-*][[:space:]]+//; s/[*#]//g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
        ;;
    esac
  done < <(head -n 80 "$path")

  local size mtime
  size="$(stat -c%s "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null || echo 0)"
  mtime="$(date -u -r "$path" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "@$(stat -c%Y "$path")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || echo "1970-01-01T00:00:00Z")"

  "$JQ" -cn \
    --arg slug "$slug" \
    --arg path "$path" \
    --argjson build_auto "$build_auto" \
    --argjson build_target "$build_target" \
    --argjson build_priority "$build_priority" \
    --argjson build_into "$build_into" \
    --argjson build_version_bump "$build_version_bump" \
    --argjson deferred_acs "$deferred_acs" \
    --argjson deferred_ac_reasons "$deferred_ac_reasons" \
    --arg status_line "$status_line" \
    --argjson size "$size" \
    --arg mtime "$mtime" \
    '{slug:$slug, path:$path, build_auto:$build_auto, build_target:$build_target, build_priority:$build_priority, build_into:$build_into, build_version_bump:$build_version_bump, deferred_acs:$deferred_acs, deferred_ac_reasons:$deferred_ac_reasons, status_line:$status_line, size_bytes:$size, mtime_iso:$mtime}'
}

# Emit top-level PRDs (buildable) AND ARCHIVE/ PRDs (already done).
# Phase 1 diff distinguishes them by path: contains "/ARCHIVE/" → treat as
# "archived" if the manifest entry is currently "vanished", never re-queue.
# This prevents the scan from declaring "vanished" for PRDs that were
# legitimately archived (moved out of top-level after shipping).
{
  find -L "$PRD_DIR" -maxdepth 1 -type f -name 'PRD-*.md' -print0
  [ -d "$PRD_DIR/ARCHIVE" ] && \
    find -L "$PRD_DIR/ARCHIVE" -maxdepth 1 -type f -name 'PRD-*.md' -print0
} | sort -z \
  | {
      first=true
      printf '['
      while IFS= read -r -d '' f; do
        $first || printf ','
        first=false
        emit_one "$f"
      done
      printf ']\n'
    }
