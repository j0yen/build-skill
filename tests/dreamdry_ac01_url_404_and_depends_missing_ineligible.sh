#!/usr/bin/env bash
# dreamdry_ac01 — PRD-dream-dryrun-hook AC1 (known-bad controls).
# Given a lint-clean PRD whose Live AC names a URL the fake prober answers 404,
# Then `ineligible — url: <url> 404`, exit 3. Given a PRD whose Depends-on names
# a file absent from the batch and the destination, Then `ineligible — lint:
# depends-on-missing`, explain and the prober are not called, exit 3.
set -uo pipefail
source "$(dirname "$0")/fixtures/dreamdry-common.sh"
dd_setup

url="https://dreamdry.example.com/missing.csv"
dd_prd "$DD_T/drafts" dreamdry-url "" "3. P0 — Given the landed fixture, When the judge fetches the sample, Then it answers 200. (Live; evidence: \`cmd:curl -sf -o /dev/null $url\`)"
dd_probe HEAD "$url" 404
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-url.md"
dd_expect_contains dreamdry-url "ineligible — url: $url 404" "AC1 url 404"
dd_expect_rc 3 "AC1 url 404"
grep -qx "HEAD $url" "$DD_T/probe.log" && dd_ok "AC1 url 404: the prober was asked HEAD $url" || dd_fail "AC1 url 404: probe log: $(cat "$DD_T/probe.log")"
dd_tmp_empty "AC1 url 404"

: > "$DD_T/wb.log"; : > "$DD_T/probe.log"
dd_prd "$DD_T/drafts" dreamdry-dep "- Depends-on: PRD-dreamdry-nowhere.md" "3. P0 — Given the landed fixture, When the judge fetches, Then 200. (Live; evidence: \`cmd:curl -sf -o /dev/null $url\`)"
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-dep.md"
dd_expect_line dreamdry-dep "admit-would: dreamdry-dep ineligible — lint: depends-on-missing claims=unknown open-runs=unknown" "AC1 depends-on-missing"
dd_expect_rc 3 "AC1 depends-on-missing"
if grep -q '^explain' "$DD_T/wb.log"; then dd_fail "AC1 depends-on-missing: explain was called: $(cat "$DD_T/wb.log")"; else dd_ok "AC1 depends-on-missing: explain not called"; fi
if [ -s "$DD_T/probe.log" ]; then dd_fail "AC1 depends-on-missing: prober was called: $(cat "$DD_T/probe.log")"; else dd_ok "AC1 depends-on-missing: prober not called"; fi
grep -q '^lint ' "$DD_T/wb.log" && dd_ok "AC1 depends-on-missing: the lint half ran (wm-build lint through the wrapper)" || dd_fail "AC1: wm-build lint never ran: $(cat "$DD_T/wb.log")"
dd_tmp_empty "AC1 depends-on-missing"
dd_finish
