#!/usr/bin/env bash
# dreamdry_ac05 — PRD-dream-dryrun-hook AC5 (known-bad controls). 405 to HEAD and 206
# to the ranged GET -> verdict unchanged; 405 to both -> `unknown — url: <url>
# head-not-allowed`, exit 4; the prober printing an error -> `unknown — url: <url>
# <error>`; a loopback URL is never passed to the prober.
set -uo pipefail
source "$(dirname "$0")/fixtures/dreamdry-common.sh"
dd_setup
u1="https://dreamdry.example.com/head-refused.csv"
dd_prd "$DD_T/drafts" dreamdry-u405 "" "3. P0 — Given the fixture, When the judge fetches, Then 200. (Live; evidence: \`cmd:curl -sf -o /dev/null $u1\`)"
dd_probe HEAD "$u1" 405; dd_probe GET "$u1" 206
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-u405.md"
dd_expect_line dreamdry-u405 "admit-would: dreamdry-u405 eligible claims=unknown open-runs=unknown" "AC5 405 then 206: verdict unchanged"
dd_expect_rc 0 "AC5 405 then 206"
[ "$(cat "$DD_T/probe.log")" = "HEAD $u1"$'\n'"GET $u1" ] && dd_ok "AC5 HEAD then one ranged GET" || dd_fail "AC5 probe log: $(cat "$DD_T/probe.log")"

dd_probe GET "$u1" 405
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-u405.md"
dd_expect_line dreamdry-u405 "admit-would: dreamdry-u405 unknown — url: $u1 head-not-allowed claims=unknown open-runs=unknown" "AC5 405 twice"
dd_expect_rc 4 "AC5 405 twice"

u2="https://dreamdry.example.com/dns-fails.csv"
dd_prd "$DD_T/drafts" dreamdry-uerr "" "3. P0 — Given the fixture, When the judge fetches, Then 200. (Live; evidence: \`cmd:curl -sf -o /dev/null $u2\`)"
dd_probe HEAD "$u2" "curl: (6) Could not resolve host: dreamdry.example.com"
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-uerr.md"
dd_expect_line dreamdry-uerr "admit-would: dreamdry-uerr unknown — url: $u2 curl: (6) Could not resolve host: dreamdry.example.com claims=unknown open-runs=unknown" "AC5 prober error"
dd_expect_rc 4 "AC5 prober error"

: > "$DD_T/probe.log"
u3="http://127.0.0.1:8080/x"
dd_prd "$DD_T/drafts" dreamdry-uloop "" "3. P0 — Given the fixture, When the judge fetches, Then 200. (Live; evidence: \`cmd:curl -sf -o /dev/null $u3\`)"
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-uloop.md"
dd_expect_line dreamdry-uloop "admit-would: dreamdry-uloop unknown — url: $u3 not-public claims=unknown open-runs=unknown" "AC5 loopback skipped"
dd_expect_rc 4 "AC5 loopback"
[ ! -s "$DD_T/probe.log" ] && dd_ok "AC5 loopback URL never passed to the prober" || dd_fail "AC5 prober saw: $(cat "$DD_T/probe.log")"

# 5xx is a refusal; the Premise: value is probed too
u4="https://dreamdry.example.com/premise.txt"
dd_prd "$DD_T/drafts" dreamdry-prem "- Premise: $u4 answers 200"
dd_probe HEAD "$u4" 503
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-prem.md"
dd_expect_line dreamdry-prem "admit-would: dreamdry-prem ineligible — url: $u4 503 claims=unknown open-runs=unknown" "R7 Premise URL 503"
dd_expect_rc 3 "R7 Premise URL 503"

# over 10 distinct URLs: the excess is reported, never probed
: > "$DD_T/probe.log"
ev=""; for i in $(seq 1 11); do ev="$ev https://dreamdry.example.com/u$i"; done
dd_prd "$DD_T/drafts" dreamdry-many "" "3. P0 — Given the fixture, When the judge fetches, Then 200. (Live; evidence: \`cmd:for u in$ev; do curl -sf -o /dev/null \$u; done\`)"
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-many.md"
dd_expect_contains dreamdry-many "unknown — url: over-limit" "R7 over 10 URLs"
[ "$(wc -l < "$DD_T/probe.log")" -eq 10 ] && dd_ok "R7 exactly 10 URLs probed" || dd_fail "R7 probed $(wc -l < "$DD_T/probe.log")"
dd_expect_rc 4 "R7 over-limit"
dd_tmp_empty "AC5"
dd_finish
