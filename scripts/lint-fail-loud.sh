#!/usr/bin/env bash
# scripts/lint-fail-loud.sh — PRD-build-fail-loud-evidence-kept requirement
# 4: flags NEW silent-swallow sites on an allowlist of verdict/routing/
# teardown commands, so the eight sites this PRD converted to
# scripts/lib/probe.sh don't grow a ninth.
#
# Usage:
#   lint-fail-loud.sh [<dir> ...]     (default: scripts)
#
# Flags any line under the scanned dir(s), in a *.sh file OTHER than
# scripts/lib/probe.sh itself (probe.sh's own stderr-swallow-then-branch
# implementation is exactly what a caller is supposed to delegate to, not
# an offense), matching:
#   <allowlisted-command> ... >/dev/null 2>&1 ... (|| true | || :)
#   <allowlisted-command> ... & disown
# The allowlist (verdict/routing/teardown commands whose silent failure
# already caused a real incident — see the PRD's Grounding):
#   cmd_verify  cmd_down  cmd_parity  status --json  route-check
#   jq -r .*verdict  extend-gate  hcloud server delete
# `mkdir -p ... || true` and similar on a NON-allowlisted command are never
# flagged (AC8's negative case) — this lints commands, not the redirect
# shape in isolation.
#
# Prints one `file:line: <matched-allowlist-entry>` per offense. Exit 0 and
# a summary line ("lint-fail-loud: 0 offenses") when clean; exit 1 with the
# offense list otherwise.
#
# Migration (PRD's own Migration section): warn-only for one week via
# LINT_FAIL_LOUD_WARN=1 (default) — offenses are printed but exit stays 0;
# set LINT_FAIL_LOUD_WARN=0 to make it a hard gate (the eventual default).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

# Allowlist entries as extended-regex fragments matching the COMMAND part
# of a line (left of the redirect/backgrounding this lint looks for).
ALLOWLIST=(
  'cmd_verify'
  'cmd_down'
  'cmd_parity'
  'status --json'
  'route-check'
  'jq -r [^ ]*verdict'
  'extend-gate'
  'hcloud server delete'
)

dirs=("$@")
[ "${#dirs[@]}" -eq 0 ] && dirs=("$SKILL_DIR/scripts")

offenses=0
while IFS= read -r -d '' f; do
  # probe.sh itself legitimately implements the swallow-then-branch shape
  # this lint exists to keep OUT of every other site — it is the one place
  # that shape belongs.
  case "$f" in */lib/probe.sh) continue ;; esac
  local_line=0
  while IFS= read -r line; do
    local_line=$((local_line + 1))
    # The redirect/backgrounding shape this PRD converted away from. A
    # line that already routes through probe_run/probe_bg is the FIX, not
    # an offense — probe.sh keeps the stderr and journals the failure
    # internally before the caller's own outer `|| true` ever runs, so
    # excluding these avoids flagging every site this PRD just converted.
    case "$line" in
      *'probe_run '*|*'probe_bg '*) continue ;;
    esac
    case "$line" in
      *'>/dev/null 2>&1'*'|| true'*|*'>/dev/null 2>&1'*'|| :'*|*'& disown'*) : ;;
      *) continue ;;
    esac
    for entry in "${ALLOWLIST[@]}"; do
      if [[ "$line" =~ $entry ]]; then
        echo "$f:$local_line: matched allowlist entry: $entry"
        offenses=$((offenses + 1))
        break
      fi
    done
  done < "$f"
done < <(find "${dirs[@]}" -type f -name '*.sh' -print0 2>/dev/null)

if [ "$offenses" -eq 0 ]; then
  echo "lint-fail-loud: 0 offenses"
  exit 0
fi

echo "lint-fail-loud: $offenses offense(s)" >&2
if [ "${LINT_FAIL_LOUD_WARN:-1}" = "1" ]; then
  echo "lint-fail-loud: warn-only (LINT_FAIL_LOUD_WARN=1) — not failing the suite" >&2
  exit 0
fi
exit 1
