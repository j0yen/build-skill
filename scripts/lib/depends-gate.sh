#!/usr/bin/env bash
# depends-gate.sh — single shared Depends-on resolution function
# (PRD-build-select-guard-depends-before-slot requirement 2). Sourced
# (never executed) by select-guard.sh, and by anything standing in for the
# coordinator's own Depends-on check (SKILL.md Phase 2 / select-tick.sh),
# so every call site resolves "unmet" identically — one definition, not a
# second bespoke pass that can quietly drift from the first.
#
# depends_gate_unmet <prd-path> <built-prds-dir>
#   Reads <prd-path>'s frontmatter `Depends-on:` field (same key shapes
#   read_field() elsewhere in scripts/ already accepts: `- Depends-on:`,
#   `Depends-on:`, `**Depends-on:**`, first match in the first 80 lines).
#   Comma-separated names; "none"/"-"/"n/a"/"na"/"[]" (any case, ignoring
#   internal whitespace) means no dependencies. For each named PRD
#   (normalized to `PRD-<name>.md` before the filesystem check — a bare
#   `foo`, `foo.md`, or `PRD-foo.md` all resolve to the same file), prints
#   the name EXACTLY as written in the frontmatter, one per line, when
#   `<built-prds-dir>/PRD-<name>.md` does not exist. Prints nothing when
#   every dependency is met (or there is no Depends-on line, or it reads
#   "none").
#
#   Returns 0 when nothing is unmet (output is empty); returns 1 when at
#   least one dependency is unmet (output is non-empty) — callers may use
#   either the exit code or the presence of output; both agree by
#   construction, so a caller only needs to check the one it prefers.
#
#   No side effects: no journal writes, no stderr diagnostics. Callers
#   journal (select-guard.sh does, under its own reason/format).
depends_gate_unmet() {
  local prd="$1" built_dir="$2"
  [ -f "$prd" ] || return 0

  local raw
  raw=$(head -n 80 "$prd" \
    | grep -E "^(- *Depends-on:|Depends-on:|\*\*Depends-on:\*\*)" | head -n1 \
    | sed -E "s/^(- *Depends-on:|Depends-on:|\*\*Depends-on:\*\*)[[:space:]]*//" \
    | sed -E 's/[[:space:]]*#.*$//' \
    | sed -E 's/[[:space:]]+$//')
  [ -n "$raw" ] || return 0

  local normalized
  normalized=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[][:space:]]//g')
  case "$normalized" in
    ''|none|-|n/a|na) return 0 ;;
  esac

  local unmet_count=0 name base
  local IFS=','
  for name in $raw; do
    name=$(printf '%s' "$name" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ -n "$name" ] || continue
    base="$name"
    case "$base" in PRD-*) : ;; *) base="PRD-$base" ;; esac
    case "$base" in *.md) : ;; *) base="$base.md" ;; esac
    if [ ! -f "$built_dir/$base" ]; then
      printf '%s\n' "$name"
      unmet_count=$((unmet_count + 1))
    fi
  done
  [ "$unmet_count" -eq 0 ]
}
