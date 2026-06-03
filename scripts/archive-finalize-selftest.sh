#!/usr/bin/env bash
# archive-finalize-selftest.sh — durable acceptance harness for
# archive-finalize.sh (PRD-build-archive-finalize). Builds throwaway git
# fixtures under a tempdir and asserts the fenced/idempotent behavior.
# No network: uses local bare repos as origins and --no-push.
#
# Run: bash scripts/archive-finalize-selftest.sh   (exit 0 = all pass)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
AFZ="$HERE/archive-finalize.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/afz-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
cd "$T"
PASS=0; FAIL=0
ck(){ if eval "$2"; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); fi; }
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# ---- AC1 + AC6: a C5-failing PRD is refused with zero mutation --------
mkdir -p A/repo/src; git -C A/repo init -q -b main
printf '[package]\nname="fixa"\nversion="0.1.0"\nedition="2021"\n' > A/repo/Cargo.toml
echo 'pub fn f(){}' > A/repo/src/lib.rs
gc A/repo add -A; gc A/repo commit -qm init
printf '# fixa\n\n## TL;DR\n\nfixa.\n\n## Acceptance\n\n1. a.\n2. b.\n' > A/PRD-fixa.md
cat > A/manifest.json <<EOF
{"prds":[{"slug":"fixa","build_target":"rust-cli","output_repo_path":"$T/A/repo","path":"$T/A/PRD-fixa.md","verification":null}]}
EOF
rs0="$(sha1sum A/repo/src/lib.rs)"
MANIFEST="$T/A/manifest.json" REPOS_MD="$T/A/REPOS.md" bash "$AFZ" fixa --no-push >/dev/null 2>A/err; rc=$?
ck "AC1 C5-fail exits 10"            "[ $rc -eq 10 ]"
ck "AC1 message says not-clerical"   "grep -q 'not-clerical: C5' A/err"
ck "AC1 repo tree untouched"         "[ -z \"\$(git -C A/repo status --porcelain)\" ]"
ck "AC6 no .rs file changed"         "[ \"\$rs0\" = \"\$(sha1sum A/repo/src/lib.rs)\" ]"

# ---- AC5 + AC2 + AC4: extend repo, dry-run then real CHANGELOG fix ----
git init -q --bare B/origin.git
mkdir -p B/repo/src; git -C B/repo init -q -b main
printf '[package]\nname="fixb"\nversion="0.4.2"\nedition="2021"\n' > B/repo/Cargo.toml
echo 'pub fn g(){}' > B/repo/src/lib.rs; echo '# fixb' > B/repo/README.md
gc B/repo add -A; gc B/repo commit -qm init
git -C B/repo remote add origin "$T/B/origin.git"; git -C B/repo push -q origin main
git -C B/repo branch --set-upstream-to=origin/main main >/dev/null 2>&1
printf '# fixb\n\n## TL;DR\n\nAdds a rollup to fixb.\n\n## Acceptance\n\n1. a.\n2. b.\n' > B/PRD-fixb.md
printf '| [fixb](https://github.com/j0yen/fixb) | `fixb` | x |\n' > B/REPOS.md
cat > B/manifest.json <<EOF
{"prds":[{"slug":"fixb","build_target":"rust-extend","output_repo_path":"$T/B/repo","path":"$T/B/PRD-fixb.md","verification":{"ac1":"t::1","ac2":"t::2"}}]}
EOF
head0="$(git -C B/repo rev-parse HEAD)"
MANIFEST="$T/B/manifest.json" REPOS_MD="$T/B/REPOS.md" bash "$AFZ" fixb --c1-prechecked --no-push --dry-run >/dev/null 2>B/dry
ck "AC5 dry-run plans C3"            "grep -q 'C3:.*CHANGELOG' B/dry"
ck "AC5 dry-run made no commit"      "[ \"\$head0\" = \"\$(git -C B/repo rev-parse HEAD)\" ]"
ck "AC5 dry-run wrote no CHANGELOG"  "[ ! -f B/repo/CHANGELOG.md ]"
echo 'DIRTY' > B/repo/src/lib.rs   # unrelated dirty file
MANIFEST="$T/B/manifest.json" REPOS_MD="$T/B/REPOS.md" bash "$AFZ" fixb --c1-prechecked --no-push --paired 1,2 >/dev/null 2>B/run
ck "AC2 CHANGELOG gets v0.4.2"       "grep -q '^## v0.4.2' B/repo/CHANGELOG.md"
ck "AC2 CHANGELOG carries TL;DR"     "grep -q 'rollup to fixb' B/repo/CHANGELOG.md"
files="$(git -C B/repo show --name-only --pretty=format: HEAD | grep -v '^$')"
ck "AC4 commit has CHANGELOG.md"     "echo \"\$files\" | grep -qx 'CHANGELOG.md'"
ck "AC4 commit omits dirty lib.rs"   "! echo \"\$files\" | grep -qx 'src/lib.rs'"
ck "AC4 dirty file still uncommitted" "git -C B/repo status --porcelain | grep -q 'lib.rs'"
git -C B/repo push -q origin main
MANIFEST="$T/B/manifest.json" REPOS_MD="$T/B/REPOS.md" bash "$AFZ" fixb --c1-prechecked --no-push --paired 1,2 >/dev/null 2>B/run2
ck "re-gate ready once pushed"        "grep -q 'finalize-verdict] ready' B/run2"

