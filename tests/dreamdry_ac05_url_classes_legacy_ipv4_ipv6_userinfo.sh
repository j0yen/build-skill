#!/usr/bin/env bash
# dreamdry_ac05_url_classes_legacy_ipv4_ipv6_userinfo — PRD-dream-dryrun-hook R7 and AC5
# ("a loopback URL is never passed to the prober"; "every distinct http(s):// URL"; "no
# credentials"; loopback/private-range -> `unknown — url: <url> not-public`) and Goals
# ("Every verdict the dry run cannot reach is unknown with its reason, never a default").
# Independent review DRY-MEDIUM-2 (shorthand IPv4 loopback reached the prober),
# DRY-MEDIUM-3 (IPv6 literals dropped silently: a public one answering 404 read eligible),
# DRY-LOW-4 (userinfo forwarded), and test gaps DM3 (private ranges), DM4 (3xx), DM5
# (only Live evidence and Premise: are probed). The fake prober stands in for curl, so
# nothing here reaches the network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamdry-common.sh"
dd_setup
run1() { : > "$DD_T/probe.log"; dd_run --prd-dir "$DD_T/dest" "$@"; }

# DRY-MEDIUM-2: legacy IPv4 spellings of loopback, and other non-global IPv4
legacy=(http://127.1/x http://0177.0.0.1/x http://0x7f.0.0.1/x http://2130706433/x http://0x7f000001/x
        http://127.0.1/x http://017700000001/x http://0x7F.1:8080/x http://127.1./x)
dd_prd_urls "$DD_T/drafts" dreamdry-legacy "${legacy[@]}"
run1 "$DD_T/drafts/PRD-dreamdry-legacy.md"
dd_expect_rc 4 "MEDIUM-2 legacy IPv4 loopback"
for u in "${legacy[@]}"; do dd_expect_contains dreamdry-legacy "url: $u not-public" "MEDIUM-2 $u"; done
[ ! -s "$DD_T/probe.log" ] && dd_ok "MEDIUM-2 no legacy-form loopback URL reached the prober" || dd_fail "MEDIUM-2 prober saw: $(cat "$DD_T/probe.log")"

# DM3: private, link-local, shared, unspecified and reserved IPv4 ranges (dotted and legacy)
priv=(http://10.1.2.3/x http://192.168.1.1/x http://172.16.0.1/x http://169.254.169.254/latest http://100.64.0.1/x
      http://0.0.0.0/x http://10.1/x http://192.0.2.10/x http://0xa9.254.169.254/x)
dd_prd_urls "$DD_T/drafts" dreamdry-priv "${priv[@]}"
run1 "$DD_T/drafts/PRD-dreamdry-priv.md"
dd_expect_rc 4 "DM3 private ranges"
for u in "${priv[@]}"; do dd_expect_contains dreamdry-priv "url: $u not-public" "DM3 $u"; done
[ ! -s "$DD_T/probe.log" ] && dd_ok "DM3 no private-range URL reached the prober" || dd_fail "DM3 prober saw: $(cat "$DD_T/probe.log")"

# names that are not public
names=(http://localhost./x http://foo.localhost/x HTTP://LOCALHOST/x http://intranet/x http://svc.internal/x http://box.local/x)
dd_prd_urls "$DD_T/drafts" dreamdry-names "${names[@]}"
run1 "$DD_T/drafts/PRD-dreamdry-names.md"
for u in "${names[@]}"; do dd_expect_contains dreamdry-names "url: $u not-public" "names $u"; done
[ ! -s "$DD_T/probe.log" ] && dd_ok "names: none reached the prober" || dd_fail "names: prober saw: $(cat "$DD_T/probe.log")"

# DRY-MEDIUM-3: IPv6 literals are classified, never dropped
v6np=('http://[::1]/x' 'http://[::ffff:127.0.0.1]/x' 'http://[fd00::1]/x' 'http://[fe80::1%25eth0]/x'
      'http://[64:ff9b::7f00:1]/x' 'http://[::]/x' 'http://[2002:7f00:1::1]/x' 'https://[::1]:8443/x')
dd_prd_urls "$DD_T/drafts" dreamdry-v6np "${v6np[@]}"
run1 "$DD_T/drafts/PRD-dreamdry-v6np.md"
dd_expect_rc 4 "MEDIUM-3 non-global IPv6 literals"
for u in "${v6np[@]}"; do dd_expect_contains dreamdry-v6np "url: $u not-public" "MEDIUM-3 $u"; done
[ ! -s "$DD_T/probe.log" ] && dd_ok "MEDIUM-3 no non-global IPv6 literal reached the prober" || dd_fail "MEDIUM-3 prober saw: $(cat "$DD_T/probe.log")"

u6='http://[2606:4700:4700::1111]/dreamdry-missing'
dd_prd_urls "$DD_T/drafts" dreamdry-v6pub "$u6"
dd_probe HEAD "$u6" 404
run1 "$DD_T/drafts/PRD-dreamdry-v6pub.md"
dd_expect_line dreamdry-v6pub "admit-would: dreamdry-v6pub ineligible — url: $u6 404 claims=unknown open-runs=unknown" "MEDIUM-3 public IPv6 literal answering 404"
dd_expect_rc 3 "MEDIUM-3 public IPv6 404"
[ "$(cat "$DD_T/probe.log")" = "HEAD $u6" ] && dd_ok "MEDIUM-3 the public IPv6 literal was probed whole, brackets kept" || dd_fail "MEDIUM-3 probe log: $(cat "$DD_T/probe.log")"

# malformed hosts are unknown, never probed
bad=('http://[zz::1]/x' 'http://exa%6dple.com/x' 'http://１２７.0.0.1/x' 'http://a..b.com/x' 'http://999.1.1.1/x' 'http://example.com:99999/x')
dd_prd_urls "$DD_T/drafts" dreamdry-badhost "${bad[@]}"
run1 "$DD_T/drafts/PRD-dreamdry-badhost.md"
dd_expect_rc 4 "malformed hosts"
for u in "${bad[@]}"; do dd_expect_contains dreamdry-badhost "url: $u invalid-host" "malformed $u"; done
[ ! -s "$DD_T/probe.log" ] && dd_ok "malformed hosts: none reached the prober" || dd_fail "malformed: prober saw: $(cat "$DD_T/probe.log")"

# DRY-LOW-4: userinfo is refused, never probed, never printed
secret="s3cr3t-tok3n-dreamdry"
cred=("https://user:$secret@dreamdry.example.com/x" "https://$secret@dreamdry.example.com/y" "http://u:$secret@127.1:9/z")
dd_prd_urls "$DD_T/drafts" dreamdry-cred "${cred[@]}"
run1 "$DD_T/drafts/PRD-dreamdry-cred.md"
dd_expect_rc 4 "LOW-4 userinfo"
dd_expect_contains dreamdry-cred "url: https://***@dreamdry.example.com/x credentials" "LOW-4 user:password redacted"
dd_expect_contains dreamdry-cred "url: https://***@dreamdry.example.com/y credentials" "LOW-4 token-only userinfo redacted"
dd_expect_contains dreamdry-cred "url: http://***@127.1:9/z credentials" "LOW-4 userinfo on a loopback host"
[ ! -s "$DD_T/probe.log" ] && dd_ok "LOW-4 no URL carrying userinfo reached the prober" || dd_fail "LOW-4 prober saw: $(cat "$DD_T/probe.log")"
grep -qF "$secret" <<<"$DD_OUT" && dd_fail "LOW-4 the credential appears in the text output or stderr" || dd_ok "LOW-4 the credential appears nowhere in the text output or stderr"
dd_run --prd-dir "$DD_T/dest" --json "$DD_T/drafts/PRD-dreamdry-cred.md"
grep -qF "$secret" <<<"$DD_OUT" && dd_fail "LOW-4 the credential appears in the --json output" || dd_ok "LOW-4 the credential appears nowhere in the --json output"
grep -qF 'user:' <<<"$DD_OUT" && dd_fail "LOW-4 the user name appears in --json" || dd_ok "LOW-4 the user name is redacted too"

# DM4: 3xx leaves the verdict (no redirect is followed; the prober is asked once)
for c in 301 302 307 308; do
  u="https://dreamdry.example.com/redir-$c"
  dd_prd_urls "$DD_T/drafts" "dreamdry-r$c" "$u"; dd_probe HEAD "$u" "$c"
  run1 "$DD_T/drafts/PRD-dreamdry-r$c.md"
  dd_expect_line "dreamdry-r$c" "admit-would: dreamdry-r$c eligible claims=unknown open-runs=unknown" "DM4 $c leaves the verdict"
  [ "$(wc -l < "$DD_T/probe.log")" -eq 1 ] && dd_ok "DM4 $c: one HEAD, nothing followed" || dd_fail "DM4 $c probe log: $(cat "$DD_T/probe.log")"
done

# DM5: only Live evidence and Premise: are probed — not prose, not a non-Live AC, not other sections
ul="https://dreamdry.example.com/live.csv"; un1="https://dreamdry.example.com/prose-ac.csv"
un2="https://dreamdry.example.com/tldr.csv"; un3="https://dreamdry.example.com/requirement.csv"
dd_prd "$DD_T/drafts" dreamdry-scope "" "3. P0 — Given $un1 in the AC text, When the judge fetches, Then 200. (Live; evidence: \`cmd:curl -sf -o /dev/null $ul\`)"
printf '%s\n' "4. P0 — Given the fixture, When it is read, Then it cites $un1." >> "$DD_T/drafts/PRD-dreamdry-scope.md"
python3 -I - "$DD_T/drafts/PRD-dreamdry-scope.md" "$un2" "$un3" <<'PY'
import sys
p, a, b = sys.argv[1:4]
t = open(p, encoding="utf-8").read()
t = t.replace("## Problem statement\n", f"See {a} for context.\n\n## Problem statement\n", 1)
t = t.replace("- R1. The file stays", f"- R1. Read {b}. The file stays", 1)
open(p, "w", encoding="utf-8").write(t)
PY
run1 "$DD_T/drafts/PRD-dreamdry-scope.md"
[ "$(cat "$DD_T/probe.log")" = "HEAD $ul" ] && dd_ok "DM5 only the Live evidence URL was probed" || dd_fail "DM5 probe log: $(cat "$DD_T/probe.log") :: $DD_OUT"
dd_expect_rc 0 "DM5"
dd_tmp_empty "url classes"
dd_finish
