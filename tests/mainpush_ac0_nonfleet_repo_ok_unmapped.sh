#!/usr/bin/env bash
# mainpush_ac0_nonfleet_repo_ok_unmapped.sh — PRD-build-main-push-gate,
# Migration / compatibility section: "Repos without
# .buildloop/ci-equivalent.toml get unknown (rc 5) ... SKILL.md treats rc
# 5 as defer for shared-target repos and as ok-unmapped (journaled) for
# repos not in ci-status.sh's list." Named ac0 (not one of the PRD's nine
# numbered ACs) because it covers this cross-cutting Migration-section
# rule rather than a specific acceptance criterion — but it earns its
# place: without this exemption, the pre-push hook refuses EVERY push
# from a non-fleet build_into repo forever (this is exactly what happened
# live to build-skill's own self-push.sh on 2026-09-15, the day this PRD
# landed — build-skill has no `.buildloop/ci-equivalent.toml` and is not
# in scripts/lib/fleet-repos.sh's FLEET_REPOS).
#
# Covers: the pre-push hook allows a push (and journals `ok-unmapped`)
# when main-push-gate.sh returns unknown (rc 5, missing config) for a
# repo whose basename is NOT in FLEET_REPOS; a repo WHOSE basename IS in
# FLEET_REPOS still gets refused the same way exit 5 always has.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fixtures/mainpush-common.sh
source "$HERE/fixtures/mainpush-common.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac0.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export BUILD_JOURNAL_ROOT="$ROOT/journal"

# --- case A: non-fleet repo name ("work"), missing config -> allowed ---
work="$(mainpush_mkfixture "$ROOT")"
rm -f "$work/.buildloop/ci-equivalent.toml"
git -C "$work" -c user.name="Fixture Bot" -c user.email="fixture@example.invalid" commit -aqm "remove ci-equivalent.toml"
git -C "$work" config core.hooksPath "$MAINPUSH_SCRIPTS/repo-hooks"
remote_before="$(git -C "$work" ls-remote origin main | awk '{print $1}')"

pushd "$work" >/dev/null
git push origin HEAD:main >/tmp/mainpush-ac0a.$$.out 2>&1
rc_a=$?
out_a="$(cat "/tmp/mainpush-ac0a.$$.out")"
rm -f "/tmp/mainpush-ac0a.$$.out"
popd >/dev/null

mainpush_expect "AC0: non-fleet repo push allowed (exit 0)" '[ "$rc_a" -eq 0 ]'
mainpush_expect "AC0: remote main advanced" '[ "$(git -C "$work" ls-remote origin main | awk "{print \$1}")" != "$remote_before" ]'

journal_file="$BUILD_JOURNAL_ROOT/$(date -u +%F).md"
mainpush_expect "AC0: journal records ok-unmapped" 'grep -q "main-push  ok-unmapped" "$journal_file"'

# --- case B: a FLEET_REPOS name, missing config -> still refused -------
# Build under a directory whose basename is literally "mcphost" so
# is_fleet_repo()'s basename match is real, not simulated.
ROOT2="$(mktemp -d "${TMPDIR:-/tmp}/mainpush-ac0b.XXXXXX")"
trap 'rm -rf "$ROOT" "$ROOT2"' EXIT
work2="$(mainpush_mkfixture "$ROOT2")"
fleet_named="$(dirname "$work2")/mcphost"
mv "$work2" "$fleet_named"
rm -f "$fleet_named/.buildloop/ci-equivalent.toml"
git -C "$fleet_named" -c user.name="Fixture Bot" -c user.email="fixture@example.invalid" commit -aqm "remove ci-equivalent.toml"
git -C "$fleet_named" config core.hooksPath "$MAINPUSH_SCRIPTS/repo-hooks"
export BUILD_JOURNAL_ROOT="$ROOT2/journal"
remote_before2="$(git -C "$fleet_named" ls-remote origin main | awk '{print $1}')"

pushd "$fleet_named" >/dev/null
git push origin HEAD:main >/tmp/mainpush-ac0b.$$.out 2>&1
rc_b=$?
rm -f "/tmp/mainpush-ac0b.$$.out"
popd >/dev/null

mainpush_expect "AC0: FLEET_REPOS-named repo (mcphost) still refused" '[ "$rc_b" -ne 0 ]'
mainpush_expect "AC0: FLEET_REPOS-named repo remote unchanged" '[ "$(git -C "$fleet_named" ls-remote origin main | awk "{print \$1}")" = "$remote_before2" ]'

exit "$mainpush_fail"
