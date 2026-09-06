#!/usr/bin/env bash
# onboard-repo.sh — take a crate with real, tested, pushed code from zero
# autobuilder scaffolding to gate-evaluable in one command.
# PRD-build-repo-onboard.
#
# The /build fleet's 25-receipt gate (extend-gate.sh) assumes every extended
# repo already carries the scaffolding mcphost was hand-built with:
# agent/intent-card.json, agent/proof-lanes.toml, agent/owner-map.json,
# agent/test-map.json, agent/AUTOBUILDER_PROGRAM.md, and a v* tag lineage.
# A repo lacking these structurally can never pass receipts that assume
# them (intake, vti-plan, rollback-plan, ...) no matter how good its code
# is. This script generates the scaffolding from introspecting the repo —
# it does not touch the gate, its receipts, or extend-gate.sh itself
# (non-goal), and it makes no repo more likely to pass a receipt that
# describes something actually true about the code (also a non-goal).
#
# Usage:
#   onboard-repo.sh <repo> [--check] [--rollback-model revert-commits|redeploy-tag]
#   onboard-repo.sh --list
#
# Modes:
#   default    Generate, only where absent: agent/intent-card.json (via
#              intent-card-refresh.sh from the newest built/archived PRD
#              naming this repo, else a minimal truthful card marked
#              onboarded-without-prd), agent/proof-lanes.toml,
#              agent/owner-map.json, agent/test-map.json (from the repo's
#              actual src/tests/ layout), agent/AUTOBUILDER_PROGRAM.md
#              (repo name, build commands, rollback_model line, PRD
#              workspace-location note). An existing agent/ file is left
#              byte-identical and reported `kept`; only absent files are
#              written. If the repo has zero `v*` tags, tags
#              `v<Cargo.toml version>` (annotated) at HEAD; if any `v*` tag
#              exists, the tag step is a no-op.
#   --check    Print the create/keep/tag plan; write nothing, tag nothing.
#   --rollback-model  revert-commits (default, matches the gate's own
#              default) or redeploy-tag. Recorded as a `rollback_model:`
#              line in the generated AUTOBUILDER_PROGRAM.md (the same file
#              autobuilder's rollback.rs falls back to reading when
#              intent-card.json has no rollback_model of its own — see
#              autobuilder/src/rollback.rs explicit_rollback_model). Only
#              applies when AUTOBUILDER_PROGRAM.md is being newly created;
#              an existing one is never rewritten.
#   --list     Scan ~/wintermute/*/Cargo.toml, print each crate's
#              onboarding state (scaffolded / partial / none) as a table.
#              Ignores --check / --rollback-model / <repo>.
#
# Never overwrites an existing agent/ file — re-running on an onboarded
# repo is a no-op (all-kept, exit 0). Refuses on a dirty working tree
# before writing anything (same convention as extend-gate.sh). A directory
# with no Cargo.toml at its root exits 2 naming the expectation.
#
# Exit codes:
#   0  ok (including --check and idempotent no-op re-runs)
#   1  usage error
#   2  no Cargo.toml at <repo> (or <repo> not found) — not a Rust crate/workspace root
#   3  dirty working tree — refused before writing anything
#   4  repo is not a git repository
#
# What this script deliberately does NOT do (non-goals, PRD-build-repo-onboard):
#   - Guarantee a green gate. A real reviewer block or failing proof stays
#     real; onboarding only removes missing-scaffolding blocks.
#   - Fabricate PRD content. `ac-traceability` reads a literal `PRD-*.md`
#     at the repo root (or `extended-gates.toml`'s `prd_path`) — this
#     script never copies/symlinks a PRD in on the repo's behalf; that is
#     a per-repo judgment call left to the operator (see the printed
#     summary's "still needs" section).
#   - Retroactive tag archaeology beyond one initial tag.
#   - Touch mcphost (already onboarded) or the gate itself.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"

die() { echo "onboard-repo: $2" >&2; exit "$1"; }

