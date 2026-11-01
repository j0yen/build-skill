#!/usr/bin/env bash
# Fake intent-card-refresh.sh for routepar_ac*.sh -- no-op success so a
# --scope branch run never marks intent_card_stale=true (which blocks the
# gate and skips the reviewer), without a real PRD/intent-card round trip.
exit 0
