#!/usr/bin/env bash
# dream-seeds.sh — /dream hook `dream.seeds` (Phase 0): find the newest chain
# digest + dream seed and say whether they belong to the SAME chain run, then
# list the open families a /dream may draft from.
#
# Read-only. Reads orch over ssh (non-login: the PATH export is part of every
# remote command), files under ~/.local/state/synthorg/runs/:
#   digest: newest of  chain-digest-<date>.md (not *-evidence) and chain-*/digest.md
#   seed:   newest of  dream-seed-latest.md and chain-*/dream-seed.md
# The midnight timer is disabled and one-shot runs write their own roots, so
# both can be overridden.
#
# Usage:
#   dream-seeds.sh [--digest <path>] [--seed <path>]
#   dream-seeds.sh --selftest
#     <path> is a local file, or `orch:<path>` / an absolute path on orch when
#     it does not exist locally and the default host is used (see env).
#
# Env:
#   DREAM_SEEDS_SSH   command that runs a shell string on orch (default `ssh orch`).
#   DREAM_SEEDS_RUNS  runs dir on orch (default $HOME/.local/state/synthorg/runs).
#
# Output:
#   seed: <chain id>   (<path>)
#   digest: <chain id> (<path>)
#   MATCH | MISMATCH
#   <family-id> count=<n> owner=host why-1=<...>      one per `## Family:` block with
#                                                    covered-by none and owner host
#   hand-PR: <family-id> count=<n> why-1=<...>        covered-by none, owner harness
# Exit: 0 MATCH | 2 MISMATCH (or an id could not be read) | 1 usage / read error
set -uo pipefail

SSH="${DREAM_SEEDS_SSH:-ssh orch}"
RUNS="${DREAM_SEEDS_RUNS:-\$HOME/.local/state/synthorg/runs}"
PATHX='export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH;'

remote() { $SSH "$PATHX $1"; }

# newest <glob...> under the runs dir, by mtime, excluding *-evidence files
newest() { # $1=space-separated globs
  remote "cd $RUNS 2>/dev/null && ls -t $1 2>/dev/null | grep -v -- '-evidence' | head -1"
}

cat_file() { # $1=path (local if it exists, else on orch; relative = under the runs dir)
  if [ -f "$1" ]; then cat "$1"; return; fi
  case "$1" in
    /*|\$HOME/*|~/*) remote "cat \"$1\"" ;;
    *) remote "cat $RUNS/\"$1\"" ;;
  esac
}

# parse <seed|digest text on stdin> -> chain id
chain_id() {
  grep -oE 'chain-[0-9]{8}T[0-9]{6}Z' | head -1
}

parse_families() { # stdin = seed text
  python3 -c '
import re, sys
text = sys.stdin.read()
host, harness = [], []
for blk in re.split(r"(?m)^## Family:", text)[1:]:
    head, _, rest = blk.partition("\n")
    m = re.match(r"\s*(\S+)\s*[—–-]+\s*(\d+)", head)
    if not m:
        continue
    fam, count = m.group(1), m.group(2)
    def field(name):
        mm = re.search(r"(?m)^- " + name + r":\s*(.*)$", rest)
        return mm.group(1).strip() if mm else ""
    if field("covered-by").lower() != "none":
        continue
    why = field("why-1")
    owner = field("owner").lower()
    (harness if owner == "harness" else host).append((fam, count, why))
for fam, count, why in host:
    print(f"{fam} count={count} owner=host why-1={why}")
for fam, count, why in harness:
    print(f"hand-PR: {fam} count={count} why-1={why}")
'
}

run() {
  local digest="" seed=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --digest) digest="${2:-}"; shift 2 ;;
      --seed) seed="${2:-}"; shift 2 ;;
      -h|--help) sed -n '2,32p' "$0"; return 0 ;;
      *) echo "usage: dream-seeds.sh [--digest <path>] [--seed <path>]" >&2; return 1 ;;
    esac
  done
  [ -n "$digest" ] || digest="$(newest 'chain-digest-[0-9]*.md chain-*/digest.md')"
  [ -n "$seed" ] || seed="$(newest 'dream-seed-latest.md chain-*/dream-seed.md')"
  if [ -z "$digest" ] || [ -z "$seed" ]; then
    echo "dream-seeds: could not find a digest and a seed (digest='${digest}' seed='${seed}')" >&2
    return 1
  fi
  local seed_txt digest_txt sid did
  seed_txt="$(cat_file "$seed")" || { echo "dream-seeds: cannot read seed $seed" >&2; return 1; }
  digest_txt="$(cat_file "$digest" | head -40)" || { echo "dream-seeds: cannot read digest $digest" >&2; return 1; }
  sid="$(printf '%s\n' "$seed_txt" | head -3 | chain_id)"
  did="$(printf '%s\n' "$digest_txt" | chain_id)"
  echo "seed: ${sid:-unknown} ($seed)"
  echo "digest: ${did:-unknown} ($digest)"
  local rc=0
  if [ -n "$sid" ] && [ "$sid" = "$did" ]; then
    echo "MATCH"
  else
    echo "MISMATCH"
    rc=2
  fi
  printf '%s\n' "$seed_txt" | parse_families
  return $rc
}

