#!/usr/bin/env bash
# tests/prpath_ac_p2_status_landing_record.sh —
# PRD-build-main-push-gate-pr-path requirement 11 (P2, no numbered AC in
# the PRD's own list): `branch-protection.sh status <repo>` prints
# `push_via_branch`, the landing record if any, and the last
# `main-synced` journal line.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=prpath_common.sh
source "$HERE/prpath_common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prpath-status.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

work="$(prpath_mk_repo "$ROOT/repo")"
repo_slug="$(basename "$work")"

export BUILD_STATE_DIR="$ROOT/state"
export BUILD_JOURNAL_ROOT="$ROOT/journal"
mkdir -p "$BUILD_STATE_DIR" "$BUILD_JOURNAL_ROOT"
cat > "$BUILD_STATE_DIR/branch-protection.json" <<EOF
{"$repo_slug": {"push_via_branch": true, "required_contexts": ["ci"]}}
EOF
mkdir -p "$BUILD_STATE_DIR/landings/$repo_slug"
cat > "$BUILD_STATE_DIR/landings/$repo_slug/some-slug.json" <<EOF
{"pr_url": "https://github.com/j0yen/$repo_slug/pull/5", "pr_number": 5, "head_sha": "cafebabe", "armed_at": "2026-09-16T22:00:00Z"}
EOF
printf '%s  branch-protection  %s  main-synced old=aaa new=bbb tree=identical\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$repo_slug" > "$BUILD_JOURNAL_ROOT/$(date -u +%F).md"

bindir="$ROOT/bin"
mkdir -p "$bindir"
# A dedicated stub, not prpath_install_gh_stub's shared one -- `status`
# starts with `gh api repos/.../branches/main/protection`, a call shape
# the shared stub's `pr view/list/create/merge` cases don't cover.
cat > "$bindir/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
case "\$1 \$2" in
  "auth status") exit 0 ;;
esac
if [ "\$1" = "api" ]; then
  echo '{"required_status_checks":{"strict":false,"contexts":["ci"]},"enforce_admins":{"enabled":true}}'
  exit 0
fi
echo "gh-stub: unexpected invocation: \$*" >&2
exit 1
STUB
chmod +x "$bindir/gh"

out="$(env PATH="$bindir:$PATH" "$PRPATH_BP" status "$work")"
prpath_expect "status: shows push_via_branch" "printf '%s\n' \"\$out\" | grep -q 'push_via_branch: True'"
prpath_expect "status: shows the landing record's PR" "printf '%s\n' \"\$out\" | grep -q 'pr=https://github.com/j0yen/'"
prpath_expect "status: shows the landing record's head_sha" "printf '%s\n' \"\$out\" | grep -q 'head=cafebabe'"
prpath_expect "status: shows the last main-synced line" "printf '%s\n' \"\$out\" | grep -q 'last main-synced:.*main-synced old=aaa new=bbb'"

exit "$prpath_fail"
