#!/usr/bin/env bash
# crate_dir_ac4_parity_self_heal_guard_covers_lint_reader.sh —
# PRD-build-contract-declared-crate-dir AC4 / R4 across header forms.
#
# For every header form in tests/fixtures/crate-dir-forms.sh in which
# scripts/prd-lint.sh finds a crate_dir key, scripts/classification-self-heal.sh
# resolve declines with `crate_dir declared -- never rewritten`, exits 1 and
# writes nothing: the PRD bytes, the PRD repo's HEAD and its origin are
# unchanged. The guard may be broader than the lint (forms the lint does not
# read are reported, not asserted), never narrower. When prd-lint.sh's
# crate_dir reader fails, resolve declines too (fail closed). A PRD with no
# crate_dir in any form is still resolved as before.
#
# Fixtures only: a private bare origin + clone for the PRD repo, a Python
# build_into holding ledger-read/ without a Cargo.toml (the probe reads it as
# python, so a resolve that is not declined rewrites build_target and pushes
# to the fixture origin), scratch manifest/journal.
. "$(dirname "$0")/fixtures/crate-dir-common.sh"
. "$(dirname "$0")/fixtures/crate-dir-forms.sh"
CSH="$CD_REPO/scripts/classification-self-heal.sh"
[ -x "$CSH" ] || { echo "FAIL: $CSH not executable" >&2; exit 2; }
PY3="$(command -v python3)"

fx="$CD_ROOT/fx"; mkdir -p "$fx/state"
gc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
mkdir -p "$fx/swarm/ledger-read"
printf '[project]\nname = "swarm"\n' > "$fx/swarm/pyproject.toml"

git init -q --bare "$fx/origin.git"
git clone -q "$fx/origin.git" "$fx/prds" 2>/dev/null
mkdir -p "$fx/prds/build-queue" "$fx/prds/visions"
echo "plain vision." > "$fx/prds/visions/plain.md"
T="$CD_ROOT/forms.tsv"; : > "$T"
cdf_write "$fx/prds/build-queue" "$fx/swarm" h "$T"
gc "$fx/prds" add -A; gc "$fx/prds" commit -qm "crate_dir header forms"
defbr="$(git -C "$fx/prds" symbolic-ref --short HEAD)"
git -C "$fx/prds" push -q -u origin "$defbr" 2>/dev/null
printf '{"prds":{},"built_at":"2020-01-01T00:00:00Z"}\n' > "$fx/state/manifest.json"

# resolve_declines <file> <label> <line-suffix> [env...]: resolve declines
# with "declined: <slug>: <suffix>", exits 1, and writes nothing.
resolve_declines() {
  local f="$1" label="$2" suffix="$3"; shift 3
  local slug; slug="$(basename "$f" .md)"; slug="${slug#PRD-}"
  local b_prd b_head b_origin out rc
  b_prd="$(sha256sum < "$f")"
  b_head="$(git -C "$fx/prds" rev-parse HEAD)"
  b_origin="$(git -C "$fx/origin.git" rev-parse "$defbr")"
  out="$(env "$@" BUILD_STATE_DIR="$fx/state" BUILD_MANIFEST="$fx/state/manifest.json" \
    JOURNAL="$fx/journal.md" "$CSH" resolve "$f" 2>&1)"; rc=$?
  local line_ok=0
  grep -qxF "declined: $slug: $suffix" <<<"$out" && line_ok=1
  local nothing=1
  [ "$(sha256sum < "$f")" = "$b_prd" ] || nothing=0
  [ "$(git -C "$fx/prds" rev-parse HEAD)" = "$b_head" ] || nothing=0
  [ "$(git -C "$fx/origin.git" rev-parse "$defbr")" = "$b_origin" ] || nothing=0
  cd_expect "$label: resolve exits 1 printing 'declined: $slug: $suffix'" "[ $rc -eq 1 ] && [ $line_ok -eq 1 ]"
  cd_expect "$label: PRD bytes, repo HEAD and origin unchanged" "[ $nothing -eq 1 ]"
  [ "$nothing" -eq 1 ] || echo "  $label: resolve rc=$rc output: $(tr '\n' ' ' <<<"$out")" >&2
}

while IFS=$'\t' read -r f form exp; do
  lint="$(cdf_lint_value "$f")"
  cd_expect "lint reads $form as $exp (findings say $lint)" "[ '$lint' = '$exp' ]"
  case "$lint" in
    null|UNDETERMINED) ;;  # no key the lint reads: the guard may still decline (broader)
    *) resolve_declines "$f" "RQ2 $form (lint reads crate_dir $lint)" "crate_dir declared -- never rewritten" ;;
  esac
done < "$T"

# Broader-than-lint forms, reported only: resolve on a form the lint does not
# read as crate_dir (it may decline or resolve; neither is asserted).
for form in indented-bullet window-80-after-cr; do
  f="$fx/prds/build-queue/PRD-h-$form.md"
  out="$(BUILD_STATE_DIR="$fx/state" BUILD_MANIFEST="$fx/state/manifest.json" JOURNAL="$fx/journal.md" \
    "$CSH" resolve "$f" 2>&1 | head -n1)"
  echo "info: $form (lint reads no crate_dir): $out"
done

# Fail closed: python3 refuses only inside prd-lint.sh's crate_dir reader mode.
mkdir -p "$CD_ROOT/failbin"
printf '#!/bin/sh\n[ "${LINT_PRINT_CRATE_DIR:-}" = 1 ] && { echo "test: reader refused" >&2; exit 1; }\nexec %s "$@"\n' "$PY3" > "$CD_ROOT/failbin/python3"
chmod +x "$CD_ROOT/failbin/python3"
resolve_declines "$fx/prds/build-queue/PRD-h-double-space-key.md" "RQ2 fail-closed (reader fails)" \
  "crate_dir unknown (prd-lint.sh --print-crate-dir failed) -- never rewritten" PATH="$CD_ROOT/failbin:$PATH"

# No crate_dir in any form: resolve still rewrites build_target and pushes.
f="$fx/prds/build-queue/PRD-h-absent.md"
b_origin="$(git -C "$fx/origin.git" rev-parse "$defbr")"
out="$(BUILD_STATE_DIR="$fx/state" BUILD_MANIFEST="$fx/state/manifest.json" JOURNAL="$fx/journal.md" \
  "$CSH" resolve "$f" 2>&1)"; rc=$?
cd_expect "absent: resolve still resolves a PRD without crate_dir (exit 0)" "[ $rc -eq 0 ]"
cd_expect "absent: build_target rewritten to python-cli" "grep -qx -- '- build_target: python-cli' \"\$f\""
cd_expect "absent: the rewrite reached the fixture origin" \
  "[ \"\$(git -C \"\$fx/origin.git\" rev-parse \"\$defbr\")\" != \"\$b_origin\" ]"

exit $cd_fail
