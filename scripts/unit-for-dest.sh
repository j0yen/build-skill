#!/usr/bin/env bash
# unit-for-dest.sh — resolve an install dest to its backing systemd-user unit.
#
# Usage:
#   wm_unit_for_dest <dest>
#
#   Scans ~/.config/systemd/user/*.service ExecStart= lines.
#   Expands %h → $HOME and %t → $XDG_RUNTIME_DIR (or /run/user/<uid>).
#   Echoes the first unit name (e.g. "agorabus.service") whose ExecStart
#   binary component matches <dest>.  Echoes nothing if no unit matches.
#   Exit 0 always.
#
# Designed to be sourced (wm_unit_for_dest as a function) or called directly
# (last argument is the dest, stdout is the unit name or empty).
#
# Examples:
#   wm_unit_for_dest ~/.local/bin/agorabus   → "agorabus.service"
#   wm_unit_for_dest ~/.local/bin/something  → ""

set -uo pipefail

# Expand systemd specifiers %h and %t in a string.
_expand_specifiers() {
  local s="$1"
  local h="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"
  local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  s="${s//'%h'/$h}"
  s="${s//'%t'/$rt}"
  printf '%s' "$s"
}

# wm_unit_for_dest <dest>
# Echoes the backing unit name or empty string. Exit 0 always.
wm_unit_for_dest() {
  local dest="$1"
  # Normalise dest: expand ~ and make absolute.
  dest="${dest/#\~/$HOME}"
  dest="$(readlink -f "$dest" 2>/dev/null || printf '%s' "$dest")"

  local unit_dir="${WM_UNIT_DIR:-$HOME/.config/systemd/user}"
  [ -d "$unit_dir" ] || return 0

  local unit_file unit_name exec_line exec_binary expanded
  for unit_file in "$unit_dir"/*.service; do
    [ -f "$unit_file" ] || continue
    unit_name="$(basename "$unit_file")"
    # Read ExecStart= lines; take the first one.
    while IFS= read -r exec_line; do
      # Strip "ExecStart=" prefix.
      exec_line="${exec_line#ExecStart=}"
      # Expand specifiers.
      expanded="$(_expand_specifiers "$exec_line")"
      # The binary is the first whitespace-delimited token.
      exec_binary="${expanded%% *}"
      # Normalise via readlink so symlinks compare equal.
      exec_binary="$(readlink -f "$exec_binary" 2>/dev/null || printf '%s' "$exec_binary")"
      if [ "$exec_binary" = "$dest" ]; then
        printf '%s\n' "$unit_name"
        return 0
      fi
    done < <(grep -m1 '^ExecStart=' "$unit_file" 2>/dev/null || true)
  done
  return 0
}

# When invoked directly (not sourced), call the function with $1.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'EOF'
unit-for-dest.sh <dest>
  Print the systemd-user unit name whose ExecStart= binary matches <dest>.
  Prints nothing if no unit matches. Exit 0 always.
EOF
    exit 0
  fi
  [ -n "${1:-}" ] || { printf 'usage: unit-for-dest.sh <dest>\n' >&2; exit 1; }
  wm_unit_for_dest "$1"
fi
