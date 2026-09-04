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

PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"

# Fast path: use vellum if available (same output format, faster + more correct).
# Emit BOTH top-level (buildable) and ARCHIVE/ (already-done) so Phase 1 diff
# can distinguish archived from truly-vanished. Without this, PRDs moved to
# ARCHIVE/ after shipping would be marked "vanished" on the next scan and
# re-queued or lost — wasting cloud server time re-building done work.
if command -v vellum >/dev/null 2>&1; then
    ARCHIVE_DIR="${PRD_DIR}/ARCHIVE"
    if [ -d "$ARCHIVE_DIR" ]; then
        # Merge top-level + ARCHIVE results into one JSON array.
        # vellum emits pretty-printed JSON; use temp files so python3 parses
        # each as a complete document rather than trying to split by line.
        _tmp_top="$(mktemp)" _tmp_arc="$(mktemp)"
        vellum scan "${PRD_DIR}"      >"$_tmp_top"
        vellum scan "${ARCHIVE_DIR}"  >"$_tmp_arc"
        python3 - "$_tmp_top" "$_tmp_arc" <<'PY'
import json, sys
merged = []
for path in sys.argv[1:]:
    try:
        with open(path) as f:
            merged.extend(json.load(f))
    except Exception:
        pass
print(json.dumps(merged))
PY
        rm -f "$_tmp_top" "$_tmp_arc"
    else
        exec vellum scan "${PRD_DIR}"
    fi
    exit 0
fi
# Fallback: bash parser (used when vellum is absent or upgrading).
JQ="${JQ:-$(command -v jq 2>/dev/null || echo /usr/bin/jq)}"

[ -d "$PRD_DIR" ] || { printf '[]\n'; exit 0; }
[ -x "$JQ" ] || { echo "jq not at $JQ" >&2; exit 1; }