# ---- AC3: new-repo missing only REPOS.md entry, idempotent -----------
git init -q --bare C/origin.git
mkdir -p C/fixc/src; git -C C/fixc init -q -b main
printf '[package]\nname="fixc"\nversion="0.1.0"\nedition="2021"\n' > C/fixc/Cargo.toml
echo 'pub fn h(){}' > C/fixc/src/lib.rs
printf '# fixc\n\nstuff\n\n## Install\n\ncargo install --path .\n' > C/fixc/README.md
gc C/fixc add -A; gc C/fixc commit -qm init
git -C C/fixc remote add origin "$T/C/origin.git"; git -C C/fixc push -q origin main
printf '# fixc\n\n## TL;DR\n\nA fixc tool.\n\n## Acceptance\n\n1. a.\n' > C/PRD-fixc.md
printf '# repos\n## Tools\n' > C/REPOS.md; git -C "$T/C" init -q
cat > C/manifest.json <<EOF
{"prds":[{"slug":"fixc","build_target":"rust-cli","output_repo_path":"$T/C/fixc","path":"$T/C/PRD-fixc.md","verification":{"ac1":"t::1"}}]}
EOF
MANIFEST="$T/C/manifest.json" REPOS_MD="$T/C/REPOS.md" bash "$AFZ" fixc --c1-prechecked --no-push --paired 1 >/dev/null 2>C/run
ck "AC3 REPOS.md gains fixc row"     "grep -q 'j0yen/fixc)' C/REPOS.md"
MANIFEST="$T/C/manifest.json" REPOS_MD="$T/C/REPOS.md" bash "$AFZ" fixc --c1-prechecked --no-push --paired 1 >/dev/null 2>C/run2
ck "AC3 second run idempotent (1 row)" "[ \$(grep -c 'j0yen/fixc)' C/REPOS.md) -eq 1 ]"

# ---- C1 real gate: a failing cargo test is refused -------------------
mkdir -p D/repo/src; git -C D/repo init -q -b main
printf '[package]\nname="fixd"\nversion="0.1.0"\nedition="2021"\n' > D/repo/Cargo.toml
printf '#[test] fn boom(){ assert_eq!(1,2); }\n' > D/repo/src/lib.rs
gc D/repo add -A; gc D/repo commit -qm init
printf '# fixd\n\n## TL;DR\n\nfixd.\n\n## Acceptance\n\n1. a.\n' > D/PRD-fixd.md
cat > D/manifest.json <<EOF
{"prds":[{"slug":"fixd","build_target":"rust-cli","output_repo_path":"$T/D/repo","path":"$T/D/PRD-fixd.md","verification":{"ac1":"x"}}]}
EOF
MANIFEST="$T/D/manifest.json" REPOS_MD="$T/D/REPOS.md" bash "$AFZ" fixd --no-push --paired 1 --test-cmd 'cargo test' >/dev/null 2>D/err; rc=$?
ck "C1 broken-test refused (exit 10)" "[ $rc -eq 10 ]"
ck "C1 message says not-clerical C1"  "grep -q 'not-clerical: C1' D/err"

echo "----"
echo "archive-finalize-selftest: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
