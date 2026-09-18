#!/usr/bin/env bash
# tests/canaryliv_ac1_worktree_pinning.sh — PRD-build-burst-canary-live-
# parity AC1 (R1): baseline and main-variant gate-launch.sh calls must
# target a detached worktree pinned at the canary's resolved head, never
# CANARY_REPO directly — CANARY_REPO's own HEAD can move out from under a
# canary in flight (the 2026-09-18 04:36Z incident this PRD exists to fix,
# where the shared mcphost checkout's HEAD moved mid-canary and
# extend-gate.sh refused a --head that no longer matched the checkout).
#
# Fixture: CANARY_REPO's checkout HEAD is one commit PAST the sha the
# canary is asked to run at (--head pins the older sha, resolving with no
# gh lookup — canary_resolve_head short-circuits on an explicit operator
# head). A fake gate-launch.sh records the repo path it was invoked
# against for every call. Pure fixture: no real box, no network.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label"; fail=1; fi; }

export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canaryliv-ac1.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

repo="$ROOT/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
canary_head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "checkout moved past canary head"
checkout_head="$(git -C "$repo" rev-parse HEAD)"

call_log="$ROOT/gate-launch-calls.log"
fake_gl="$ROOT/fake-gate-launch"
cat > "$fake_gl" <<EOF
#!/usr/bin/env bash
repo="\$1"; shift
slug=""
prev=""
for a in "\$@"; do
  case "\$prev" in --slug) slug="\$a" ;; esac
  prev="\$a"
done
echo "\$slug \$repo \$(git -C "\$repo" rev-parse HEAD 2>/dev/null || echo unknown)" >> "$call_log"
mkdir -p "\$repo/target/autobuilder/receipts"
cat > "\$repo/target/autobuilder/receipts/extended-receipts-receipt.json" <<JSON
{"schema":"autobuilder.extended_receipts.v1","verdict":"pass","route":"local","head_sha":"\$(git -C "\$repo" rev-parse HEAD 2>/dev/null || echo unknown)"}
JSON
printf '{"verdict":"pass"}\n' > "\$repo/target/autobuilder/last-verdict.json"
exit 0
EOF
chmod +x "$fake_gl"

wt_root="$ROOT/wt-root"
export BURST_LANE_STATE_DIR="$ROOT/state"
export BURST_LANE_JOURNAL="$ROOT/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"
export BURST_LANE_CANARY_REPO="$repo"
export BURST_LANE_CANARY_GATE_LAUNCH="$fake_gl"
export BURST_LANE_CANARY_WORKTREE_ROOT="$wt_root"
mkdir -p "$BURST_LANE_STATE_DIR/current"
echo '{"server_id":"testbox-ac1","ip":"127.0.0.1"}' > "$BURST_LANE_STATE_DIR/current/session.json"

set +e
"$BL" canary --head "$canary_head" --variants main --keep-worktree >/dev/null 2>&1
rc=$?
set -e
expect "AC1: canary command did not hard-fail" "[ '$rc' -le 1 ]"

expect "AC1: journal has canary worktree line naming the pinned head" \
  "grep -qE 'canary  worktree  \(path=.*head='$canary_head'\)' '$BURST_LANE_JOURNAL'"

wt_path="$(awk -F'path=| head=' '/canary  worktree/{print $2; exit}' "$BURST_LANE_JOURNAL")"
expect "AC1: worktree path is under CANARY_WORKTREE_ROOT, not CANARY_REPO" \
  "[ -n '$wt_path' ] && [ '$wt_path' != '$repo' ] && case '$wt_path' in '$wt_root'/*) true;; *) false;; esac"
expect "AC1: worktree HEAD equals the pinned canary head" \
  "[ \"\$(git -C '$wt_path' rev-parse HEAD 2>/dev/null)\" = '$canary_head' ]"
expect "AC1: shared checkout HEAD is unchanged" \
  "[ \"\$(git -C '$repo' rev-parse HEAD)\" = '$checkout_head' ]"

expect "AC1: baseline call recorded against a worktree, not CANARY_REPO" \
  "grep -q '^canary-baseline-[^ ]* '\"'\"'$wt_path'\"'\"' ' '$call_log' 2>/dev/null || grep -qE '^canary-baseline-\S+ '$wt_path' ' '$call_log'"
expect "AC1: main-variant call recorded against a worktree, not CANARY_REPO" \
  "grep -qE '^canary-main-\S+ '$wt_path' ' '$call_log'"
expect "AC1: no gate-launch call was ever made against CANARY_REPO directly" \
  "! grep -qE ' '$repo' ' '$call_log'"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canaryliv_ac1_worktree_pinning: ALL PASS"
else
  echo "canaryliv_ac1_worktree_pinning: FAILED" >&2
fi
exit "$fail"
