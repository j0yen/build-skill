#!/usr/bin/env bash
# substrate-probe.sh — single source of truth for "what language substrate
# lives at this build_into path" (PRD-build-classification-self-heal).
#
# Shared by:
#   - prd-lint.sh's build-into-substrate-mismatch check (that check
#     duplicates this exact depth-1 algorithm in its own python heredoc
#     instead of shelling out to this script, per this repo's convention of
#     duplicating small helpers across self-contained scripts rather than
#     sourcing — see select-guard.sh's read_field comment for precedent;
#     keep the two in step by hand).
#   - scan-prds.sh's manifest `substrate` field (P2).
#   - classification-self-heal.sh's `resolve` auto-fix (requirement 3).
#
# Detection is depth <=1: Cargo.toml/pyproject.toml directly at <path>, OR
# in any immediate subdirectory of <path> (covers a workspace root whose
# member crates/projects live one level down without their own top-level
# manifest). Not a recursive walk — deep vendor trees must not false-positive
# a substrate signal.
#
# Usage: substrate-probe.sh <path> [--format text|json]
#
# JSON shape:
#   {"path": "<abs-or-given>", "exists": bool,
#    "cargo_toml": bool, "cargo_members": ["<subdir>", ...],
#    "pyproject_toml": bool, "pyproject_dirs": ["<subdir>", ...],
#    "substrate": "cargo"|"python"|"mixed"|"none"|"absent"}
#
# Exit: 0 always (a probe reports what it finds; it is not a pass/fail gate).
set -uo pipefail

usage() { echo "usage: substrate-probe.sh <path> [--format text|json]" >&2; }

fmt="json"
path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --format) shift; fmt="${1:-}"; [ -n "$fmt" ] || { usage; exit 2; }; shift ;;
    --format=*) fmt="${1#--format=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "substrate-probe: unknown flag: $1" >&2; usage; exit 2 ;;
    *) [ -z "$path" ] || { usage; exit 2; }; path="$1"; shift ;;
  esac
done
[ -n "$path" ] || { usage; exit 2; }
case "$fmt" in text|json) ;; *) echo "substrate-probe: --format must be text or json" >&2; exit 2 ;; esac

python3 - "$path" "$fmt" <<'PY'
import json, os, sys

path, fmt = sys.argv[1], sys.argv[2]

def immediate_subdirs_with(base, filename):
    out = []
    try:
        for name in sorted(os.listdir(base)):
            sub = os.path.join(base, name)
            if os.path.isdir(sub) and os.path.isfile(os.path.join(sub, filename)):
                out.append(name)
    except OSError:
        pass
    return out

exists = os.path.isdir(path)
cargo_toml = os.path.isfile(os.path.join(path, "Cargo.toml")) if exists else False
cargo_members = immediate_subdirs_with(path, "Cargo.toml") if exists else []
pyproject_toml = os.path.isfile(os.path.join(path, "pyproject.toml")) if exists else False
pyproject_dirs = immediate_subdirs_with(path, "pyproject.toml") if exists else []

cargo_present = cargo_toml or bool(cargo_members)
python_present = pyproject_toml or bool(pyproject_dirs)

if not exists:
    substrate = "absent"
elif cargo_present and python_present:
    substrate = "mixed"
elif cargo_present:
    substrate = "cargo"
elif python_present:
    substrate = "python"
else:
    substrate = "none"

result = {
    "path": path,
    "exists": exists,
    "cargo_toml": cargo_toml,
    "cargo_members": cargo_members,
    "pyproject_toml": pyproject_toml,
    "pyproject_dirs": pyproject_dirs,
    "substrate": substrate,
}

if fmt == "json":
    print(json.dumps(result))
else:
    print(f"path: {result['path']}")
    print(f"exists: {result['exists']}")
    print(f"cargo_toml: {result['cargo_toml']}  cargo_members: {result['cargo_members']}")
    print(f"pyproject_toml: {result['pyproject_toml']}  pyproject_dirs: {result['pyproject_dirs']}")
    print(f"substrate: {result['substrate']}")
PY
