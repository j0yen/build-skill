#!/usr/bin/env bash
# classification-self-heal.sh — PRD-build-classification-self-heal.
#
# Closes the loop the 2026-09-12 five-whys found: a build_target that
# contradicts the substrate at build_into passed prd-lint.sh twice (fixed
# separately, see prd-lint.sh's build-into-substrate-mismatch check), then
# bounced three identical dispatches in 77 minutes -- each one independently
# re-discovering the same mismatch via ls/find/cat Cargo.toml and asking for
# a human -- until a manual tick fixed the frontmatter from evidence any
# tick could read. This script is the automated version of that manual fix,
# plus the bookkeeping that stops a repeat diagnosis from costing a second
# (or third) dispatch.
#
# Subcommands:
#   classification-self-heal.sh probe <build_into-path> [--format text|json]
#       Thin passthrough to substrate-probe.sh (kept as its own subcommand
#       so a caller never has to know two script names).
#
#   classification-self-heal.sh bounce-check <prd-file> <lint-id> <lint-msg>
#       Requirement 2 + P1 bounce budget. Reads the manifest cache entry for
#       this PRD (read-only) and this call's (lint-id, lint-msg, current
#       build_target/build_into) to decide: first time seeing this
#       diagnosis -> record it (a fresh "bounce"); same diagnosis as the
#       last recorded bounce (frontmatter-and-diagnosis hash unchanged) ->
#       journal ONE skip line (never a second one for the same unchanged
#       state) and, on the SECOND unchanged bounce, raise ONE alarm
#       (journal + docket, fail-open) instead of letting a third dispatch
#       happen; diagnosis changed since the last bounce -> treat as a fresh
#       bounce (reset the count). All manifest writes go through
#       manifest-set.sh, same as every other Phase 1/7 writer. Always exits
#       0 -- this is bookkeeping, not a dispatch gate (needs_classification
#       PRDs are already outside Phase 2's candidate pool by construction;
#       this call's value is the dedup + alarm, not new exclusion logic).
#
#   classification-self-heal.sh resolve <prd-file>
#       Requirement 3. Only touches a PRD whose Status is already
#       needs_classification. Probes build_into's substrate
#       (substrate-probe.sh's algorithm) and self-heals build_target ONLY
#       when the evidence is mechanically unambiguous (exactly one of
#       Cargo.toml / pyproject.toml present under build_into) -- a mixed
#       substrate (both present) or no substrate at all (neither present,
#       or build_into doesn't exist) declines and leaves the PRD parked for
#       a human, per this PRD's own Non-Goals. On success: rewrites
#       build_target, sets Status: queued, appends an iter_log entry naming
#       the probes and the decision (same evidence-bar as the manual
#       2026-09-12 17:15:00Z fix this replaces), commits with the Joe Yen
#       identity and pushes (git plumbing mirrors mark-needs-
#       classification.sh's pull/commit/push-with-one-retry, run in the
#       opposite direction), then updates the manifest cache to match so
#       the next scan doesn't have to wait on a reconcile pass.
#
# Exit codes (resolve): 0 resolved-and-pushed | 1 declined (not eligible,
#   ambiguous, no evidence, or build_into missing -- message says which,
#   caller keeps the PRD parked exactly as before) | 2 usage error |
#   3 push-failed (commit landed locally) | 4 local git/write error.
# Exit codes (bounce-check, probe): 0 always, except 2 for a usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${BUILD_SKILL_DIR:-$(cd "$HERE/.." && pwd)}"
STATE_DIR="${BUILD_STATE_DIR:-$SKILL_DIR/state}"
MANIFEST="${BUILD_MANIFEST:-$STATE_DIR/manifest.json}"
MANIFEST_SET="${MANIFEST_SET:-$HERE/manifest-set.sh}"
SUBSTRATE_PROBE="${SUBSTRATE_PROBE:-$HERE/substrate-probe.sh}"
JOURNAL="${JOURNAL:-$HOME/brain/journal/build/$(date -u +%F).md}"
DOCKET_RUN="${DOCKET_RUN:-classification-self-heal.$(date -u +%Y%m%dT%H%M%SZ)}"
GIT_ID=(-c user.email=jyen.tech@gmail.com -c user.name="Joe Yen")

log() { printf 'classification-self-heal: %s\n' "$*" >&2; }
die() { log "$*"; exit "${2:-4}"; }

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

slug_of() {
  local base; base="$(basename "$1")"
  base="${base#PRD-}"
  base="${base%.md}"
  printf '%s' "$base"
}

