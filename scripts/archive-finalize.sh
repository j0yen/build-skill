#!/usr/bin/env bash
# archive-finalize.sh — the missing "do the clerical chores the archive
# gate is complaining about" actuator. Per PRD-build-archive-finalize.
#
# A /build archive gate (verified-completed) can fail a done/complete
# candidate purely on POST-BUILD CLERICAL checks — repo never pushed, no
# README, missing CHANGELOG section, absent REPOS.md entry — while the
# real functionality (C1 tests green) and AC pairing (C5) are fine. Such
# PRDs re-fail the gate every time they're re-selected, burning ticks
# without progress.
#
# This helper performs ONLY those clerical fixes (gate checks C2/C3/C4),
# and is fenced so it can NEVER paper over a real gap:
#   * It refuses to run unless C1 (tests) AND C5 (AC pairing) already pass.
#   * It never writes a test file, never edits src/, never alters AC
#     pairing. It only touches README.md / CHANGELOG.md / REPOS.md and
#     pushes already-built commits.
#   * Every commit is path-scoped — a dirty unrelated file is never swept
#     in (honors the 2026-06-03 path-scoped-commit lesson).
#
# Usage:
#   archive-finalize.sh <slug> [options]
#
# Options:
#   --dry-run              Print the planned steps and the would-be commit
#                          pathspec; mutate nothing, push nothing, exit 0.
#   --paired N,N,...       AC numbers asserted paired (forwarded to
#                          verified-completed.sh's C5 gate ALONGSIDE
#                          --derive, additively — see PRD-build-archive-
#                          autopair). If omitted, derived from manifest
#                          verification keys. Either way, verified-
#                          completed.sh derives its own pairing from the
#                          repo first (test_prefix / bare / acceptance_ac
#                          / mocks / fn-scan conventions); --paired only
#                          covers ACs the derivation didn't find. If C5
#                          still fails, the helper refuses (safe default
#                          — never paper over).
#   --test-cmd '<cmd>'     C1 test command run in the repo (default:
#                          `cargo test --release`).
#   --c1-prechecked        Trust the caller that C1 already passed (the
#                          tick just saw the build go green). Skips the
#                          expensive re-run. C5 is still always checked.
#   --no-push              Make local commits but do not publish/push
#                          (for smoke tests / offline audits).
#   --repos-category '<h>' REPOS.md heading to file the C4 entry under
#                          (default: a managed "## Recently shipped (auto)"
#                          section the helper owns).
#
# Exit codes:
#   0   ran (see [finalize-verdict] on stderr: ready | still-blocked: ...)
#   2   usage / resolution error
#   10  refused — not clerical: C1 or C5 already fails (zero mutations)
#
# On success stderr ends with:
#   [finalize-verdict] ready|still-blocked: <checks>

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
SCAN="$HERE/scan-prds.sh"
VC="$HERE/verified-completed.sh"
EXT="$HERE/extend-handler.sh"
MANIFEST="${MANIFEST:-$SKILL_DIR/state/manifest.json}"
JQ="${JQ:-/usr/bin/jq}"
REPOS="${REPOS_MD:-$HOME/wintermute/REPOS.md}"
GIT_ID=(-c user.email=jyen.tech@gmail.com -c "user.name=Joe Yen")

log()  { printf '%s\n' "archive-finalize: $*" >&2; }
die()  { printf '%s\n' "archive-finalize: $*" >&2; exit "${2:-2}"; }

slug=""
dry_run=false
paired_csv=""
test_cmd="cargo test --release"
c1_prechecked=false
no_push=false
repos_category="## Recently shipped (auto)"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)        dry_run=true; shift ;;
    --paired)         paired_csv="${2:-}"; shift 2 ;;
    --paired=*)       paired_csv="${1#--paired=}"; shift ;;
    --test-cmd)       test_cmd="${2:-}"; shift 2 ;;
    --test-cmd=*)     test_cmd="${1#--test-cmd=}"; shift ;;
    --c1-prechecked)  c1_prechecked=true; shift ;;
    --no-push)        no_push=true; shift ;;
    --repos-category) repos_category="${2:-}"; shift 2 ;;
    --repos-category=*) repos_category="${1#--repos-category=}"; shift ;;
    -h|--help)        sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    --)               shift; break ;;
    -*)               die "unknown flag $1" ;;
    *)                [ -z "$slug" ] && slug="$1" || die "unexpected arg $1"; shift ;;
  esac
