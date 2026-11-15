#!/usr/bin/env bash
# dreamdry_ac04_r8_chain_precedence — PRD-dream-dryrun-hook R8: with no seam the binary is
# the FIRST existing executable of `command -v wm-build`, $HOME/.cargo/bin/wm-build,
# $HOME/.local/bin/wm-build. Independent review gaps DM1 (~/.local/bin before
# ~/.cargo/bin) and DM2 (~/.cargo/bin before command -v): every candidate is present at
# once and each answers a different --version, so any reordering shows in the header.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamdry-common.sh"
dd_setup
dd_prd "$DD_T/drafts" dreamdry-r8
unset DREAM_DRYRUN_WM_BUILD
mkdir -p "$DD_T/pathbin" "$HOME/.cargo/bin" "$HOME/.local/bin"
mk() { printf '#!/bin/sh\nFAKE_WB_VERSION=%s exec %q "$@"\n' "$2" "$DD_T/bin/wm-build" > "$1"; chmod +x "$1"; }
mk "$DD_T/pathbin/wm-build" 1.0.1; mk "$HOME/.cargo/bin/wm-build" 1.0.2; mk "$HOME/.local/bin/wm-build" 1.0.3
bare="/usr/bin:/bin"
( PATH="$bare"; command -v wm-build >/dev/null 2>&1 ) && dd_fail "fixture: $bare already holds a wm-build"
hdr() { local keep="$PATH"; PATH="$1"; dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-r8.md"; PATH="$keep"; HV="$(head -1 <<<"$DD_OUT" | sed 's/.* wm-build=\([^ ]*\) .*/\1/')"; }

hdr "$DD_T/pathbin:$bare"; [ "$HV" = 1.0.1 ] && dd_ok "R8 all three present: command -v wins" || dd_fail "R8 all three: $DD_OUT"
hdr "$bare"; [ "$HV" = 1.0.2 ] && dd_ok "R8 cargo and local present, none on PATH: ~/.cargo/bin wins (DM1)" || dd_fail "R8 cargo vs local: $DD_OUT"
chmod -x "$DD_T/pathbin/wm-build"
hdr "$DD_T/pathbin:$bare"; [ "$HV" = 1.0.2 ] && dd_ok "R8 a non-executable PATH entry is skipped: ~/.cargo/bin next (DM2 order holds)" || dd_fail "R8 non-exec PATH: $DD_OUT"
chmod +x "$DD_T/pathbin/wm-build"; chmod -x "$HOME/.cargo/bin/wm-build"
hdr "$bare"; [ "$HV" = 1.0.3 ] && dd_ok "R8 a non-executable ~/.cargo/bin entry is skipped: ~/.local/bin last" || dd_fail "R8 non-exec cargo: $DD_OUT"
hdr "$DD_T/pathbin:$bare"; [ "$HV" = 1.0.1 ] && dd_ok "R8 command -v still first with cargo unusable" || dd_fail "R8: $DD_OUT"
dd_tmp_empty "R8 precedence"
dd_finish
