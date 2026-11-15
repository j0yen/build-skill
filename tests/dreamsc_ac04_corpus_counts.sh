#!/usr/bin/env bash
# dreamsc_ac04 — PRD-dream-scorecard-hook AC4. 4 fixture visions in the window (1 citing a
# -wwhtbt.md page, 1 matching 5whysandrhyme, 1 with a WWHTBT section and no page cited),
# 2 queued PRDs (1 failing prd-lint.sh) and 1 parked PRD naming prd-defect: visions_in_window
# 4, visions_citing_wwhtbt_page 1, visions_citing_fivewhys_page 1, parked_prd_defect 1, and
# queued_lint_fail_by_id names the one failing id. Out-of-window files are controls.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamsc-common.sh"
sc_setup
v="$SC_T/prds/visions"
sc_queued sc-clean
sc_queued sc-bad "- Depends-on: PRD-sc-nowhere.md"
sc_queued sc-old; sed -i 's/^- Drafted: 2026-11-15$/- Drafted: 2026-10-01/' "$SC_T/prds/build-queue/PRD-sc-old.md"   # out of window by Drafted:
# the fixture vision sc_queued copied (visions/dreamdry-fixture.md) is the 4th in-window vision, no page cited
printf '# v1\nAnalysis: pages/2026-11-14-dream-wwhtbt.md\n' > "$v/v1.md"
printf '# v2\nRan /5whysandrhyme on the park.\n' > "$v/v2.md"
printf '# v3\n## What would have to be true (WWHTBT)\n- leaf one\n' > "$v/v3.md"
printf '# old\nsee pages/2020-old-wwhtbt.md and five-whys\n' > "$v/old.md"; touch -d 2020-01-01 "$v/old.md"
printf '# PRD — p1\n- Parked: prd-defect (live evidence never landed)\n' > "$SC_T/prds/parked/PRD-p1.md"
printf '# PRD — p2\n- Parked: infra\n' > "$SC_T/prds/parked/PRD-p2.md"
printf '# PRD — p3\n- Parked: prd-defect\n' > "$SC_T/prds/parked/PRD-p3.md"; touch -d 2020-01-01 "$SC_T/prds/parked/PRD-p3.md"
sc_run --json --since 2026-11-01
sc_expect_rc 0 "AC4"
sc_expect metrics.corpus.visions_in_window.value 4 "AC4"
sc_expect metrics.corpus.visions_citing_wwhtbt_page.value 1 "AC4"
sc_expect metrics.corpus.visions_citing_fivewhys_page.value 1 "AC4"
sc_expect metrics.corpus.parked_prd_defect.value 1 "AC4"
sc_expect metrics.corpus.queued.value 2 "AC4"
sc_expect metrics.corpus.queued_lint_fail_by_id.value '{"depends-on-missing": 1}' "AC4"
sc_expect metrics.corpus.queued.source "\"$SC_T/prds/build-queue\"" "R1 source"
sc_expect sources.prd_lint "\"$SC_REPO/scripts/prd-lint.sh\"" "R4 prd-lint reused from this repo"
if command -v strace >/dev/null 2>&1; then
  w="$(sc_writes --json --since 2026-11-01)"
  [ -z "$w" ] && sc_ok "R7 strace with prd-lint in the loop: nothing written" || sc_fail "R7 strace writes: $w"
fi
sc_finish
