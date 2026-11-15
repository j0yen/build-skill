# tests/fixtures/dream-local-origin.sh — a local git origin and clone for the no-fetch
# controls of dream.scorecard and dream.dryrun (review finding SC-HIGH-1: the reused
# prd-lint fetches every build_into named by a Live AC's repo-path evidence). Sourced,
# never run. No network: the origin is a file:// bare repository under the test's own
# temporary directory.
#
#   dlo_make <dir>          <dir>/origin.git (bare), <dir>/seed (pushes), <dir>/clone (the
#                           "live clone" a PRD's build_into names); origin main holds
#                           scripts/present.sh. Sets DLO_DIR, DLO_CLONE.
#   dlo_reclone             a fresh clone (origin/main = origin main now)
#   dlo_advance             one more commit on origin main: a fetch would move the clone's
#                           origin/main and write FETCH_HEAD
#   dlo_prd <file> <slug>   a lint-clean PRD (copy of the shipped dryrun fixture) whose
#                           build_into is the clone and whose Live evidence names
#                           scripts/present.sh, so prd-lint's referent check runs
#   dlo_state               fetch_head=<yes|no> origin_main=<sha> dirty=<n>
#   dlo_snapshot            path, mtime and size of every file and directory in the clone
#   dlo_trace <log> <cmd…>  strace -f of <cmd> (execve, connect, write-class syscalls)
#   dlo_violations <log>    lines showing a `git fetch` exec, an AF_INET/AF_INET6 connect,
#                           or a successful write-class syscall under the clone; empty = none
#   dlo_exercised <log>     the execve lines of git reading the clone (proof the referent
#                           check ran); empty = it never ran

DLO_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dreamdry_fixture/PRD-dreamdry-fixture.md"

dlo_git() { git -c user.name=dreamtest -c user.email=dreamtest@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

dlo_make() {
  DLO_DIR="$1"; DLO_CLONE="$1/clone"
  mkdir -p "$DLO_DIR" || return 1
  dlo_git init -q --bare "$DLO_DIR/origin.git" || return 1
  dlo_git clone -q "file://$DLO_DIR/origin.git" "$DLO_DIR/seed" 2>/dev/null || return 1
  mkdir -p "$DLO_DIR/seed/scripts" && printf 'echo present\n' > "$DLO_DIR/seed/scripts/present.sh"
  dlo_git -C "$DLO_DIR/seed" add -A && dlo_git -C "$DLO_DIR/seed" commit -qm c1 \
    && dlo_git -C "$DLO_DIR/seed" push -q origin HEAD:main || return 1
  dlo_reclone
}

dlo_reclone() { rm -rf "$DLO_CLONE"; dlo_git clone -q "file://$DLO_DIR/origin.git" "$DLO_CLONE"; }

dlo_advance() {
  printf '%s\n' "$RANDOM" >> "$DLO_DIR/seed/bump"
  dlo_git -C "$DLO_DIR/seed" add -A && dlo_git -C "$DLO_DIR/seed" commit -qm bump \
    && dlo_git -C "$DLO_DIR/seed" push -q origin HEAD:main
}

dlo_prd() {
  local f="$1" slug="$2" tp; tp="$(printf '%s' "$slug" | tr -cd 'a-z0-9')"
  sed -e "s/^# PRD — dreamdry-fixture:/# PRD — $slug:/" -e "s/^- test_prefix: dreamdryfx$/- test_prefix: $tp/" \
      -e "s#^- build_into: .*#- build_into: $DLO_CLONE#" "$DLO_FIXTURE" > "$f"
  printf '%s\n' '3. P0 — Given the clone, When the judge runs the script, Then it exits 0. (Live; evidence: `cmd:bash scripts/present.sh`)' >> "$f"
}

dlo_state() {
  printf 'fetch_head=%s origin_main=%s dirty=%s' \
    "$([ -e "$DLO_CLONE/.git/FETCH_HEAD" ] && echo yes || echo no)" \
    "$(GIT_OPTIONAL_LOCKS=0 git -C "$DLO_CLONE" rev-parse -q --verify refs/remotes/origin/main)" \
    "$(GIT_OPTIONAL_LOCKS=0 git -C "$DLO_CLONE" status --porcelain 2>/dev/null | wc -l)"
}

dlo_snapshot() { find "$DLO_CLONE" -printf '%p %y %T@ %s\n' 2>/dev/null | sort; }

dlo_trace() {
  local log="$1"; shift
  strace -f -qq -s 1024 -o "$log" \
    -e trace=execve,connect,open,openat,creat,rename,renameat,renameat2,unlink,unlinkat,mkdir,mkdirat,truncate,ftruncate,utimensat,link,linkat,symlink,symlinkat \
    "$@" >/dev/null 2>&1
}

dlo_violations() {
  local log="$1" real; real="$(readlink -f "$DLO_CLONE")"
  grep -E 'execve\(.*"fetch"' "$log"
  grep -E 'connect\(.*AF_INET6?[,}]' "$log"
  grep -vE '= -1 ' "$log" | grep -E "\"($DLO_CLONE|$real)(/[^\"]*)?\"" \
    | grep -E 'O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|creat\(|rename|unlink|mkdir|truncate|utimensat|link\(|linkat\(|symlink'
  return 0
}

dlo_exercised() {
  local log="$1" real; real="$(readlink -f "$DLO_CLONE")"
  grep -E 'execve\("[^"]*git", \[' "$log" | grep -E "\"($DLO_CLONE|$real)\"" | grep -E '"(rev-parse|cat-file)"'
  return 0
}
