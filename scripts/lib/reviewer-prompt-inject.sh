#!/usr/bin/env bash
# lib/reviewer-prompt-inject.sh — one-shot operator env injection for ONE
# branch gate (PRD-build-gate-infra-outcome AC13, route A2 per decision
# 261f5b2c, Joe 2026-09-18). Source this; never execute it.
#
# The operator arms $STATE_DIR/reviewer-prompt-inject-once.json:
#   {"slug_glob":"mcphost-*","reviewer_prompt":"/nonexistent",
#    "decision":"261f5b2c","armed_at":"<ISO>","expires_at":"<ISO>"}
# The FIRST branch-scope gate whose slug matches slug_glob claims the file
# (mv is atomic on one filesystem, so concurrent gates cannot both win),
# prints the injected REVIEWER_PROMPT value, and journals the claim. Main-
# scope gates, non-matching slugs and a second call see nothing. Past
# expires_at the file is renamed .expired and nothing is injected (route C
# fallback is then the operator's call).
reviewer_prompt_inject_once() {
  local scope="$1" slug="$2" file="$3" journal="${4:-}"
  [ "$scope" = branch ] || return 0
  [ -n "$slug" ] && [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local glob val expires now ts consumed
  glob="$(jq -r '.slug_glob // "*"' "$file" 2>/dev/null)" || return 0
  val="$(jq -r '.reviewer_prompt // empty' "$file" 2>/dev/null)" || return 0
  expires="$(jq -r '.expires_at // empty' "$file" 2>/dev/null)"
  [ -n "$val" ] || return 0
  # shellcheck disable=SC2254
  case "$slug" in
    $glob) ;;
    *) return 0 ;;
  esac
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$expires" ]; then
    now="$(date -u +%s)"
    if [ "$now" -gt "$(date -u -d "$expires" +%s 2>/dev/null || echo 0)" ]; then
      mv "$file" "${file%.json}.expired-$(date -u +%Y%m%dT%H%M%SZ).json" 2>/dev/null || true
      [ -n "$journal" ] && printf '%s  %s  gate  reviewer-prompt-inject  expired  (file=%s expires_at=%s)\n' \
        "$ts" "$slug" "$file" "$expires" >>"$journal"
      return 0
    fi
  fi
  consumed="${file%.json}.consumed-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  mv "$file" "$consumed" 2>/dev/null || return 0
  jq --arg slug "$slug" --arg ts "$ts" '. + {consumed_by_slug:$slug, consumed_at:$ts}' "$consumed" >"$consumed.tmp" 2>/dev/null \
    && mv "$consumed.tmp" "$consumed"
  [ -n "$journal" ] && printf '%s  %s  gate  reviewer-prompt-injected  once  (decision=%s reviewer_prompt=%s consumed=%s)\n' \
    "$ts" "$slug" "$(jq -r '.decision // "-"' "$consumed")" "$val" "$consumed" >>"$journal"
  printf '%s\n' "$val"
}
