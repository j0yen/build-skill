#!/usr/bin/env bash
# governor_ac5_lint_fail_not_staged.sh —
# PRD-dream-depth-governor AC5: given a drafted fixture PRD that fails
# lint, when the post-run step executes, then that file is not staged
# for build-queue/ and the journal names the lint finding. Hermetic
# fixture, mirrors dream-governor-selftest.sh's AC5 block.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DG="$HERE/../scripts/dream-governor.sh"

t="$(mktemp -d "${TMPDIR:-/tmp}/governor-ac5.XXXXXX")"
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/prds/build-queue" "$t/prds/built-prds" "$t/prds/seeds" "$t/state/dream-governor" "$t/ledger" "$t/journal-dir"
git -C "$t/prds" init -q
git -C "$t/prds" config user.email test@example.com
git -C "$t/prds" config user.name "Test"
: > "$t/prds/.gitkeep"
git -C "$t/prds" add .gitkeep
git -C "$t/prds" commit -q -m init

printf 'DEPTH_MIN=8\nHEADROOM_MAX=500000\n' > "$t/state/dream-governor/config"
for i in 1 2; do
  printf '# PRD: fixture-q%s\n\n- Status: queued\n' "$i" > "$t/prds/build-queue/PRD-fixture-q$i.md"
done
cat > "$t/prds/seeds/2026-09-15-green-seed.md" <<EOF
- Source: manual
- Observed: 2026-09-15
- Status: pending
- Fingerprint: deadbeefdeadbeef

An observation.
EOF
printf 'date\tper_model\tweighted\tstatus\tcomplete\thosts\tmissing\tgenerated\n' > "$t/ledger/ledger.tsv"
printf '%s\t{}\t1000\tok\t1\t1\t0\t%s\n' "$(date -u +%F)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$t/ledger/ledger.tsv"

stub="$t/stub-draft.sh"
# systemd-run sets WorkingDirectory=$PRDS_DIR for this unit (see
# dream-governor.sh's launch_and_postprocess), so this stub operates on
# relative paths exactly like a real /dream invocation would from inside
# the PRDs clone.
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
set -e
mkdir -p visions
echo "a fixture vision" > visions/fixture.md
cat > build-queue/PRD-fixture-good.md <<'GOOD'
# PRD: fixture-good

- Status: queued
- build_target: shell
- Vision: visions/fixture.md
- Grounding: wwhtbt -- a fixture

## Acceptance criteria

1. P0 -- Given a thing, When it runs, Then it passes.
GOOD
cat > build-queue/PRD-fixture-bad.md <<'BAD'
# PRD: fixture-bad

- Status: queued
- build_target: not-a-real-target
- Vision: visions/fixture.md
- Grounding: wwhtbt -- a fixture

## Acceptance criteria

1. P0 -- Given a thing, When it runs, Then it fails lint on purpose.
BAD
git add visions/fixture.md build-queue/PRD-fixture-good.md build-queue/PRD-fixture-bad.md
git commit -q -m "dream: draft fixture-good, fixture-bad"
EOF
chmod +x "$stub"

out="$(DREAM_GOVERNOR_PRDS_DIR="$t/prds" \
  BUILD_STATE_DIR="$t/state" \
  DREAM_GOVERNOR_CONFIG="$t/state/dream-governor/config" \
  DREAM_GOVERNOR_JOURNAL="$t/journal-dir/dream-governor.log" \
  DREAM_GOVERNOR_LOCK="$t/state/dream-governor/run.lock" \
  DREAM_GOVERNOR_TOKEN_LEDGER_DIR="$t/ledger" \
  DREAM_GOVERNOR_DREAM_CMD="$stub" \
  DREAM_GOVERNOR_TIMEOUT_S=30 \
  "$DG" run 2>"$t/run.err")"

fail=0
if [ "$out" != "fire" ]; then
  echo "FAIL AC5: expected fire (drafting itself is dream's job, not a gate), got: $out (stderr: $(cat "$t/run.err"))"
  fail=1
fi
if [ -e "$t/prds/build-queue/PRD-fixture-bad.md" ]; then
  echo "FAIL AC5: lint-failing file still present in build-queue/"
  fail=1
fi
if [ ! -e "$t/prds/build-queue/PRD-fixture-good.md" ]; then
  echo "FAIL AC5: lint-passing file missing from build-queue/"
  fail=1
fi
jgrep="$(grep 'lint-fail' "$t/journal-dir/dream-governor.log" 2>/dev/null | tail -1)"
if ! printf '%s' "$jgrep" | grep -q "file=build-queue/PRD-fixture-bad.md"; then
  echo "FAIL AC5: journal does not name the lint finding -- $jgrep"
  fail=1
fi
[ "$fail" -eq 0 ] && echo "ok  AC5: lint-failing fixture PRD never staged for build-queue/, journal names the finding"
exit "$fail"
