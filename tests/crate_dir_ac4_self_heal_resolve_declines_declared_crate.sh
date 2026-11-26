#!/usr/bin/env bash
# crate_dir_ac4_self_heal_resolve_declines_declared_crate.sh —
# PRD-build-contract-declared-crate-dir AC4.
#
# Given a queued fixture PRD that declares crate_dir and fails lint, When
# scripts/classification-self-heal.sh resolve runs on it, Then it exits 1
# printing `crate_dir declared -- never rewritten`, and the PRD bytes, the
# fixture repo's git HEAD and the manifest are unchanged.
#
# Fixtures only: a bare origin + clone for the PRD repo, a git build_into, a
# scratch manifest/journal, and a recording stand-in for substrate-probe.sh
# so the test also sees that resolve declines before probing. The whole
# fixture tree is hashed before and after: resolve must write nothing.
. "$(dirname "$0")/fixtures/crate-dir-common.sh"
CSH="$CD_REPO/scripts/classification-self-heal.sh"
[ -x "$CSH" ] || { echo "FAIL: $CSH not executable" >&2; exit 2; }

fx="$CD_ROOT/fx"; mkdir -p "$fx"
gc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# build_into: a git Python repo whose ledger-read/ exists without a Cargo.toml
git init -q "$fx/swarm"
printf '[project]\nname = "swarm"\n' > "$fx/swarm/pyproject.toml"
mkdir -p "$fx/swarm/ledger-read/src"; echo "// not a crate yet" > "$fx/swarm/ledger-read/src/lib.rs"
gc "$fx/swarm" add -A; gc "$fx/swarm" commit -qm init

# the PRD repo: bare origin + clone, one queued PRD declaring crate_dir
git init -q --bare "$fx/origin.git"
git clone -q "$fx/origin.git" "$fx/prds" 2>/dev/null
mkdir -p "$fx/prds/build-queue" "$fx/prds/visions"
echo "plain vision." > "$fx/prds/visions/plain.md"
f="$fx/prds/build-queue/PRD-cd4-declared.md"
cd_prd "$f" rust-extend "$fx/swarm" ledger-read
gc "$fx/prds" add -A; gc "$fx/prds" commit -qm "add cd4-declared"
defbr="$(git -C "$fx/prds" symbolic-ref --short HEAD)"
git -C "$fx/prds" push -q origin "$defbr"

# scratch manifest + journal path + a probe stand-in that records the call
# and then runs the real substrate-probe.sh
mkdir -p "$fx/state"
printf '{"prds":{"cd4-declared":{"status":"queued"}},"built_at":"2020-01-01T00:00:00Z"}\n' > "$fx/state/manifest.json"
printf '#!/bin/sh\necho called >> "%s"\nexec "%s" "$@"\n' "$CD_ROOT/probe-calls" "$CD_REPO/scripts/substrate-probe.sh" > "$CD_ROOT/probe.sh"
chmod +x "$CD_ROOT/probe.sh"

# Given: the PRD fails lint
"$CD_LINT" "$f" >/dev/null 2>&1; lint_rc=$?
cd_expect "AC4 given: the queued crate_dir PRD fails lint" "[ $lint_rc -eq 1 ]"

tree_hash() { (cd "$fx" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum); }
before_tree="$(tree_hash)"
before_prd="$(sha256sum < "$f")"
before_head="$(git -C "$fx/prds" rev-parse HEAD)"
before_origin="$(git -C "$fx/origin.git" rev-parse "$defbr")"
before_into="$(git -C "$fx/swarm" rev-parse HEAD)"
before_manifest="$(sha256sum < "$fx/state/manifest.json")"

out="$(BUILD_STATE_DIR="$fx/state" BUILD_MANIFEST="$fx/state/manifest.json" \
  JOURNAL="$fx/journal.md" SUBSTRATE_PROBE="$CD_ROOT/probe.sh" \
  "$CSH" resolve "$f" 2>&1)"; rc=$?

cd_expect "AC4: resolve exits 1" "[ $rc -eq 1 ]"
cd_expect "AC4: prints 'declined: cd4-declared: crate_dir declared -- never rewritten'" \
  "grep -qx 'declined: cd4-declared: crate_dir declared -- never rewritten' <<<\"\$out\""
cd_expect "AC4: PRD bytes unchanged" "[ \"\$(sha256sum < \"\$f\")\" = \"\$before_prd\" ]"
cd_expect "AC4: PRD repo HEAD unchanged" "[ \"\$(git -C \"\$fx/prds\" rev-parse HEAD)\" = \"\$before_head\" ]"
cd_expect "AC4: origin unchanged (nothing pushed)" "[ \"\$(git -C \"\$fx/origin.git\" rev-parse \"\$defbr\")\" = \"\$before_origin\" ]"
cd_expect "AC4: build_into repo HEAD unchanged" "[ \"\$(git -C \"\$fx/swarm\" rev-parse HEAD)\" = \"\$before_into\" ]"
cd_expect "AC4: manifest unchanged" "[ \"\$(sha256sum < \"\$fx/state/manifest.json\")\" = \"\$before_manifest\" ]"
cd_expect "AC4: no journal written" "[ ! -e \"\$fx/journal.md\" ]"
cd_expect "AC4: declined before probing (probe never called)" "[ ! -e \"\$CD_ROOT/probe-calls\" ]"
cd_expect "AC4: writes nothing (fixture tree hash unchanged)" "[ \"\$(tree_hash)\" = \"\$before_tree\" ]"

exit $cd_fail
