#!/usr/bin/env bash
# selslot_ac10_scratch_only_no_real_host.sh —
# PRD-build-select-guard-depends-before-slot AC10: given no AC in this PRD
# names a real host, network call, or billed resource, when any of the
# above ACs run, then every fixture operates entirely under a
# `mktemp -d /tmp/...` scratch tree with a local bare git origin,
# identical in kind to select-guard-selftest.sh's own $ROOT pattern, and
# no AC's pass/fail depends on RedBaron, casper, or any external service
# being reachable.
#
# Mechanized as a static check over every tests/selslot_ac*.sh sibling:
# each must source the shared scratch-only fixture harness, and none may
# reference a real fleet hostname or a network tool.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="$(basename "$0")"
fail=0

for f in "$HERE"/selslot_ac*.sh; do
  [ "$(basename "$f")" = "$SELF" ] && continue
  # AC9's own fixture legitimately re-invokes the real
  # select-guard-selftest.sh script directly (that IS its assertion) --
  # that script's own $ROOT is the mktemp-d/bare-origin scratch tree, just
  # not via THIS PRD's shared selslot-common.sh helper. Checked below by
  # inspecting select-guard-selftest.sh itself instead.
  if [ "$(basename "$f")" != "selslot_ac9_preexisting_suite_still_passes.sh" ]; then
    grep -q 'source "\$HERE/fixtures/selslot-common.sh"' "$f" \
      || { echo "FAIL AC10: $(basename "$f") does not use the shared scratch-only fixture harness" >&2; fail=1; }
  fi
  if grep -qiE '\b(redbaron|casper|hetzner|hcloud)\b|(^|[^A-Za-z0-9_-])(curl|ssh|scp|wget)\b' "$f"; then
    echo "FAIL AC10: $(basename "$f") references a real host or network tool" >&2
    fail=1
  fi
done

grep -q 'mktemp -d' "$HERE/../scripts/select-guard-selftest.sh" \
  || { echo "FAIL AC10: select-guard-selftest.sh (AC9's target) does not use mktemp -d" >&2; fail=1; }

grep -q 'mktemp -d' "$HERE/fixtures/selslot-common.sh" \
  || { echo "FAIL AC10: shared fixture does not use mktemp -d" >&2; fail=1; }
grep -q 'git init -q --bare' "$HERE/fixtures/selslot-common.sh" \
  || { echo "FAIL AC10: shared fixture does not use a local bare git origin" >&2; fail=1; }

[ "$fail" -eq 0 ] || exit 1
echo "ok  AC10: every selslot_ac*.sh fixture is scratch-only (mktemp -d + local bare origin), no real host/network"
