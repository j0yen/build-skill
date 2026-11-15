#!/usr/bin/env bash
# dreamdry_ac06 — PRD-dream-dryrun-hook AC6 / R2 (known-bad control for the
# staged-corpus rule). Every file under the destination keeps its mtime across the
# AC1-AC5 shapes and this call, the temporary directory is gone afterwards, and a
# batch file whose slug equals a destination built-prds/ slug reads `ineligible —
# lint: slug-not-unique`, which a lint run in the file's own home does not report.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/dreamdry-common.sh"
dd_setup
dd_prd "$DD_T/dest/built-prds" dreamdry-old
# a DIFFERENT, earlier PRD that holds the slug (prd-lint tolerates an identical title+Drafted copy as "in transit")
sed -i -e 's/^# PRD — dreamdry-old:.*/# PRD — dreamdry-old: an older PRD that already holds this slug/' -e 's/^- Drafted: 2026-11-15$/- Drafted: 2026-10-01/' "$DD_T/dest/built-prds/PRD-dreamdry-old.md"
dd_prd "$DD_T/dest/build-queue" dreamdry-queued
dd_prd "$DD_T/dest/parked" dreamdry-parked
printf 'parked note\n' > "$DD_T/dest/parked/notes.txt"
before="$(dd_snapshot "$DD_T/dest")"
[ -n "$before" ] || dd_fail "AC6 snapshot empty"

# the shapes below replay AC1-AC5 against THIS destination
url="https://dreamdry.example.com/missing.csv"
dd_prd "$DD_T/drafts" dreamdry-url "" "3. P0 — Given the fixture, When fetched, Then 200. (Live; evidence: \`cmd:curl -sf -o /dev/null $url\`)"
dd_probe HEAD "$url" 404
dd_prd "$DD_T/drafts" dreamdry-dep "- Depends-on: PRD-dreamdry-nowhere.md"
dd_prd "$DD_T/drafts" dreamdry-a
dd_prd "$DD_T/drafts" dreamdry-b "- Depends-on: PRD-dreamdry-a.md"
dd_answer dreamdry-b "tick-would: skip:depends-unresolved:dreamdry-a"
dd_prd "$DD_T/drafts" dreamdry-p; dd_answer dreamdry-p "tick-would: skip:prefix-denied"
dd_prd "$DD_T/drafts" dreamdry-queued   # a given file wins over the destination's same-named link
for args in "dreamdry-url" "dreamdry-dep" "dreamdry-a dreamdry-b" "dreamdry-b" "dreamdry-p" "dreamdry-queued"; do
  files=(); for s in $args; do files+=("$DD_T/drafts/PRD-$s.md"); done
  dd_run --prd-dir "$DD_T/dest" "${files[@]}"
  dd_run --prd-dir "$DD_T/dest" --json "${files[@]}"
done

dd_prd "$DD_T/drafts" dreamdry-old
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-old.md"
dd_expect_line dreamdry-old "admit-would: dreamdry-old ineligible — lint: slug-not-unique claims=unknown open-runs=unknown" "AC6 collision with destination built-prds/"
dd_expect_rc 3 "AC6 collision"
home_lint="$(bash "$DD_REPO/scripts/prd-lint.sh" "$DD_T/drafts/PRD-dreamdry-old.md" 2>&1)"
if grep -q 'slug-not-unique' <<<"$home_lint"; then dd_fail "AC6 control: the home lint already reports slug-not-unique: $home_lint"; else dd_ok "AC6 control: a lint in the file's own home does not report slug-not-unique"; fi

# documented boundary: an identical copy (same title and Drafted:) is prd-lint's "same PRD in transit"
dd_prd "$DD_T/dest/built-prds" dreamdry-transit; dd_prd "$DD_T/drafts" dreamdry-transit
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-transit.md"
grep -q '^admit-would: dreamdry-transit ineligible — lint: slug-not-unique' <<<"$DD_OUT" \
  && dd_fail "in-transit copy refused (prd-lint's tolerance not inherited): $DD_OUT" || dd_ok "boundary: an identical in-transit copy keeps prd-lint's tolerance (the dry run adds no lint rule)"
rm -f "$DD_T/dest/built-prds/PRD-dreamdry-transit.md"

# two batch members with one slug (same file name from two homes)
mkdir -p "$DD_T/drafts2/visions"; cp "$DD_T/drafts/visions/"* "$DD_T/drafts2/visions/"
dd_prd "$DD_T/drafts2" dreamdry-a
dd_run --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-a.md" "$DD_T/drafts2/PRD-dreamdry-a.md"
[ "$(grep -c '^admit-would: dreamdry-a ineligible — lint: slug-not-unique ' <<<"$DD_OUT")" -eq 2 ] \
  && dd_ok "R1(b) two batch members sharing a slug both read slug-not-unique" || dd_fail "batch collision: $DD_OUT"
dd_expect_rc 3 "batch collision"

after="$(dd_snapshot "$DD_T/dest")"
if [ "$before" = "$after" ]; then dd_ok "AC6 every file under the destination kept its mtime and size ($(wc -l <<<"$before") files)"; else dd_fail "AC6 destination changed: $(diff <(echo "$before") <(echo "$after"))"; fi
dd_tmp_empty "AC6"

# R2 syscall proof: no open-for-write, create, rename or unlink under the destination
if command -v strace >/dev/null 2>&1; then
  tr="$DD_T/strace.log"
  strace -f -qq -e trace=open,openat,creat,rename,renameat,renameat2,unlink,unlinkat,mkdir,mkdirat,truncate,utimensat -o "$tr" \
    bash "$DD_SCRIPT" --prd-dir "$DD_T/dest" "$DD_T/drafts/PRD-dreamdry-a.md" "$DD_T/drafts/PRD-dreamdry-b.md" "$DD_T/drafts/PRD-dreamdry-old.md" >/dev/null 2>&1
  real_dest="$(readlink -f "$DD_T/dest")"
  bad="$(grep -E "\"($DD_T/dest|$real_dest)[^\"]*\"" "$tr" | grep -E 'O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|creat\(|rename|unlink|mkdir|truncate|utimensat' || true)"
  # staged symlinks resolve INTO the destination: a write through <tmp>/built-prds would show the tmp path
  bad2="$(grep -E '/(built-prds|parked)/[^"]*"' "$tr" | grep -E 'O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|rename|unlink|truncate|utimensat' || true)"
  if [ -z "$bad$bad2" ]; then dd_ok "R2 strace: no write-class syscall on any destination path or through the staged links"; else dd_fail "R2 strace write-class calls: $bad $bad2"; fi
else
  echo "skip R2 strace: strace not installed"
fi
dd_finish
