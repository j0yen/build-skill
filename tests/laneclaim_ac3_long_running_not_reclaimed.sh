#!/usr/bin/env bash
# laneclaim_ac3_long_running_not_reclaimed.sh — PRD-build-lane-claim-integrity AC3.
#
# Given a claim older than the 3h threshold whose lane journal shows
# activity 5 minutes ago, when stale detection runs, then state is
# long-running and no reclaim occurs.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac3: $LC not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/laneclaim-ac3.XXXXXX")"
JOURNAL_DIR_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/laneclaim-ac3-journal.XXXXXX")"
trap 'rm -rf "$T" "$JOURNAL_DIR_SCRATCH"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
cat > "$T/clone/build-queue/PRD-longrunning.md" <<'EOF'
# PRD: longrunning
- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$T/clone" push -q origin master 2>/dev/null || git -C "$T/clone" push -q origin main 2>/dev/null
BR=$(git -C "$T/clone" symbolic-ref --short HEAD)
LR_PRD="$T/clone/build-queue/PRD-longrunning.md"

source "$LC"
old=$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)
write_claim "$LR_PRD" building "redbaron $old"
git -C "$T/clone" add -A
GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" \
  git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: longrunning lane=redbaron (fixture)"
git -C "$T/clone" push -q origin "$BR"

# iter_log activity 5 minutes ago — committed AFTER the backdated claim
# commit, so this exercises the liveness probe (the commit probe alone
# would also fire here; either is sufficient for long-running).
five_min_ago=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
printf -- '- iter_log: %s still iterating\n' "$five_min_ago" >> "$LR_PRD"
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "iter_log: longrunning progress"
git -C "$T/clone" push -q origin "$BR"

st=$("$LC" status "$LR_PRD" --json)
expect "status --json reports state=long-running, stale=false" \
  "echo '$st' | jq -e '.state == \"long-running\" and .stale == false' >/dev/null 2>&1"

set +e
out=$("$LC" claim "$LR_PRD" carbon 2>&1); rc=$?
set -e
expect "a foreign lane's claim attempt is held (exit 2), not reclaimed" "[ $rc -eq 2 ]"
expect "held message names state=long-running" "echo '$out' | grep -q 'state=long-running'"

# AC3b: journal-only activity (no iter_log, no commit since claim) also
# reads long-running — the other half of the liveness-signal OR-clause.
cat > "$T/clone/build-queue/PRD-journalonly.md" <<'EOF'
# PRD: journalonly
- Status: building
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m add-journalonly
git -C "$T/clone" push -q origin "$BR"
JO_PRD="$T/clone/build-queue/PRD-journalonly.md"
old2=$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)
write_claim "$JO_PRD" building "redbaron $old2"
git -C "$T/clone" add -A
GIT_AUTHOR_DATE="$old2" GIT_COMMITTER_DATE="$old2" \
  git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m "claim: journalonly lane=redbaron (fixture)"
git -C "$T/clone" push -q origin "$BR"
five_min_ago2=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
printf '%s  journalonly  tick  progress  (lane=redbaron)\n' "$five_min_ago2" > "$JOURNAL_DIR_SCRATCH/today.md"

st2=$(JOURNAL_DIR="$JOURNAL_DIR_SCRATCH" "$LC" status "$JO_PRD" --json)
expect "journal-only activity (no iter_log) also reads long-running" \
  "echo '$st2' | jq -e '.state == \"long-running\"' >/dev/null 2>&1"

exit $fail