done

[ -n "$slug" ]   || die "slug required (usage: archive-finalize.sh <slug>)"
[ -x "$SCAN" ]   || die "$SCAN not executable"
[ -x "$VC" ]     || die "$VC not executable"
[ -x "$EXT" ]    || die "$EXT not executable"
[ -x "$JQ" ]     || die "jq not at $JQ"
[ -r "$MANIFEST" ] || die "$MANIFEST not readable"

# ---- resolve PRD path, build_target, output_repo_path -----------------
entry="$("$JQ" -c --arg s "$slug" '.prds[]? | select(.slug==$s)' "$MANIFEST")"
[ -n "$entry" ] || die "no manifest entry for slug '$slug'"
build_target="$("$JQ" -r '.build_target // ""' <<<"$entry")"
repo="$("$JQ" -r '.output_repo_path // ""' <<<"$entry")"
prd_path="$("$JQ" -r '.path // ""' <<<"$entry")"
verification="$("$JQ" -c '.verification // null' <<<"$entry")"

[ -n "$repo" ] && [ -d "$repo" ] || die "output_repo_path missing or not a dir: '$repo'"
[ -n "$prd_path" ] && [ -r "$prd_path" ] || die "PRD path missing or unreadable: '$prd_path'"
repo_name="$(basename "$repo")"

case "$build_target" in
  rust-extend|kernel-extend) shape=extend ;;
  *)                         shape=newrepo ;;
esac

# ---- helpers: TL;DR extraction ----------------------------------------
extract_tldr() {  # full TL;DR section body (after the `## TL;DR` heading)
  awk '
    /^##[[:space:]]+TL;?DR/ { grab=1; next }
    /^##[[:space:]]/ && grab { grab=0 }
    grab { print }
  ' "$prd_path" | sed '/./,$!d'
}
extract_oneliner() {  # first non-empty sentence of the TL;DR, else PRD title
  local l
  l="$(extract_tldr | grep -m1 '[[:alnum:]]' | sed 's/^[*-][[:space:]]*//; s/[[:space:]]*$//')"
  if [ -z "$l" ]; then
    l="$(grep -m1 '^#[[:space:]]' "$prd_path" | sed 's/^#\+[[:space:]]*//')"
  fi
  printf '%s\n' "$l"
}

# ---- C5 gate: AC pairing (cheap — run first) --------------------------
if [ -z "$paired_csv" ] && [ "$verification" != "null" ]; then
  # Derive paired AC numbers from manifest verification keys (any digits
  # in each key, e.g. "ac3" -> 3, "AC10" -> 10). Best-effort.
  paired_csv="$("$JQ" -r '
    if type=="object" then (keys_unsorted[]) elif type=="array" then .[] else empty end
  ' <<<"$verification" 2>/dev/null \
    | sed -n 's/.*[^0-9]\([0-9][0-9]*\).*/\1/p; s/^\([0-9][0-9]*\)$/\1/p' \
    | sort -un | paste -sd, -)"
fi

# --derive always (PRD-build-archive-autopair req. 4): the classifier
# scans the repo for the AC-to-test pairing itself; --paired (derived
# above from manifest verification keys, when present) only ADDS
# coverage for ACs the derivation didn't find — it never replaces it.
if "$VC" "$prd_path" --derive ${paired_csv:+--paired "$paired_csv"} >/dev/null 2>&1; then
  c5_ok=true
else
  c5_ok=false
fi
if [ "$c5_ok" != true ]; then
  die "not-clerical: C5 (ACs not all paired/deferred) — refusing, zero mutations" 10
fi

# ---- C1 gate: tests green ---------------------------------------------
if [ "$c1_prechecked" = true ]; then
  log "C1 assumed green (--c1-prechecked)"
