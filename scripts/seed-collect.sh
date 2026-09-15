#!/usr/bin/env bash
# seed-collect.sh — harvest durable seed files into the PRDs-repo inbox
# (PRD-prd-seed-inbox). A "seed" is a finding worth dreaming from — a build
# journal failure family, a synthorg pack index, or a manual observation —
# written once, with its evidence, to survive session end and host cleanup.
# /dream reads seeds/ as a Phase 0 source; this script never drafts PRDs,
# it only harvests and files findings (Non-Goals: "dream owns that").
#
# Usage:
#   seed-collect.sh [collect]
#       Runs every known harvester. Each surface's absence is a stated
#       skip (printed, not an error) — exit is always 0 unless a usage
#       error occurred before any harvester ran.
#   seed-collect.sh add "<observation>" [--evidence <path> ...] [--source <label>]
#       Manual entry point. Each --evidence path must exist; it is copied
#       (see cap below) into seeds/evidence/<seed>/ and the ORIGINAL path
#       is always recorded in the seed body regardless of copy outcome.
#       --source defaults to "manual".
#   seed-collect.sh list [--pending]
#       One line per seed: "<Observed> <slug> <Source>". --pending filters
#       to Status: pending only (status line / depth-governor consumer).
#
# Seed file: seeds/<date>-<slug>.md (frontmatter the same bullet form the
# contract parser family already reads):
#   - Source: <surface + path/command>
#   - Observed: <ISO date>
#   - Status: pending | dreamed | discarded
#   - Fingerprint: <16-hex sha256 of source+observation>  (internal dedupe
#     key — an extra bullet, harmless to every existing frontmatter reader,
#     which stops at the keys it knows)
# body: the observation, then an "## Evidence" section when evidence was
# attached (inline excerpt and/or copied-file pointers, original path
# always named per AC3).
#
# Evidence-copy size cap (open question in the PRD, picked here and
# documented per its own instruction "builder (pick, document)"): 256 KiB
# per file. A larger file is copied truncated with a trailing
# "...[truncated, N bytes total]" marker; the original path is still
# recorded so a human can go back to the untruncated source while it's
# still readable.
#
# Idempotent: re-running collect/add never duplicates a seed — the dedupe
# key is sha256(source + "\x1f" + observation), checked against every
# existing seed file's `- Fingerprint:` bullet before a new file is
# written (AC2).
#
# The inbox lives in the PRDs repo so it syncs across machines (Technical
# considerations). This script commits like any other PRDs-repo writer:
# pull --rebase --autostash before reading/writing, targeted `git add` of
# only the seeds/ tree, commit, then push — never a force-push; a push
# rejection gets exactly one fetch+rebase retry.
#
# Env overrides (test-only hooks; production defaults unchanged):
#   SEED_PRD_DIR             PRD-repo root (default $HOME/Documents/PRDs)
#   SEED_JOURNAL_DIR         build-journal surface
#                            (default $HOME/brain/journal/build)
#   SEED_SYNTHORG_DIRS       colon-separated candidate dirs for the
#                            synthorg-pack surface (default
#                            "$HOME/projects/synthorg/runs:$HOME/repos/synthorg/runs")
#   SEED_COLLECT_PUSH        1 (default) pushes committed seeds to origin;
#                            0 commits locally only — set 0 in tests/
#                            fixtures with no reachable remote.
#   SEED_EVIDENCE_CAP_BYTES  262144 (default)
#
# Exit codes: 0 success (including "every surface skipped"); 2 usage error.

set -uo pipefail

PRD_DIR="${SEED_PRD_DIR:-$HOME/Documents/PRDs}"
SEEDS_DIR="$PRD_DIR/seeds"
EVIDENCE_ROOT="$SEEDS_DIR/evidence"
JOURNAL_DIR="${SEED_JOURNAL_DIR:-$HOME/brain/journal/build}"
SYNTHORG_DIRS="${SEED_SYNTHORG_DIRS:-$HOME/projects/synthorg/runs:$HOME/repos/synthorg/runs}"
PUSH="${SEED_COLLECT_PUSH:-1}"
EVIDENCE_CAP="${SEED_EVIDENCE_CAP_BYTES:-262144}"

usage() {
  cat <<'EOF'
usage: seed-collect.sh [collect]
       seed-collect.sh add "<observation>" [--evidence <path> ...] [--source <label>]
       seed-collect.sh list [--pending]
EOF
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-60
}

fingerprint() {
  # $1=source $2=observation
  printf '%s\x1f%s' "$1" "$2" | sha256sum | cut -c1-16
}

