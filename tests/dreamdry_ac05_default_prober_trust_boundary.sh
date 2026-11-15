#!/usr/bin/env bash
# dreamdry_ac05_default_prober_trust_boundary — PRD-dream-dryrun-hook R7 with the DEFAULT
# prober (no DREAM_DRYRUN_URL_PROBE seam): one HEAD, 5 s, no body, no credentials, no
# redirect following, and a loopback/private URL never probed. Independent review
# DRY-MEDIUM-2 (the default curl prober reached 127.0.0.1 through `127.1`) and the DNS
# boundary it listed. Local-only and offline:
#   [1] a local-only HTTP server on 127.0.0.1 receives NO request for legacy-IPv4,
#       IPv4-mapped-IPv6 and userinfo spellings of its address (the real curl runs);
#   [2] a fake `curl` first on PATH records argv: a name is resolved first (resolver seam
#       DREAM_DRYRUN_RESOLVE), a name resolving to any non-global address is never probed
#       (`not-public (resolves to …)`), a public answer is pinned with --resolve so curl
#       cannot re-resolve elsewhere, and every call carries -q (no .curlrc), --noproxy '*',
#       -g (IPv6 brackets are not globs), --proto =http,https and no -L;
#   [3] a name that does not resolve (`.invalid`, real resolver) is unknown and curl is
#       never called.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamdry-common.sh"
dd_setup
unset DREAM_DRYRUN_URL_PROBE

# [1] local-only server; it stops itself when $DD_T/stop-server appears (or after 120 s)
cat > "$DD_T/server.py" <<'PY'
import http.server, os, sys, time, threading
log, stop, portfile = sys.argv[1:4]
class H(http.server.BaseHTTPRequestHandler):
    def _r(self):
        with open(log, "a") as fh:
            fh.write(f"{self.command} {self.path} auth={self.headers.get('Authorization')}\n")
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
    do_HEAD = do_GET = _r
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_address[1]))
s.timeout = 0.2
t0 = time.time()
while not os.path.exists(stop) and time.time() - t0 < 120:
    s.handle_request()
PY
: > "$DD_T/server.log"
python3 -I "$DD_T/server.py" "$DD_T/server.log" "$DD_T/stop-server" "$DD_T/server.port" &
srv=$!
for _ in $(seq 1 50); do [ -s "$DD_T/server.port" ] && break; sleep 0.1; done
port="$(cat "$DD_T/server.port" 2>/dev/null)"
if [ -n "$port" ] && curl -q -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/control" | grep -q 200 \
   && grep -q '^GET /control' "$DD_T/server.log"; then
  dd_ok "[1] control: the local-only server answers and logs a direct request"
else dd_fail "[1] control: local server not reachable (port '$port')"; fi
: > "$DD_T/server.log"
loop=("http://127.1:$port/ok" "http://0x7f.0.0.1:$port/ok" "http://0177.0.0.1:$port/ok" "http://2130706433:$port/ok"
      "http://[::ffff:127.0.0.1]:$port/ok" "http://user:secret@127.1:$port/ok" "http://localhost.:$port/ok")
dd_prd_urls "$DD_T/drafts" dreamdry-loopsrv "${loop[@]}"
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-loopsrv.md"
dd_expect_rc 4 "[1] loopback spellings"
[ ! -s "$DD_T/server.log" ] && dd_ok "[1] the local-only server received no request from the default prober" || dd_fail "[1] the server received: $(cat "$DD_T/server.log")"
grep -qF secret <<<"$DD_OUT" && dd_fail "[1] the credential was printed" || dd_ok "[1] the credential was not printed"
touch "$DD_T/stop-server"; wait "$srv" 2>/dev/null

# [2] fake curl first on PATH + resolver seam
mkdir -p "$DD_T/fakebin"
cat > "$DD_T/fakebin/curl" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
printf '200'
EOS
cat > "$DD_T/fakebin/resolve" <<'EOS'
#!/usr/bin/env bash
# fake resolver: `resolve <host>` prints one address per line
printf '%s\n' "$1" >> "$FAKE_RESOLVE_LOG"
case "$1" in
  loopback-alias.dreamdry.test) echo 127.0.0.1 ;;
  v6-loop.dreamdry.test)        echo ::1 ;;
  mixed.dreamdry.test)          printf '93.184.215.14\n10.0.0.5\n' ;;
  public-alias.dreamdry.test)   printf '93.184.215.14\n2606:2800:21f:cb07:6820:80da:af6b:8b2c\n' ;;
  *) echo "no such host" >&2; exit 2 ;;
