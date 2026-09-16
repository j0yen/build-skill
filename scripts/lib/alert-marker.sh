#!/usr/bin/env bash
# scripts/lib/alert-marker.sh — the one (rule, repo, UTC day) idempotency
# marker, shared by alert-deliver.sh (which creates it) and
# manifest-invariants.sh (which checks it before journaling an alarm line
# or seeding a fix PRD) — PRD-build-repo-health-invariants requirement 4 /
# AC3. Two call sites deriving the same path independently is exactly the
# kind of drift that made "idempotent per day" silently stop being true
# once; keeping it in one function instead.
#
# Requires BUILD_STATE_DIR to be set by the caller (both scripts already
# resolve and export it before sourcing this).
#
# Day boundary is UTC (`date -u +%F`), consistent with every timestamp
# this codebase journals.

alert_marker_dir() {
  printf '%s/alerts/%s\n' "${BUILD_STATE_DIR:?alert-marker.sh requires BUILD_STATE_DIR}" "$(date -u +%F)"
}

alert_marker_path() {  # $1=rule $2=repo
  printf '%s/%s.%s\n' "$(alert_marker_dir)" "$2" "$1"
}

alert_marker_exists() {  # $1=rule $2=repo
  [ -f "$(alert_marker_path "$1" "$2")" ]
}

alert_marker_touch() {  # $1=rule $2=repo
  mkdir -p "$(alert_marker_dir)" 2>/dev/null || true
  : > "$(alert_marker_path "$1" "$2")"
}