selftest() {
  local t fails=0 total=0 out rc
  t="$(mktemp -d)"; trap 'rm -rf "$t"' RETURN
  mkdir -p "$t/runs/chain-20261022T000000Z" "$t/runs/chain-20261021T000000Z"
  cat > "$t/runs/chain-20261022T000000Z/digest.md" <<'EOF'
# Chain digest — 2026-10-22 · chain-20261022T000000Z · started 10:26 pm PDT
EOF
  cat > "$t/runs/chain-20261022T000000Z/dream-seed.md" <<'EOF'
# Seed — chain chain-20261022T000000Z · 12:00 am PDT · prod 0.1

Seed-format: 1

## Family: fam-host — 9 (prev 0, Δ +9) · truth-tier
- why-1: Why 9? something at /x
- covered-by: none
- owner: host

## Family: fam-covered — 3 (prev 0, Δ +3) · explore
- why-1: Why 3?
- covered-by: PRD-x.md
- owner: host

## Family: fam-harness — 5 (prev 0, Δ +5) · conformance
- why-1: Why 5? fixture
- covered-by: none
- owner: harness
EOF
  sed 's/20261022T000000Z/20261021T000000Z/g' "$t/runs/chain-20261022T000000Z/dream-seed.md" > "$t/runs/dream-seed-latest.md"
  touch -d '2 days ago' "$t/runs/dream-seed-latest.md"
  SSH="bash -c"; RUNS="$t/runs"
  ck() { # $1=label $2=want-rc $3=grep-pattern(s, one per line) ; $4... args
    local label="$1" want="$2" pats="$3"; shift 3
    total=$((total+1))
    out="$(run "$@" 2>&1)"; rc=$?
    local bad=""
    [ "$rc" -eq "$want" ] || bad="exit=$rc want $want"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      grep -q -- "$p" <<<"$out" || bad="$bad; missing /$p/"
    done <<<"$pats"
    if [ -z "$bad" ]; then echo "ok: $label"; else echo "FAIL: $label: $bad :: $out"; fails=$((fails+1)); fi
  }
  # newest seed + newest digest are the same one-shot chain -> MATCH
  ck "defaults pick the newest one-shot root, MATCH" 0 \
"^seed: chain-20261022T000000Z
^digest: chain-20261022T000000Z
^MATCH
^fam-host count=9 owner=host why-1=Why 9
^hand-PR: fam-harness count=5"
  total=$((total+1))
  if grep -q 'fam-covered' <<<"$out"; then echo "FAIL: covered family listed"; fails=$((fails+1)); else echo "ok: covered-by family omitted"; fi
  # stale seed override -> MISMATCH, exit 2
  ck "stale seed override -> MISMATCH exit 2" 2 "^MISMATCH
^seed: chain-20261021T000000Z" --seed "$t/runs/dream-seed-latest.md"
  ck "digest+seed overrides (local paths)" 0 "^MATCH" \
    --digest "$t/runs/chain-20261022T000000Z/digest.md" --seed "$t/runs/chain-20261022T000000Z/dream-seed.md"
  # path relative to the runs dir
  ck "runs-relative path" 0 "^MATCH" --digest chain-20261022T000000Z/digest.md --seed chain-20261022T000000Z/dream-seed.md
  # nothing to read
  RUNS="$t/none"; ck "no files -> exit 1" 1 "could not find"; RUNS="$t/runs"
  if [ "$fails" -ne 0 ]; then echo "SELFTEST FAILED ($fails/$total checks)"; return 1; fi
  echo "SELFTEST PASSED ($total checks)"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
esac
run "$@"
