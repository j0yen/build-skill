#!/usr/bin/env bash
# Fake intent-card-refresh.sh for revauth_ac*.sh -- no-op success so the
# --scope branch pre-gate refresh step never marks intent_card_stale=true
# (which would otherwise skip the reviewer entirely), without needing a
# real PRD/intent-card round trip this PRD's own fixtures don't exercise.
exit 0