# Same first-80-lines / bullet-bare-bold reader every other script in this
# directory duplicates rather than sources (see select-guard.sh's own
# read_field comment for the precedent).
read_field() {
  local f="$1" key="$2"
  head -n 80 "$f" \
    | grep -E "^(- *${key}:|${key}:|\*\*${key}:\*\*)" | head -n1 \
    | sed -E "s/^(- *${key}:|${key}:|\*\*${key}:\*\*)[[:space:]]*//" \
    | sed -E 's/[[:space:]]*#.*$//' \
    | sed -E 's/[[:space:]]+$//'
}

manifest_entry_json() {
  # Read-only manifest lookup. Prints "{}" if the manifest, or this slug's
  # entry, is missing/unreadable -- callers treat that as "no prior bounce".
  local slug="$1"
  MANIFEST="$MANIFEST" python3 -c '
import json, os, sys
slug = sys.argv[1]
try:
    m = json.load(open(os.environ["MANIFEST"]))
except Exception:
    print("{}"); sys.exit()
prds = m.get("prds", {})
entry = prds.get(slug) if isinstance(prds, dict) else next(
    (p for p in prds if isinstance(p, dict) and p.get("slug") == slug), None)
print(json.dumps(entry or {}))
' "$slug"
}

entry_field() { # $1=json $2=key -> raw string ("" if absent/null)
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
v = d.get(sys.argv[2])
print("" if v is None else v)
' "$1" "$2"
}

sha_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

usage() {
  cat >&2 <<'EOF'
usage:
  classification-self-heal.sh probe <build_into-path> [--format text|json]
  classification-self-heal.sh bounce-check <prd-file> <lint-id> <lint-msg>
  classification-self-heal.sh resolve <prd-file>
EOF
}

cmd_probe() {
  [ -x "$SUBSTRATE_PROBE" ] || die "substrate-probe.sh not found or not executable: $SUBSTRATE_PROBE" 4
  exec "$SUBSTRATE_PROBE" "$@"
}

cmd_bounce_check() {
  [ "$#" -ge 3 ] || { usage; exit 2; }
  local prd_file="$1" lint_id="$2" lint_msg="$3"
  [ -f "$prd_file" ] || die "no such file: $prd_file" 4
  local slug; slug="$(slug_of "$prd_file")"
  local build_target build_into
  build_target="$(read_field "$prd_file" build_target)"
  build_into="$(read_field "$prd_file" build_into)"
  local hash; hash="$(sha_of "${build_target}|${build_into}|${lint_id}|${lint_msg}")"

  local entry status stored_hash bounces
  entry="$(manifest_entry_json "$slug")"
  status="$(entry_field "$entry" status)"
  stored_hash="$(entry_field "$entry" needs_classification_hash)"
  bounces="$(entry_field "$entry" needs_classification_bounces)"
  case "$bounces" in ''|*[!0-9]*) bounces=0 ;; esac

  mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null || true

  if [ "$status" != "needs_classification" ] || [ -z "$stored_hash" ]; then
    # Fresh bounce: first time this PRD is being parked, or the manifest
    # cache has no recorded hash yet (e.g. pre-upgrade entry).
    local tmp; tmp="$(mktemp)" || { log "mktemp failed"; exit 0; }
    python3 -c 'import json,sys; print(json.dumps({
      "status":"needs_classification",
      "needs_classification_reason": sys.argv[1] + ": " + sys.argv[2],
      "needs_classification_hash": sys.argv[3],
      "needs_classification_bounces": 1}))' \
      "$lint_id" "$lint_msg" "$hash" >"$tmp"
    "$MANIFEST_SET" "$slug" "$tmp" 1>&2 || log "manifest write failed for $slug (fresh bounce)"
    rm -f "$tmp"
    printf '%s  %s  bounce  parked  (id=%s bounces=1 lane=%s)\n' \
      "$(utc_now)" "$slug" "$lint_id" "$(hostname)" >> "$JOURNAL"
    echo "bounce: $slug fresh (bounces=1)"
    exit 0
  fi

  if [ "$stored_hash" = "$hash" ]; then
    local new_bounces=$((bounces + 1))
    local tmp; tmp="$(mktemp)" || { log "mktemp failed"; exit 0; }
    printf '{"needs_classification_bounces":%d}' "$new_bounces" >"$tmp"
    "$MANIFEST_SET" "$slug" "$tmp" 1>&2 || log "manifest write failed for $slug (bounce count)"
    rm -f "$tmp"
    # Requirement 2: one skip line per tick, not per branch -- this call
    # site (scan-prds.sh's run_lint_pass) runs exactly once per tick.
    printf '%s  %s  skip  needs_classification-unchanged  (id=%s bounces=%d lane=%s)\n' \
      "$(utc_now)" "$slug" "$lint_id" "$new_bounces" "$(hostname)" >> "$JOURNAL"
    echo "skip: $slug unchanged since last bounce (bounces=$new_bounces)"
    if [ "$new_bounces" -eq 2 ]; then
      # P1: the SECOND consecutive identical diagnosis raises one alarm,
      # instead of letting a third dispatch happen.
      local message="needs_classification twice with identical diagnosis: $lint_id: $lint_msg"
      printf '%s  %s  alarm  %s  (class=classification-bounce lane=%s)\n' \
        "$(utc_now)" "$slug" "$message" "$(hostname)" >> "$JOURNAL"
      if command -v docket >/dev/null 2>&1; then
        docket report --run "$DOCKET_RUN" --key "classification-bounce-$slug" \
          --title "$message" --severity warn >/dev/null 2>&1 \
          || log "docket report failed for classification-bounce-$slug (fail-open, journal line already written)"
      fi
    fi
    exit 0
  fi

  # Diagnosis changed since the last recorded bounce -> fresh bounce, reset.
  local tmp; tmp="$(mktemp)" || { log "mktemp failed"; exit 0; }
  python3 -c 'import json,sys; print(json.dumps({
    "status":"needs_classification",
    "needs_classification_reason": sys.argv[1] + ": " + sys.argv[2],
    "needs_classification_hash": sys.argv[3],
    "needs_classification_bounces": 1}))' \
    "$lint_id" "$lint_msg" "$hash" >"$tmp"
  "$MANIFEST_SET" "$slug" "$tmp" 1>&2 || log "manifest write failed for $slug (changed diagnosis)"
  rm -f "$tmp"
  printf '%s  %s  bounce  parked-diagnosis-changed  (id=%s bounces=1 lane=%s)\n' \
    "$(utc_now)" "$slug" "$lint_id" "$(hostname)" >> "$JOURNAL"
  echo "bounce: $slug diagnosis changed (bounces=1)"
  exit 0
}