emit_one() {
  local path="$1" slug status_line build_auto build_target build_priority build_into build_version_bump deferred_acs deferred_ac_reasons publish test_prefix deferred_acs_unparsed
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
  publish=null
  # Per PRD-build-deferred-acs.md AC1: PRDs may declare ground-truth ACs
  # that /build cannot mechanically verify. Defaults are empty so all
  # existing PRDs behave unchanged (no-deferral path = current behavior).
  # Only inline-list form supported here (e.g. `deferred_acs: [1, 3, 5]`);
  # block-list form lands with deferred_ac_reasons parsing in a later tick.
  deferred_acs="[]"
  deferred_ac_reasons="{}"
  # Per PRD-build-archive-autopair AC3: a `deferred_acs:` line whose value
  # isn't the bracket-list form (and isn't simply absent/block-form-empty)
  # is prose the parser can't read. Distinguish that from "no deferred_acs
  # key at all" so verified-completed.sh can name the failure instead of
  # silently treating it the same as "none declared".
  deferred_acs_unparsed=false
  # Per PRD-build-archive-autopair AC1: a PRD on a shared crate may declare
  # the test-file prefix its own ACs use (`test_prefix: http`, or a list
  # `test_prefix: [http, https]`) so the archive gate's derivation doesn't
  # have to guess. Always emitted as a JSON array (possibly empty).
  test_prefix="[]"
  status_line=""

  # Look at the first 80 lines for the keys we care about. Tolerant of
  # both YAML frontmatter and plain `**Status:**` markdown headers.
  # Skip lines inside ``` fenced code blocks so PRD examples don't poison
  # the parse. First-match-wins for build_* keys so real frontmatter
  # always beats later in-doc examples.
  local in_fence=false
  local seen_target=false seen_priority=false seen_into=false seen_bump=false seen_deferred=false seen_test_prefix=false
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
      "publish:"*)
        [ "${seen_publish:-false}" = true ] && continue
        v="$(strip_val "$(printf '%s' "$kline" | sed -E 's/^publish[[:space:]]*:[[:space:]]*//')")"
        [ -n "$v" ] && publish="\"$v\""
        seen_publish=true
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
        # commas, keep digits-only tokens, join into a JSON array. An
        # empty remainder (block-list form: `deferred_acs:` alone on its
        # line, values on following `- N` lines — not parsed here, lands
        # in a later tick) is a silent no-op, same as absent. Anything
        # ELSE (prose — PRD-build-archive-autopair AC3) parses to `[]`
        # too, but is flagged via deferred_acs_unparsed so the caller can
        # name the failure instead of treating it as "none declared".
        [ "$seen_deferred" = true ] && continue
        v="$(strip_val "$(printf '%s' "$kline" | sed -E 's/^deferred_acs[[:space:]]*:[[:space:]]*//')")"
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
          '')
            : # block-list form or bare `deferred_acs:` — no-op, not prose
            ;;
          *)
            deferred_acs_unparsed=true
            ;;
        esac
        seen_deferred=true
        ;;
      "test_prefix:"*)
        # Bare scalar (`test_prefix: http`) or bracket-list (`test_prefix:
        # [http, https]`) — always emitted as a JSON array of strings.
        [ "$seen_test_prefix" = true ] && continue
        v="$(strip_val "$(printf '%s' "$kline" | sed -E 's/^test_prefix[[:space:]]*:[[:space:]]*//')")"
        case "$v" in
          '['*']')
            inner="${v#\[}"; inner="${inner%\]}"
            arr=""
            IFS=',' read -ra ptoks <<<"$inner"
            for t in "${ptoks[@]}"; do
              tt="$(printf '%s' "$t" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//;s/^"//;s/"$//')"
              [ -n "$tt" ] || continue
              esc="$(printf '%s' "$tt" | sed 's/\\/\\\\/g;s/"/\\"/g')"
              arr+="${arr:+,}\"$esc\""
            done
            test_prefix="[$arr]"
            ;;
          '')
            : # nothing after the colon — no-op
            ;;
          *)
            esc="$(printf '%s' "$v" | sed 's/\\/\\\\/g;s/"/\\"/g')"
            test_prefix="[\"$esc\"]"
            ;;
        esac
        seen_test_prefix=true
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
    --argjson publish "$publish" \
    --argjson deferred_acs "$deferred_acs" \
    --argjson deferred_acs_unparsed "$deferred_acs_unparsed" \
    --argjson deferred_ac_reasons "$deferred_ac_reasons" \
    --argjson test_prefix "$test_prefix" \
    --arg status_line "$status_line" \
    --argjson size "$size" \
    --arg mtime "$mtime" \
    '{slug:$slug, path:$path, build_auto:$build_auto, build_target:$build_target, build_priority:$build_priority, build_into:$build_into, build_version_bump:$build_version_bump, publish:$publish, deferred_acs:$deferred_acs, deferred_acs_unparsed:$deferred_acs_unparsed, deferred_ac_reasons:$deferred_ac_reasons, test_prefix:$test_prefix, status_line:$status_line, size_bytes:$size, mtime_iso:$mtime}'
}

# Emit top-level PRDs (buildable) AND ARCHIVE/ PRDs (already done).
# Phase 1 diff distinguishes them by path: contains "/ARCHIVE/" → treat as
# "archived" if the manifest entry is currently "vanished", never re-queue.
# This prevents the scan from declaring "vanished" for PRDs that were
# legitimately archived (moved out of top-level after shipping).
{
  # Queue: build-queue/ is canonical (j0yen/prds layout, 2026-08-27). A legacy
  # workspace with no build-queue/ dir still scans its top level.
  if [ -d "$PRD_DIR/build-queue" ]; then
    find -L "$PRD_DIR/build-queue" -maxdepth 1 -type f -name 'PRD-*.md' -print0
  else
    find -L "$PRD_DIR" -maxdepth 1 -type f -name 'PRD-*.md' -print0
  fi
  # Done: built-prds/ is canonical; ARCHIVE/ and archive/ are legacy aliases.
  # parked/ is deliberately NOT scanned.
  for d in built-prds ARCHIVE archive; do
    [ -d "$PRD_DIR/$d" ] || continue
    case "$d" in archive) [ "$PRD_DIR/archive" -ef "$PRD_DIR/ARCHIVE" ] && continue;; esac
    find -L "$PRD_DIR/$d" -maxdepth 1 -type f -name 'PRD-*.md' -print0
  done
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