usage() {
  cat <<'EOF'
usage: onboard-repo.sh <repo> [--check] [--rollback-model revert-commits|redeploy-tag]
       onboard-repo.sh --list
EOF
}

AGENT_FILES=(intent-card.json proof-lanes.toml owner-map.json test-map.json AUTOBUILDER_PROGRAM.md)

# ---------------------------------------------------------------------------
# --list: scan ~/wintermute/*/Cargo.toml for onboarding state.
# ---------------------------------------------------------------------------
list_mode() {
  printf '%-24s %-12s %s\n' "crate" "state" "repo"
  local dir name state present count
  for dir in "$HOME"/wintermute/*/; do
    [ -f "$dir/Cargo.toml" ] || continue
    name="$(basename "$dir")"
    count=0
    for f in "${AGENT_FILES[@]}"; do
      [ -f "$dir/agent/$f" ] && count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then
      state="none"
    elif [ "$count" -eq "${#AGENT_FILES[@]}" ]; then
      state="scaffolded"
    else
      state="partial(${count}/${#AGENT_FILES[@]})"
    fi
    printf '%-24s %-12s %s\n' "$name" "$state" "${dir%/}"
  done
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
[ $# -ge 1 ] || { usage >&2; exit 1; }
case "$1" in -h|--help) usage; exit 0 ;; esac
if [ "$1" = "--list" ]; then
  list_mode
  exit 0
fi

repo_arg="$1"; shift
check_mode=false
rollback_model="revert-commits"

while [ $# -gt 0 ]; do
  case "$1" in
    --check) check_mode=true; shift ;;
    --rollback-model)
      rollback_model="${2:?onboard-repo: --rollback-model needs a value}"
      case "$rollback_model" in
        revert-commits|redeploy-tag) ;;
        *) die 1 "--rollback-model must be revert-commits or redeploy-tag, got $rollback_model" ;;
      esac
      shift 2 ;;
    *) die 1 "unknown argument: $1 (see --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate target
# ---------------------------------------------------------------------------
[ -d "$repo_arg" ] || die 2 "no such directory: $repo_arg"
repo="$(cd "$repo_arg" && pwd)"
[ -f "$repo/Cargo.toml" ] || die 2 "no Cargo.toml at $repo — expected a Rust crate or workspace root"
command -v python3 >/dev/null 2>&1 || die 1 "python3 not found"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die 4 "not a git repo: $repo"

# ---------------------------------------------------------------------------
# Introspect the crate (name, version, target_kind, workspace members) via
# tomllib — one python3 call, JSON out, sourced into shell variables.
# ---------------------------------------------------------------------------
introspect_json="$(python3 - "$repo" <<'PY'
import json, sys, tomllib, os

repo = sys.argv[1]
with open(os.path.join(repo, "Cargo.toml"), "rb") as fh:
    doc = tomllib.load(fh)

pkg = doc.get("package", {})
name = pkg.get("name")
version = pkg.get("version")
if isinstance(version, dict):  # version.workspace = true
    version = None

members = []
ws = doc.get("workspace")
if isinstance(ws, dict):
    for m in ws.get("members", []) or []:
        if any(ch in m for ch in "*?["):
            import glob
            for hit in glob.glob(os.path.join(repo, m)):
                rel = os.path.relpath(hit, repo)
                if os.path.isfile(os.path.join(hit, "Cargo.toml")) and rel != ".":
                    members.append(rel)
        else:
            rel = m
            if os.path.isfile(os.path.join(repo, rel, "Cargo.toml")) and rel != ".":
                members.append(rel)

# If root has no [package] (virtual workspace), fall back to dir basename
# for the intent_slug / display name, and pull version from the newest
# member (best-effort; onboarding doesn't require a perfectly resolved
# version, only *a* real one to tag from).
if not name:
    name = os.path.basename(repo.rstrip("/"))
if not version:
    for m in members:
        try:
            with open(os.path.join(repo, m, "Cargo.toml"), "rb") as fh:
                mdoc = tomllib.load(fh)
            v = mdoc.get("package", {}).get("version")
            if isinstance(v, str):
                version = v
                break
        except OSError:
            continue
if not version:
    version = "0.1.0"  # honest fallback: no version anywhere to source from

has_bin = bool(doc.get("bin")) or os.path.isfile(os.path.join(repo, "src", "main.rs"))
has_lib = bool(doc.get("lib")) or os.path.isfile(os.path.join(repo, "src", "lib.rs"))
target_kind = "cli" if has_bin else ("lib" if has_lib else "cli")

edition = pkg.get("edition")
if edition not in ("2021", "2024"):
    edition = "2021"

print(json.dumps({
    "name": name,
    "version": version,
    "target_kind": target_kind,
    "edition": edition,
    "members": members,
    "has_tests_dir": os.path.isdir(os.path.join(repo, "tests")),
    "has_workflows": os.path.isdir(os.path.join(repo, ".github", "workflows")),
}))
PY
)" || die 1 "failed to introspect $repo/Cargo.toml"

crate_name="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['name'])" "$introspect_json")"
crate_version="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['version'])" "$introspect_json")"

# ---------------------------------------------------------------------------
# Locate the newest built/archived PRD naming this repo as its build_into,
# scanning built-prds/ frontmatter directly (mirrors the shape
# intent-card-refresh.sh's --check reads out of manifest.json, but reads
# the PRDs themselves so this script has no manifest.json dependency).
# Prints the resolved path (or empty) on stdout.
# ---------------------------------------------------------------------------
locate_prd() {
  python3 - "$repo" "$PRD_DIR" <<'PY'
import os, re, sys

repo = os.path.abspath(sys.argv[1])
prd_dir = sys.argv[2]
built = os.path.join(prd_dir, "built-prds")

BUILD_INTO_RE = re.compile(r"^\s*[-*+]?\s*build_into\s*:\s*(.+?)\s*$", re.I)
BUILT_RE = re.compile(r"^\s*[-*+]?\s*Built\s*:\s*(.+?)\s*$", re.I)

best_path = None
best_key = ("", 0.0)  # (Built date string, mtime) — lexical ISO dates sort correctly
if os.path.isdir(built):
    for fname in os.listdir(built):
        if not (fname.startswith("PRD-") and fname.endswith(".md")):
            continue
        fpath = os.path.join(built, fname)
        build_into = None
        built_date = ""
        try:
            with open(fpath, encoding="utf-8", errors="replace") as fh:
                for i, line in enumerate(fh):
                    if i > 60:
                        break
                    m = BUILD_INTO_RE.match(line)
                    if m:
                        build_into = m.group(1).strip().strip('"')
                    m2 = BUILT_RE.match(line)
                    if m2:
                        built_date = m2.group(1).strip()
        except OSError:
            continue
        if not build_into:
            continue
        if os.path.abspath(os.path.expanduser(build_into)) != repo:
            continue
        mtime = os.path.getmtime(fpath)
        key = (built_date, mtime)
        if key > best_key:
            best_key = key
            best_path = fpath

print(best_path or "")
PY
}

# ---------------------------------------------------------------------------
# Plan: for each agent/ file, decide create|keep. Tag: create|keep.
# ---------------------------------------------------------------------------
agent_dir="$repo/agent"
declare -A plan
for f in "${AGENT_FILES[@]}"; do
  if [ -f "$agent_dir/$f" ]; then
    plan["$f"]="kept"
  else
    plan["$f"]="create"
  fi
done

existing_tags="$(git -C "$repo" tag -l 'v*')"
if [ -z "$existing_tags" ]; then
  tag_action="create v$crate_version"
else
  tag_action="kept (existing v* tag lineage)"
fi

prd_path="$(locate_prd)"
if [ -n "$prd_path" ]; then
  intent_source_desc="intent-card-refresh.sh from $prd_path"
else
  intent_source_desc="minimal onboarded-without-prd card (no built/archived PRD names this repo)"
fi

# ---------------------------------------------------------------------------
# --check: print the plan, write nothing.
# ---------------------------------------------------------------------------
if $check_mode; then
  echo "onboard-repo --check: $repo (crate=$crate_name version=$crate_version)"
  for f in "${AGENT_FILES[@]}"; do
    if [ "$f" = "intent-card.json" ] && [ "${plan[$f]}" = "create" ]; then
      echo "  agent/$f: create ($intent_source_desc)"
    else
      echo "  agent/$f: ${plan[$f]}"
    fi
  done
  echo "  tag: $tag_action"
  echo "  rollback_model (if AUTOBUILDER_PROGRAM.md is created): $rollback_model"
  exit 0
fi

# ---------------------------------------------------------------------------
# Refuse a dirty tree before writing anything (extend-gate.sh convention).
# ---------------------------------------------------------------------------
if [ -n "$(git -C "$repo" status --porcelain)" ]; then
  die 3 "refusing — working tree at $repo is dirty"
fi

mkdir -p "$agent_dir"

created=()
kept=()

# --- intent-card.json ------------------------------------------------------
if [ "${plan[intent-card.json]}" = "kept" ]; then
  kept+=("intent-card.json")
else
  if [ -n "$prd_path" ]; then
    "$HERE/intent-card-refresh.sh" "$repo" "$prd_path" \
      || die 1 "intent-card-refresh.sh failed to generate agent/intent-card.json from $prd_path"
  else
    python3 - "$repo" "$crate_name" <<'PY'
import json, os, re, sys, datetime

repo, crate_name = sys.argv[1], sys.argv[2]
slug = re.sub(r"[^a-z0-9-]", "-", crate_name.lower()).strip("-")[:63] or "onboarded-crate"
if not re.match(r"^[a-z0-9]", slug):
    slug = "x" + slug
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

card = {
    "schema": "autobuilder.intent_card.v1",
    "prd_source": "onboarded-without-prd",
    "intent_slug": slug,
    "root_motivation": (
        f"No built or archived PRD names {crate_name} as its build_into when "
        "onboard-repo.sh ran (PRD-build-repo-onboard); this crate has real, "
        "tested, pushed code that predates the autobuilder gate. agent/ "
        "scaffolding was generated by introspecting the crate's existing "
        "Cargo.toml, tests/, README.md, and CHANGELOG.md so it can enter "
        "the gate. See agent/AUTOBUILDER_PROGRAM.md for onboarding "
        "provenance; this card is superseded automatically the next time "
        "a PRD naming this repo ships and intent-card-refresh.sh runs."
    ),
    "user_persona": (
        "UNSPECIFIED — onboarded without a PRD or a 5-Whys interview; set "
        "by hand or by the next PRD that lands on this crate."
    ),
    "unfakeable_metric": {
        "name": "acceptance_tests_passing_count",
        "lower_is_better": False,
        "harness_command": "scripts/run-metrics.sh",
        "target": None,
    },
    "acceptance_criteria": [
        {
            "id": "AC1",
            "level": "MAY",
            "description": (
                "Placeholder: no PRD authored this onboarding, so no real "
                "acceptance criterion exists yet for this card. This entry "
                "exists only to satisfy the intent-card schema's non-empty "
                "acceptance_criteria requirement and asserts nothing about "
                "the crate's behavior."
            ),
            "test": "N/A — no PRD-sourced test",
        }
    ],
    "scope": [],
    "non_goals": [],
    "hard_constraints": {
        "rust_edition": "2024",
        "target_kind": "cli",
        "deny_unsafe": True,
    },
    "five_whys_trace": [
        {
            "why": 1,
            "q": "Card auto-generated by onboard-repo.sh — was a 5-Whys interview conducted for it?",
            "a": (
                "No. This card was mechanically generated from repo "
                "introspection by scripts/onboard-repo.sh because no PRD "
                "names this crate as built/archived yet. No five-whys "
                "interview ran."
            ),
        }
    ],
    "created_at": now,
    "carried_forward": {k: False for k in (
        "user_persona", "unfakeable_metric", "scope", "non_goals",
        "hard_constraints", "five_whys_trace", "created_at",
    )},
}

os.makedirs(os.path.join(repo, "agent"), exist_ok=True)
dest = os.path.join(repo, "agent", "intent-card.json")
tmp = dest + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(card, indent=2) + "\n")
os.replace(tmp, dest)
PY
  fi
  created+=("intent-card.json")
fi

# --- proof-lanes.toml, owner-map.json, test-map.json, AUTOBUILDER_PROGRAM.md
python3 - "$repo" "$crate_name" "$crate_version" "$rollback_model" "$introspect_json" \
  "${plan[proof-lanes.toml]}" "${plan[owner-map.json]}" "${plan[test-map.json]}" \
  "${plan[AUTOBUILDER_PROGRAM.md]}" <<'PY'
import json, os, re, sys

(repo, crate_name, crate_version, rollback_model, introspect_json,
 plan_lanes, plan_owner, plan_testmap, plan_program) = sys.argv[1:10]

meta = json.loads(introspect_json)
members = meta["members"]
has_tests_dir = meta["has_tests_dir"]
has_workflows = meta["has_workflows"]

agent_dir = os.path.join(repo, "agent")
os.makedirs(agent_dir, exist_ok=True)


def atomic_write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


created = []

# --- proof-lanes.toml ------------------------------------------------------
if plan_lanes == "create":
    src_globs = ["src/**/*.rs"] + [f"{m}/src/**/*.rs" for m in members]
    dep_globs = ["Cargo.toml", "Cargo.lock"] + [f"{m}/Cargo.toml" for m in members]
    src_globs_str = ", ".join(f'"{g}"' for g in src_globs)
    dep_globs_str = ", ".join(f'"{g}"' for g in dep_globs)

    lanes = []
    lanes.append(f'''[[lane]]
id = "rust-source"
description = "Behavior changes in src/ (generated by onboard-repo.sh from the repo's actual layout)"
globs = [{src_globs_str}]
required_commands = [
  "cargo check --workspace",
  "cargo clippy --workspace -- -D warnings",
  "cargo test --workspace",
]
''')
    if has_tests_dir:
        test_globs = ["tests/**/*.rs"] + [f"{m}/tests/**/*.rs" for m in members]
        test_globs_str = ", ".join(f'"{g}"' for g in test_globs)
        lanes.append(f'''[[lane]]
id = "rust-tests"
description = "Test-only changes"
globs = [{test_globs_str}]
required_commands = [
  "cargo test --workspace",
]
''')
    lanes.append(f'''[[lane]]
id = "deps"
description = "Cargo.toml / Cargo.lock changes"
globs = [{dep_globs_str}]
required_commands = [
  "cargo check --workspace",
]
''')
    if has_workflows:
        lanes.append('''[[lane]]
id = "ci"
description = "GitHub Actions workflow changes"
globs = [".github/workflows/**"]
required_commands = [
  "cargo check --workspace",
]
''')
    lanes.append('''[[lane]]
id = "meta"
description = "Orchestrator-owned scaffold metadata (agent/** and repo hygiene). Not edit-agent-owned; no build proof applies, only intent-card schema validation."
globs = ["agent/**", ".gitignore", "CHANGELOG.md", "README.md", "LICENSE-*", "extended-gates.toml", "PRD-*.md"]
required_commands = [
  "autobuilder intake --validate agent/intent-card.json",
]
''')
    header = (
        "# proof-lanes.toml — change-class -> required-lane routing.\n"
        "# Generated by scripts/onboard-repo.sh (PRD-build-repo-onboard) from this\n"
        f"# repo's actual layout at onboarding time ({crate_name} v{crate_version}).\n"
        "# Shape mirrors mcphost's working agent/proof-lanes.toml (the reference\n"
        "# scaffolding this fleet's gate assumes). Each lane has globs; a Stage-3\n"
        "# advance requires every changed path to resolve to >=1 lane AND that\n"
        "# lane's required_commands to be green.\n\n"
    )
    atomic_write(os.path.join(agent_dir, "proof-lanes.toml"), header + "\n".join(lanes))
    created.append("proof-lanes.toml")

# --- owner-map.json ----------------------------------------------------------
if plan_owner == "create":
    routes = [{"glob": "src/**", "owner": "edit-agent"}]
    for m in members:
        routes.append({"glob": f"{m}/src/**", "owner": "edit-agent"})
    if has_tests_dir:
        routes.append({"glob": "tests/**", "owner": "edit-agent"})
    routes.append({"glob": "agent/**", "owner": "orchestrator"})
    routes.append({"glob": "Cargo.toml", "owner": "edit-agent (dependency additions only)"})
    routes.append({"glob": "Cargo.lock", "owner": "edit-agent (deps-only iterations)"})
    owner_map = {
        "schema": "autobuilder.owner_map.v1",
        "default_owner": "autobuilder",
        "routes": routes,
    }
    atomic_write(os.path.join(agent_dir, "owner-map.json"), json.dumps(owner_map, indent=2) + "\n")
    created.append("owner-map.json")

# --- test-map.json -----------------------------------------------------------
if plan_testmap == "create":
    ac_test_map = {}
    # Matches the fleet's real AC-numbering conventions regardless of
    # prefix: bare (ac1_foo.rs), zero-padded (ac01_foo.rs), prefixed
    # (placement_ac1_foo.rs, apply_ac1_dryrun.rs), and the acceptance_ac<N>
    # convention with no trailing underscore (acceptance_ac1.rs). Searched
    # anywhere in the filename (not anchored), since the /build fleet has
    # no single fixed prefix convention across crates.
    ac_re = re.compile(r"ac0*([0-9]+)(?=[_.])", re.IGNORECASE)
    if has_tests_dir:
        tests_dir = os.path.join(repo, "tests")
        for fname in sorted(os.listdir(tests_dir)):
            if not fname.endswith((".rs", ".py")):
                continue
            m = ac_re.search(fname)
            if m:
                ac_id = f"AC{int(m.group(1))}"
                ac_test_map.setdefault(ac_id, f"tests/{fname}")
    routes = [
        {"glob": "src/**", "required_proof": ["cargo test --workspace"]},
        {"glob": "Cargo.toml", "required_proof": ["cargo check --workspace"]},
    ]
    test_map = {
        "schema": "autobuilder.test_map.v1",
        "note": (
            "Generated by onboard-repo.sh from tests/ filenames matching "
            "ac<N>_*.rs / ac0N_*.rs (the ac-judge 0.2.1 naming convention). "
            "Empty ac_test_map means no such files were found at onboarding "
            "time, not that the crate has no tests."
        ),
        "routes": routes,
        "ac_test_map": ac_test_map,
    }
    atomic_write(os.path.join(agent_dir, "test-map.json"), json.dumps(test_map, indent=2) + "\n")
    created.append("test-map.json")

# --- AUTOBUILDER_PROGRAM.md ---------------------------------------------------
if plan_program == "create":
    build_cmds = "\n".join([
        "- `cargo check --workspace`",
        "- `cargo test --workspace`",
        "- `cargo clippy --workspace -- -D warnings`",
    ])
    body = f"""# {crate_name} — autobuilder program (onboarded)

Generated by `scripts/onboard-repo.sh` (PRD-build-repo-onboard) — **not**
autobuilder Stage 2 scaffold. This crate was not built by the
autobuilder scaffold/iterate loop from scratch; it already had real,
tested, pushed code, and this file plus the rest of `agent/` were added
after the fact so the crate can be evaluated by the fleet's 25-receipt
autobuilder gate (`extend-gate.sh`). Treat "Hard gates" below as the
gate's actual requirements, not as a claim that this repo was iterated
under them from day one.

## Repo

- Crate: `{crate_name}`
- Cargo.toml version at onboarding: `{crate_version}`

## PRD workspace

PRDs for this fleet live at `~/Documents/PRDs` (`build-queue/` = queued,
`built-prds/` = shipped, `parked/` = parked) — not in this repo's own
root. The `ac-traceability` producer, however, only reads a literal
`PRD-*.md` file at this repo's root (or `extended-gates.toml`'s
`prd_path`, relative to this repo). If `ac-traceability` blocks for lack
of a PRD, copy or symlink the specific PRD in scope from
`~/Documents/PRDs` into this repo's root as `PRD-<slug>.md`, or add an
`extended-gates.toml` with `prd_path = "..."` — onboarding does not do
this automatically since which PRD is "in scope" is a per-repo judgment
call, not something introspection can decide.

## Build commands (from Cargo.toml)

{build_cmds}

## rollback_model

rollback_model: {rollback_model}
"""
    atomic_write(os.path.join(agent_dir, "AUTOBUILDER_PROGRAM.md"), body)
    created.append("AUTOBUILDER_PROGRAM.md")

# created/kept summary is derived shell-side from $plan (computed before any
# write ran); this python block's own `created` list has done its job
# purely by writing the files, no stdout needed.
PY

# The python block above performed the actual writes; its own "created"
# list is authoritative but we already know create/keep per file from
# $plan (computed before any write), so just fold that into the shell-side
# summary rather than round-tripping python's stdout a second time.
for f in proof-lanes.toml owner-map.json test-map.json AUTOBUILDER_PROGRAM.md; do
  if [ "${plan[$f]}" = "create" ]; then
    created+=("$f")
  else
    kept+=("$f")
  fi
done

# --- tag ---------------------------------------------------------------------
tag_created=false
if [ -z "$existing_tags" ]; then
  head_sha="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" tag -a "v$crate_version" -m "onboard-repo.sh: initial version tag for autobuilder rollback-plan (PRD-build-repo-onboard)" "$head_sha" \
    || die 1 "failed to create tag v$crate_version at $head_sha"
  tag_created=true
fi

# ---------------------------------------------------------------------------
# Summary — what should now be unblocked vs. what still needs real content.
# ---------------------------------------------------------------------------
echo "onboard-repo: $repo (crate=$crate_name version=$crate_version)"
if [ "${#created[@]}" -gt 0 ]; then
  echo "  created: ${created[*]}"
else
  echo "  created: (none)"
fi
if [ "${#kept[@]}" -gt 0 ]; then
  echo "  kept (already present, untouched): ${kept[*]}"
fi
if $tag_created; then
  echo "  tag: created v$crate_version (annotated) at $(git -C "$repo" rev-parse HEAD)"
else
  echo "  tag: kept (existing v* tag lineage: $existing_tags)"
fi
echo
echo "  should now be unblocked (scaffolding-dependent receipts): intake, vti-plan, rollback-plan (has a real tag base), reviewer-agent, ci-checks, session-trace, proof-lane routing"
echo "  still needs real per-repo content this script cannot fabricate:"
echo "    - ac-traceability: needs an actual PRD-*.md at $repo's root (or extended-gates.toml prd_path) — see agent/AUTOBUILDER_PROGRAM.md's 'PRD workspace' section"
if [ -z "$prd_path" ]; then
  echo "    - intent-card.json was generated onboarded-without-prd (no built/archived PRD names this repo) — a real 5-Whys card should replace it once one does"
fi
echo "    - any reviewer-agent or risk-gate block that describes something true about the code is unaffected by onboarding and stays real"

exit 0