cmd_resolve() {
  [ "$#" -ge 1 ] || { usage; exit 2; }
  local prd_file="$1"
  [ -f "$prd_file" ] || die "no such file: $prd_file" 4
  local slug; slug="$(slug_of "$prd_file")"

  local status; status="$(read_field "$prd_file" Status)"
  case "$status" in
    needs_classification)
      # Already durably parked (e.g. a branch's mark-needs-classification.sh
      # call from a prior tick) -- the common "revisit an already-parked PRD"
      # path.
      ;;
    queued)
      # The lint gate catches a mismatch the same tick it first appears,
      # before anything commits Status: needs_classification into the file
      # itself (scan-prds.sh's lint pass only ever touches the manifest
      # cache, never the file -- see build-contract.md's Lint gate
      # section). Requirement 3 explicitly wants THIS moment resolved in
      # one dispatch, not after a park-then-revisit round trip, so a
      # `queued` PRD is just as eligible as an already-parked one. Either
      # way, the probe below independently re-derives the mismatch itself
      # (branch-message-trust convention: never trust a caller's claim
      # without re-checking) -- an incorrectly-invoked resolve on a PRD
      # that isn't actually mismatched declines via the "already consistent"
      # guard further down.
      ;;
    *)
      echo "declined: $slug: Status is '${status:-<none>}', not queued or needs_classification"
      exit 1
      ;;
  esac

  local build_target build_into
  build_target="$(read_field "$prd_file" build_target)"
  build_into="$(read_field "$prd_file" build_into)"
  if [ -z "$build_into" ]; then
    echo "declined: $slug: no build_into set -- nothing to probe, park for a human"
    exit 1
  fi
  if [ ! -d "$build_into" ]; then
    # Non-Goal / AC6: a build_into that does not exist parks exactly as
    # today -- no auto-resolution attempt (can't tell "genuinely missing"
    # from "exists on a different fleet host" from here).
    echo "declined: $slug: build_into '$build_into' does not exist on this host -- no auto-resolution attempt"
    exit 1
  fi

  [ -x "$SUBSTRATE_PROBE" ] || die "substrate-probe.sh not found or not executable: $SUBSTRATE_PROBE" 4
  local probe_json; probe_json="$("$SUBSTRATE_PROBE" "$build_into" --format json)"
  local substrate cargo_toml cargo_members pyproject_toml pyproject_dirs
  substrate="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["substrate"])' "$probe_json")"
  cargo_toml="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["cargo_toml"])' "$probe_json")"
  cargo_members="$(python3 -c 'import json,sys; print(",".join(json.loads(sys.argv[1])["cargo_members"]))' "$probe_json")"
  pyproject_toml="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["pyproject_toml"])' "$probe_json")"
  pyproject_dirs="$(python3 -c 'import json,sys; print(",".join(json.loads(sys.argv[1])["pyproject_dirs"]))' "$probe_json")"

  local new_target=""
  case "$substrate" in
    mixed)
      echo "declined: $slug: mixed substrate at '$build_into' (Cargo.toml and pyproject.toml both present) -- ambiguous, park for a human"
      exit 1
      ;;
    none)
      echo "declined: $slug: no substrate evidence at '$build_into' (neither Cargo.toml nor pyproject.toml found) -- park for a human"
      exit 1
      ;;
    cargo)
      new_target="rust-extend"
      ;;
    python)
      # "the matching python-*" (requirement 3): prefer whichever python-*
      # suffix the PRD's own text already names (Technical considerations /
      # reuse targets commonly say so), default python-cli otherwise --
      # cli is this workspace's documented default shape (build-contract.md).
      if grep -qE '\bpython-agent\b' "$prd_file"; then
        new_target="python-agent"
      elif grep -qE '\bpython-lib\b' "$prd_file"; then
        new_target="python-lib"
      else
        new_target="python-cli"
      fi
      ;;
    *)
      echo "declined: $slug: unrecognized substrate '$substrate' at '$build_into' -- park for a human"
      exit 1
      ;;
  esac

  if [ "$new_target" = "$build_target" ]; then
    echo "declined: $slug: probed substrate ($substrate) already matches build_target ($build_target) -- nothing to fix, leaving parked for the next lint pass to re-confirm"
    exit 1
  fi

  # ---- resolve is genuinely mechanically unambiguous past this point -----
  local root; root="$(git -C "$(dirname "$prd_file")" rev-parse --show-toplevel 2>/dev/null)" \
    || die "$prd_file is not inside a git repo" 4
  local prd_abs; prd_abs="$(cd "$(dirname "$prd_file")" && pwd)/$(basename "$prd_file")"
  local prd_rel="${prd_abs#"$root"/}"

  git_pull_or_die() {
    local r="$1" pre_head
    pre_head="$(git -C "$r" rev-parse HEAD 2>/dev/null)"
    if git -C "$r" pull --rebase --autostash -q 2>/tmp/classification-self-heal.pull.err; then
      [ -z "$(git -C "$r" diff --name-only --diff-filter=U 2>/dev/null)" ] && return 0
    fi
    if [ -d "$r/.git/rebase-apply" ] || [ -d "$r/.git/rebase-merge" ]; then
      git -C "$r" rebase --abort 2>/dev/null
    else
      git -C "$r" reset --hard -q "$pre_head" 2>/dev/null
      git -C "$r" stash pop -q 2>/dev/null
    fi
    cat /tmp/classification-self-heal.pull.err >&2
    die "checkout-conflict: rebase conflict pulling $r; aborted and restored" 4
  }
  git_pull_or_die "$root"

  # Re-check post-pull: a sibling may have already resolved or re-diagnosed
  # this PRD while we were probing.
  status="$(read_field "$prd_abs" Status)"
  case "$status" in
    queued|needs_classification) ;;
    *)
      echo "declined: $slug: Status changed to '${status:-<none>}' during pull (sibling already acted) -- not resolving"
      exit 1
      ;;
  esac

  local iso_ts; iso_ts="$(utc_now)"
  local evidence="probed build_into=$build_into; Cargo.toml=$cargo_toml members=[${cargo_members}]; pyproject.toml=$pyproject_toml dirs=[${pyproject_dirs}]; decision: exactly one substrate-consistent target ($substrate)"
  local iter_line="auto-resolved: build_target $build_target -> $new_target ($evidence)"

  python3 - "$prd_abs" "$new_target" "$iso_ts" "$iter_line" <<'PYEOF'