else
  log "C1: running '$test_cmd' in $repo"
  if ! ( cd "$repo" && eval "$test_cmd" ) >/dev/null 2>&1; then
    die "not-clerical: C1 (tests not green) — refusing, zero mutations" 10
  fi
fi

# ---- determine current version (for extend CHANGELOG / version refs) --
version="$("$EXT" current-version "$repo" 2>/dev/null | tail -n1)"
[ -n "$version" ] || version="0.0.0"

# ---- clerical checks --------------------------------------------------
# C2: repo published & HEAD pushed.
c2_ok() {
  local url branch
  url="$(git -C "$repo" remote get-url origin 2>/dev/null)" || return 1
  [ -n "$url" ] || return 1
  branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
  git -C "$repo" merge-base --is-ancestor HEAD "origin/$branch" 2>/dev/null
}
# C3: README (newrepo) or CHANGELOG section (extend) present.
c3_ok() {
  if [ "$shape" = extend ]; then
    [ -f "$repo/CHANGELOG.md" ] && grep -q "^## v$version\b" "$repo/CHANGELOG.md"
  else
    [ -f "$repo/README.md" ] && grep -qiE '^##[[:space:]]+install' "$repo/README.md"
  fi
}
# C4: repo listed in REPOS.md.
c4_ok() {
  [ -r "$REPOS" ] && grep -qF "j0yen/$repo_name)" "$REPOS"
}

# ---- fixers (each path-scoped) ----------------------------------------
plan=()
commit_repo_paths=()   # paths to commit inside $repo
commit_repos_md=false

fix_c3() {
  if [ "$shape" = extend ]; then
    plan+=("C3: prepend '## v$version' to $repo/CHANGELOG.md from PRD TL;DR")
    $dry_run && return 0
    local tf; tf="$(mktemp)"; extract_tldr >"$tf"
    "$EXT" changelog-prepend "$repo" "$version" "$tf" >/dev/null
    rm -f "$tf"
    commit_repo_paths+=("CHANGELOG.md")
  else
    plan+=("C3: generate $repo/README.md from PRD TL;DR + Acceptance + Install")
    $dry_run && return 0
    gen_readme >"$repo/README.md"
    commit_repo_paths+=("README.md")
  fi
}
gen_readme() {
  local title; title="$(grep -m1 '^#[[:space:]]' "$prd_path" | sed 's/^#\+[[:space:]]*//')"
  printf '# %s\n\n' "$repo_name"
  printf '%s\n\n' "$(extract_oneliner)"
  printf '## Overview\n\n'
  extract_tldr
  printf '\n## Acceptance\n\n'
  awk '
    /^##[[:space:]]+([0-9]+\.[[:space:]]+)?Acceptance/ { grab=1; next }
    /^##[[:space:]]/ && grab { grab=0 }
    grab { print }
  ' "$prd_path"
  printf '\n## Install\n\n```sh\ncargo install --path .\n```\n\n'
  printf '## License\n\nMIT © Joe Yen\n'
}
fix_c2() {
  local url
  url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  if [ -z "$url" ]; then
    if [ "$shape" = extend ]; then
      plan+=("C2: NO origin on an extend repo — cannot wm-publish; still-blocked")
      return 1
    fi
    plan+=("C2: wm-publish --slug $repo_name (new repo, then push)")
    $dry_run && return 0
    ( cd "$repo" && wm-publish --slug "$repo_name" --description "$(extract_oneliner)" ) >/dev/null 2>&1 \
      || { log "wm-publish failed/missing for $repo_name"; return 1; }
  else
    plan+=("C2: wm-push --slug $repo_name (push HEAD)")
    $dry_run && return 0
    ( cd "$repo" && wm-push --slug "$repo_name" ) >/dev/null 2>&1 \
      || { log "wm-push failed/missing for $repo_name"; return 1; }
  fi
}
fix_c4() {
  plan+=("C4: append REPOS.md row for $repo_name under '$repos_category'")
  $dry_run && return 0
  local row
  row="| [$repo_name](https://github.com/j0yen/$repo_name) | \`$repo_name\` | $(extract_oneliner) |"
  if grep -qF "$repos_category" "$REPOS"; then
    awk -v hdr="$repos_category" -v row="$row" '
      { print }
      $0==hdr && !done {
        # emit a fresh table right under the heading if the next non-blank
        # line is not already a table; otherwise append after the header.
        print ""; print "| Repo | Binary | What it does |"
        print "|---|---|---|"; print row
        done=1
      }
    ' "$REPOS" >"$REPOS.tmp" && mv "$REPOS.tmp" "$REPOS"
  else
    printf '\n%s\n\n| Repo | Binary | What it does |\n|---|---|---|\n%s\n' \
      "$repos_category" "$row" >>"$REPOS"
  fi
  commit_repos_md=true
}

