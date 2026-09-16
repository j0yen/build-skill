# gatered fixtures

`2026-09-16-frozen-1435.md` is the real `~/brain/journal/build/2026-09-16.md`
build journal, copied verbatim and truncated at the first line whose
timestamp exceeds `2026-09-16T14:35:09Z` — the instant the 2026-09-16
stopgap (`~/.local/bin/gate-red-alarm.sh`) computed the aggregate that
opened `j0yen/prds#9`. Used by `scripts/gate-red-summary-selftest.sh`'s
AC2 case (PRD-build-gate-red-alarm-invariant) to prove `gate-red-summary.sh`
reproduces that aggregate (red=5, five mcphost slugs, hermetic-build the
top family) against the same real data — not a hand-written fixture the
same agent that wrote the assertions also invented.

Frozen once; never regenerate from a live journal (the point is a fixed,
known-answer snapshot).