import re, sys
f, new_target, iso_ts, iter_line = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(f) as fh:
    lines = fh.readlines()
head = lines[:80]
rest = lines[80:]

status_re = re.compile(r'^(?P<pre>-\s*Status:|Status:|\*\*Status:\*\*)\s*(?P<val>.*)$')
target_re = re.compile(r'^(?P<pre>-\s*build_target:|build_target:|\*\*build_target:\*\*)\s*(?P<val>.*)$')
lane_re = re.compile(r'^(?:-\s*Lane:|Lane:|\*\*Lane:\*\*)\s*.*$')
iter_re = re.compile(r'^(?:-\s*iter_log:|iter_log:|\*\*iter_log:\*\*)\s*.*$')

status_idx = None
target_idx = None
for i, ln in enumerate(head):
    s = ln.rstrip('\n')
    if status_idx is None and status_re.match(s):
        status_idx = i
    if target_idx is None and target_re.match(s):
        target_idx = i

if status_idx is not None:
    m = status_re.match(head[status_idx].rstrip('\n'))
    head[status_idx] = f"{m.group('pre')} queued\n"
if target_idx is not None:
    m = target_re.match(head[target_idx].rstrip('\n'))
    head[target_idx] = f"{m.group('pre')} {new_target}\n"

head = [ln for i, ln in enumerate(head)
        if not lane_re.match(ln.rstrip('\n'))]

