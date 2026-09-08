#!/usr/bin/env bash
# worktree_targets_ac2_cleanup_removes_target.sh — PRD-build-worktree-targets-off-root AC2.
#
# Given that worktree after `cargo build` of the fixture, when
# `worktree-extend.sh cleanup <fixture-repo> s1` runs, then neither the
# worktree nor $T/targets/<repo>-s1 exists and the branch still does.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WTE="$HERE/../scripts/worktree-extend.sh"
[ -x "$WTE" ] || { echo "ac2: $WTE not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/wt-targets-ac2.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

TARGETS="$T/targets"
export BUILD_WT_ROOT="$T/worktrees"
wt="$(BUILD_TARGET_ROOT="$TARGETS" "$WTE" add "$REPO" s1)"

repo_base="$(basename "$REPO")"
tdir="$TARGETS/$repo_base-s1"

# Fake `cargo build` — a real toolchain isn't needed to prove the target-dir
# redirect + cleanup wiring; a stub that mimics cargo's own config-driven
# target-dir resolution (CARGO_TARGET_DIR env, else [build] target-dir from
# ./.cargo/config.toml) is enough to populate the dir the same way a real
# `cargo build` would via the config file worktree-extend.sh just wrote.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/cargo" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "build" ]; then
  td="${CARGO_TARGET_DIR:-}"
  if [ -z "$td" ] && [ -f .cargo/config.toml ]; then
    td="$(sed -n 's/^target-dir = "\(.*\)"$/\1/p' .cargo/config.toml)"
  fi
  td="${td:-target}"
  mkdir -p "$td"
  touch "$td/fixture-build-marker"
fi
exit 0
EOF
chmod +x "$BIN/cargo"
( cd "$wt" && PATH="$BIN:$PATH" cargo build --release -q )
expect "fixture build populated target dir" "[ -f '$tdir/fixture-build-marker' ]"

out="$("$WTE" cleanup "$REPO" s1)"; rc=$?
expect "cleanup exits 0"          "[ $rc -eq 0 ]"
expect "worktree dir gone"        "[ ! -d '$wt' ]"
expect "target dir gone"          "[ ! -d '$tdir' ]"
expect "cleanup output names freed target" "[[ '$out' == *'$tdir'* ]]"
expect "branch still exists"      "git -C '$REPO' show-ref --verify --quiet refs/heads/autobuilder/s1"

exit $fail