# ---- evaluate & fix ---------------------------------------------------
need=()
c2_ok || need+=(C2)
c3_ok || need+=(C3)
c4_ok || need+=(C4)

if [ "${#need[@]}" -eq 0 ]; then
  log "all clerical checks already pass (C2/C3/C4); nothing to do"
  printf '[finalize-verdict] ready: nothing-to-fix\n' >&2
  exit 0
fi
log "clerical gaps: ${need[*]}"
in_need() { local x; for x in "${need[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }

# ---- DRY RUN: populate the plan for every gap, mutate nothing ---------
if $dry_run; then
  in_need C3 && fix_c3
  in_need C2 && fix_c2
  in_need C4 && fix_c4
  log "DRY RUN — planned steps:"
  for p in "${plan[@]}"; do printf '  - %s\n' "$p" >&2; done
  log "would-be repo commit pathspec: [${commit_repo_paths[*]:-}]${commit_repos_md:+ + REPOS.md}"
  printf '[finalize-verdict] dry-run: would-address %s\n' "${need[*]}" >&2
  exit 0
fi

# ---- REAL RUN, ordered: C3 (create) -> commit -> C2 (push) -> C4 ------
in_need C3 && { fix_c3 || true; }

# Commit the in-repo clerical files (path-scoped) BEFORE pushing so the
# push carries them.
if [ "${#commit_repo_paths[@]}" -gt 0 ]; then
  git -C "$repo" add -- "${commit_repo_paths[@]}"
  if ! git -C "$repo" diff --cached --quiet -- "${commit_repo_paths[@]}"; then
    git -C "$repo" "${GIT_ID[@]}" commit -q \
      -m "$repo_name: clerical finalize — ${commit_repo_paths[*]} (PRD-archive-finalize)" \
      -- "${commit_repo_paths[@]}"
    log "committed (path-scoped): ${commit_repo_paths[*]}"
  fi
fi

# C2 — publish/push (skipped under --no-push).
if in_need C2; then
  if $no_push; then log "C2: skipped (--no-push)"; else fix_c2 || true; fi
fi

# C4 — REPOS.md lives in ~/wintermute; commit it path-scoped there too.
in_need C4 && { fix_c4 || true; }
if $commit_repos_md; then
  repos_root="$(git -C "$(dirname "$REPOS")" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$repos_root" ]; then
    repos_rel="$(realpath --relative-to="$repos_root" "$REPOS")"
    git -C "$repos_root" add -- "$repos_rel"
    if ! git -C "$repos_root" diff --cached --quiet -- "$repos_rel"; then
      git -C "$repos_root" "${GIT_ID[@]}" commit -q \
        -m "REPOS.md: list $repo_name (PRD-archive-finalize)" -- "$repos_rel"
      log "committed REPOS.md entry for $repo_name"
      $no_push || git -C "$repos_root" push origin \
        "$(git -C "$repos_root" symbolic-ref --short HEAD)" >/dev/null 2>&1 \
        || log "REPOS.md push skipped/failed"
    fi
  fi
fi

# ---- re-run the clerical gate -----------------------------------------
still=()
c2_ok || still+=(C2)
c3_ok || still+=(C3)
c4_ok || still+=(C4)
if [ "${#still[@]}" -eq 0 ]; then
  printf '[finalize-verdict] ready: %s\n' "${need[*]}" >&2
else
  printf '[finalize-verdict] still-blocked: %s\n' "${still[*]}" >&2
fi
exit 0