status_idx = next((i for i, ln in enumerate(head) if status_re.match(ln.rstrip('\n'))), 0)
last_iter_idx = None
for i, ln in enumerate(head):
    if iter_re.match(ln.rstrip('\n')):
        last_iter_idx = i

new_line = f"- iter_log: {iso_ts} {iter_line}\n"
insert_at = (last_iter_idx + 1) if last_iter_idx is not None else (status_idx + 1)
head.insert(insert_at, new_line)

with open(f, 'w') as fh:
    fh.writelines(head + rest)
PYEOF
  [ $? -eq 0 ] || die "write: failed writing build_target/Status/iter_log into $prd_rel" 4

  git -C "$root" add -- "$prd_rel" || die "add: git add failed for $prd_rel" 4
  if git -C "$root" diff --cached --quiet -- "$prd_rel"; then
    die "commit: nothing staged after header write -- aborting" 4
  fi

  local subject="$slug: auto-resolved needs_classification — build_target $build_target -> $new_target"
  git -C "$root" "${GIT_ID[@]}" commit -q -m "$subject" -- "$prd_rel" \
    || die "commit: git commit failed" 4
  local commit_sha; commit_sha="$(git -C "$root" rev-parse HEAD)"

  push_or_die() {
    local r="$1" branch
    branch=$(git -C "$r" symbolic-ref --short HEAD)
    if git -C "$r" push origin "$branch" -q 2>/tmp/classification-self-heal.push.err; then
      return 0
    fi
    if ! git -C "$r" fetch origin -q 2>/tmp/classification-self-heal.fetch.err; then
      cat /tmp/classification-self-heal.fetch.err >&2
      die "push-failed: origin unreachable during push for $r; commit $commit_sha left local" 3
    fi
    if ! git -C "$r" rebase "origin/$branch" -q 2>/tmp/classification-self-heal.rebase.err; then
      git -C "$r" rebase --abort >/dev/null 2>&1 || true
      cat /tmp/classification-self-heal.rebase.err >&2
      die "push-failed: rebase conflict against origin/$branch for $r; commit $commit_sha left local" 3
    fi
    if git -C "$r" push origin "$branch" -q 2>/tmp/classification-self-heal.push2.err; then
      return 0
    fi
    cat /tmp/classification-self-heal.push2.err >&2
    die "push-failed: push still rejected after rebase retry for $r; commit $commit_sha left local" 3
  }
  push_or_die "$root"

  # Keep the local manifest cache in step (same pattern scan-prds.sh's own
  # lint-restore branch uses) so the next Phase 2 selection this same tick
  # doesn't have to wait on a reconcile pass to see this PRD as queued.
  local tmp; tmp="$(mktemp)" || tmp=""
  if [ -n "$tmp" ]; then
    python3 -c 'import json,sys; print(json.dumps({
      "status":"queued","build_target":sys.argv[1],
      "needs_classification_reason":"",
      "needs_classification_hash":"",
      "needs_classification_bounces":0}))' "$new_target" >"$tmp"
    "$MANIFEST_SET" "$slug" "$tmp" 1>&2 || log "manifest write failed for $slug (post-resolve)"
    rm -f "$tmp"
  fi

  mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null || true
  printf '%s  %s  auto-resolve  resolved  (from=%s to=%s substrate=%s commit=%s lane=%s)\n' \
    "$iso_ts" "$slug" "$build_target" "$new_target" "$substrate" "$commit_sha" "$(hostname)" >> "$JOURNAL"

  echo "resolved: $slug $build_target -> $new_target $commit_sha"
  exit 0
}

main() {
  [ "$#" -ge 1 ] || { usage; exit 2; }
  local sub="$1"; shift
  case "$sub" in
    probe) cmd_probe "$@" ;;
    bounce-check) cmd_bounce_check "$@" ;;
    resolve) cmd_resolve "$@" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "classification-self-heal: unknown subcommand: $sub" >&2; usage; exit 2 ;;
  esac
}

main "$@"