fingerprint_exists() {
  local fp="$1"
  [ -d "$SEEDS_DIR" ] || return 1
  grep -rl -- "^- Fingerprint: $fp\$" "$SEEDS_DIR"/*.md 2>/dev/null | grep -q .
}

unique_seed_path() {
  # $1=date $2=slug -> echoes a filename not yet present
  local date="$1" slug="$2" n=2
  local candidate="$SEEDS_DIR/${date}-${slug}.md"
  while [ -e "$candidate" ]; do
    candidate="$SEEDS_DIR/${date}-${slug}-${n}.md"
    n=$((n + 1))
  done
  printf '%s' "$candidate"
}

copy_evidence() {
  # $1=dest_dir $2=path -> prints copied-path on stdout, exit 1 if unreadable
  local dest_dir="$1" src="$2"
  [ -f "$src" ] || { echo "seed-collect: evidence path not found or not a file: $src" >&2; return 1; }
  mkdir -p "$dest_dir"
  local base dest size
  base="$(basename -- "$src")"
  dest="$dest_dir/$base"
  size=$(stat -c '%s' "$src" 2>/dev/null || stat -f '%z' "$src" 2>/dev/null || echo 0)
  if [ "$size" -gt "$EVIDENCE_CAP" ]; then
    head -c "$EVIDENCE_CAP" "$src" > "$dest"
    printf '\n...[truncated, %s bytes total]\n' "$size" >> "$dest"
  else
    cp -- "$src" "$dest"
  fi
  printf '%s' "$dest"
}

write_seed() {
  # args: source observed_date slug_hint observation [evidence_path ...]
  local source="$1" observed="$2" slug_hint="$3" observation="$4"
  shift 4
  local fp
  fp="$(fingerprint "$source" "$observation")"
  if fingerprint_exists "$fp"; then
    echo "seed-collect: dedupe skip fingerprint=$fp source=$source" >&2
    return 1
  fi
  mkdir -p "$SEEDS_DIR"
  local slug
  slug="$(slugify "$slug_hint")"
  [ -n "$slug" ] || slug="seed"
  local path seed_name
  path="$(unique_seed_path "$observed" "$slug")"
  seed_name="$(basename "$path" .md)"
  local evidence_lines="" ev copied
  for ev in "$@"; do
    [ -n "$ev" ] || continue
    if copied="$(copy_evidence "$EVIDENCE_ROOT/$seed_name" "$ev")"; then
      evidence_lines+=$'\n'"- original: \`$ev\` — copied: \`${copied#"$PRD_DIR"/}\`"
    else
      evidence_lines+=$'\n'"- original: \`$ev\` (unreadable at collect time, not copied)"
    fi
  done
  {
    printf -- '- Source: %s\n' "$source"
    printf -- '- Observed: %s\n' "$observed"
    printf -- '- Status: pending\n'
    printf -- '- Fingerprint: %s\n' "$fp"
    printf '\n'
    printf '%s\n' "$observation"
    if [ -n "$evidence_lines" ]; then
      printf '\n## Evidence\n%s\n' "$evidence_lines"
    fi
  } > "$path"
  echo "seed-collect: wrote $path"
}

prds_git_pull() {
  [ -d "$PRD_DIR/.git" ] || return 0
  if ! git -C "$PRD_DIR" pull --rebase --autostash -q 2>/tmp/seed-collect.pull.err; then
    echo "seed-collect: warning: pull --rebase failed in $PRD_DIR, continuing with local state" >&2
    cat /tmp/seed-collect.pull.err >&2
  fi
}

prds_git_commit_and_push() {
  local msg="$1"
  [ -d "$PRD_DIR/.git" ] || return 0
  local status
  status="$(git -C "$PRD_DIR" status --porcelain -- seeds 2>/dev/null)"
  [ -n "$status" ] || return 0
  git -C "$PRD_DIR" add -- seeds
  git -C "$PRD_DIR" commit -q -m "$msg" || return 0
  [ "$PUSH" = "1" ] || return 0
  if ! git -C "$PRD_DIR" push -q 2>/tmp/seed-collect.push.err; then
    echo "seed-collect: push rejected, retrying after fetch+rebase" >&2
    local branch
    branch="$(git -C "$PRD_DIR" rev-parse --abbrev-ref HEAD)"
    if git -C "$PRD_DIR" fetch -q && git -C "$PRD_DIR" rebase -q "origin/$branch"; then
      git -C "$PRD_DIR" push -q || {
        echo "seed-collect: push failed after retry, seed committed locally only" >&2
        cat /tmp/seed-collect.push.err >&2
      }
    else
      git -C "$PRD_DIR" rebase --abort 2>/dev/null
      echo "seed-collect: push retry rebase failed, seed committed locally only" >&2
    fi
  fi
}

# --- Harvester: build-journal digest failure families -----------------
# A failure family here is a (repo, phase) pair marked failed (trailing
# "!") inside an extend-gate.sh `  gate  <repo>  block  (... phases=...)`
# journal line — the same phase-reading convention gate-phase-digest.sh
# already reads ("a `<name>:<s>!` failed reading's seconds still count").
harvest_journal() {
  if [ ! -d "$JOURNAL_DIR" ]; then
    echo "seed-collect: skip build-journal ($JOURNAL_DIR not present on this host)"
    return 0
  fi
  local f
  for f in "$JOURNAL_DIR"/*.md; do
    [ -e "$f" ] || continue
    while IFS= read -r rec; do
      local lineno content ts repo phases
      lineno="${rec%%:*}"
      content="${rec#*:}"
      ts="$(awk '{print $1}' <<<"$content")"
      repo="$(awk '{print $3}' <<<"$content")"
      phases="$(grep -oE 'phases=[^ ]+' <<<"$content" | head -1 | cut -d= -f2-)"
      [ -n "$phases" ] || continue
      local date="${ts%%T*}"
      local parts p
      IFS=',' read -ra parts <<< "$phases"
      for p in "${parts[@]}"; do
        case "$p" in
          *'!')
            local name="${p%%:*}"
            local observation
            observation="build journal digest failure family: repo=${repo} phase=${name} (gate block ${ts})"$'\n\nEvidence excerpt:\n\n```\n'"${content}"$'\n```'
            write_seed "build-journal:${f}:${lineno}" "$date" "journal-${repo}-${name}" "$observation"
            ;;
        esac
      done
    done < <(grep -n '  gate  .*verdict=block' "$f")
  done
}

# --- Harvester: synthorg discover/gtm/rank pack indexes ----------------
harvest_synthorg() {
  local dirs d
  IFS=':' read -ra dirs <<< "$SYNTHORG_DIRS"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ ! -d "$d" ]; then
      echo "seed-collect: skip synthorg-packs ($d not present on this host)"
      continue
    fi
    local found=0 idx
    while IFS= read -r -d '' idx; do
      found=1
      local mtime rel excerpt observation
      mtime="$(date -u -r "$idx" +%F 2>/dev/null || date -u +%F)"
      rel="${idx#"$d"/}"
      excerpt="$(head -c 2000 "$idx")"
      observation="synthorg pack index: ${rel}"$'\n\nEvidence excerpt:\n\n```\n'"${excerpt}"$'\n```'
      write_seed "synthorg-packs:${idx}" "$mtime" "synthorg-${rel}" "$observation" "$idx"
    done < <(find "$d" -maxdepth 3 -type f \
      \( -iname '*discover*' -o -iname '*gtm*' -o -iname '*rank*' \) \
      \( -iname '*.json' -o -iname '*.yaml' -o -iname '*.yml' \) -print0 2>/dev/null)
    [ "$found" = 1 ] || echo "seed-collect: skip synthorg-packs ($d present but no discover/gtm/rank index files found)"
  done
}

cmd_collect() {
  prds_git_pull
  harvest_journal
  harvest_synthorg
  prds_git_commit_and_push "seed-collect: harvest $(date -u +%FT%TZ)"
}

cmd_add() {
  local observation="${1:-}"
  [ -n "$observation" ] || { echo "seed-collect add: usage: seed-collect.sh add \"<observation>\" [--evidence <path> ...] [--source <label>]" >&2; return 2; }
  shift
  local source="manual"
  local evidence=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --evidence)
        shift
        while [ $# -gt 0 ] && [[ "$1" != --* ]]; do evidence+=("$1"); shift; done
        ;;
      --source)
        source="${2:?seed-collect add: --source needs a value}"
        shift 2
        ;;
      *)
        echo "seed-collect add: unknown argument: $1" >&2
        return 2
        ;;
    esac
  done
  prds_git_pull
  local date
  date="$(date -u +%F)"
  write_seed "$source" "$date" "$observation" "$observation" "${evidence[@]}"
  prds_git_commit_and_push "seed-collect: add seed $(date -u +%FT%TZ)"
}

cmd_list() {
  local pending_only=0
  [ "${1:-}" = "--pending" ] && pending_only=1
  [ -d "$SEEDS_DIR" ] || return 0
  local f
  for f in "$SEEDS_DIR"/*.md; do
    [ -e "$f" ] || continue
    local status src observed slug
    status="$(grep -m1 '^- Status:' "$f" | sed 's/^- Status: *//')"
    src="$(grep -m1 '^- Source:' "$f" | sed 's/^- Source: *//')"
    observed="$(grep -m1 '^- Observed:' "$f" | sed 's/^- Observed: *//')"
    slug="$(basename "$f" .md)"
    if [ "$pending_only" = 1 ] && [ "$status" != "pending" ]; then continue; fi
    printf '%s %s %s\n' "$observed" "$slug" "$src"
  done
}

main() {
  local cmd="${1:-collect}"
  case "$cmd" in
    collect) cmd_collect ;;
    add) shift; cmd_add "$@" ;;
    list) shift; cmd_list "$@" ;;
    -h|--help) usage ;;
    *) echo "seed-collect.sh: unknown subcommand: $cmd" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