esac
EOS
chmod +x "$DD_T/fakebin/curl" "$DD_T/fakebin/resolve"
export FAKE_CURL_LOG="$DD_T/curl.log" FAKE_RESOLVE_LOG="$DD_T/resolve.log"
: > "$FAKE_CURL_LOG"; : > "$FAKE_RESOLVE_LOG"
names=("https://loopback-alias.dreamdry.test/x" "https://v6-loop.dreamdry.test/x" "https://mixed.dreamdry.test/x" "https://unknown.dreamdry.test/x")
dd_prd_urls "$DD_T/drafts" dreamdry-dns "${names[@]}"
PATH="$DD_T/fakebin:$PATH" DREAM_DRYRUN_RESOLVE="$DD_T/fakebin/resolve" dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-dns.md"
dd_expect_rc 4 "[2] private resolution"
dd_expect_contains dreamdry-dns "url: https://loopback-alias.dreamdry.test/x not-public (resolves to 127.0.0.1)" "[2] name resolving to loopback"
dd_expect_contains dreamdry-dns "url: https://v6-loop.dreamdry.test/x not-public (resolves to ::1)" "[2] name resolving to IPv6 loopback"
dd_expect_contains dreamdry-dns "url: https://mixed.dreamdry.test/x not-public (resolves to 10.0.0.5)" "[2] any non-global answer refuses"
dd_expect_contains dreamdry-dns "url: https://unknown.dreamdry.test/x resolve: no such host" "[2] resolver failure is unknown"
[ ! -s "$FAKE_CURL_LOG" ] && dd_ok "[2] curl never ran for a name resolving privately or not at all" || dd_fail "[2] curl ran: $(cat "$FAKE_CURL_LOG")"

: > "$FAKE_CURL_LOG"; : > "$FAKE_RESOLVE_LOG"
pub=("https://public-alias.dreamdry.test/data.csv" "http://93.184.215.14/x" "http://[2606:2800:21f:cb07:6820:80da:af6b:8b2c]:8080/x")
dd_prd_urls "$DD_T/drafts" dreamdry-pin "${pub[@]}"
PATH="$DD_T/fakebin:$PATH" DREAM_DRYRUN_RESOLVE="$DD_T/fakebin/resolve" dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-pin.md"
dd_expect_line dreamdry-pin "admit-would: dreamdry-pin eligible claims=unknown open-runs=unknown" "[2] public answers probed"
c1="$(grep -F 'public-alias.dreamdry.test/data.csv' "$FAKE_CURL_LOG")"
if grep -qF -- '--resolve public-alias.dreamdry.test:443:93.184.215.14,[2606:2800:21f:cb07:6820:80da:af6b:8b2c]' <<<"$c1"; then
  dd_ok "[2] a resolved name is pinned to the checked addresses (--resolve), so curl cannot re-resolve"
else dd_fail "[2] no --resolve pin: $c1"; fi
[ "$(cat "$FAKE_RESOLVE_LOG")" = "public-alias.dreamdry.test" ] && dd_ok "[2] IP literals are not sent to the resolver" || dd_fail "[2] resolver log: $(cat "$FAKE_RESOLVE_LOG")"
n=0
while IFS= read -r ln; do
  n=$((n + 1))
  case " $ln " in *" -L "*|*" --location "*) dd_fail "[2] curl was told to follow redirects: $ln" ;; esac
  for want in "-q " " --noproxy * " " -g " " --proto =http,https " " --max-time 5 " " -I " " -o /dev/null "; do
    grep -qF -- "$want" <<<" $ln " || dd_fail "[2] curl argv lacks '$want': $ln"
  done
  [[ "$ln" == "-q "* ]] || dd_fail "[2] -q is not the first argument (a .curlrc would be read): $ln"
done < "$FAKE_CURL_LOG"
[ "$n" -eq 3 ] && dd_ok "[2] three HEAD probes, each with -q first, --noproxy '*', -g, --proto =http,https, --max-time 5, no -L" || dd_fail "[2] curl calls: $n :: $(cat "$FAKE_CURL_LOG")"

# [3] the real resolver: a name that cannot resolve is unknown and curl never runs
: > "$FAKE_CURL_LOG"
dd_prd_urls "$DD_T/drafts" dreamdry-nxd "https://dreamdry-none.invalid/x"
PATH="$DD_T/fakebin:$PATH" dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-nxd.md"
dd_expect_contains dreamdry-nxd "unknown — url: https://dreamdry-none.invalid/x resolve:" "[3] .invalid does not resolve: unknown"
dd_expect_rc 4 "[3]"
[ ! -s "$FAKE_CURL_LOG" ] && dd_ok "[3] curl never ran for an unresolvable name" || dd_fail "[3] curl ran: $(cat "$FAKE_CURL_LOG")"
dd_tmp_empty "default prober"
dd_finish
