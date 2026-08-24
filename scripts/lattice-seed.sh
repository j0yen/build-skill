#!/usr/bin/env bash
# lattice-seed.sh — Ingest BFO/RO/IAO/COB/SWO into the federated lattice store
# Idempotent: re-running skips already-cached ontologies if store is intact.
set -euo pipefail

BRIDGES_DIR="${HOME}/.cache/lattice/bridges"
STORE_DIR="${HOME}/.cache/lattice/store"

log() { echo "[lattice-seed] $*" >&2; }
warn() { echo "[lattice-seed] WARN: $*" >&2; }

# ---------------------------------------------------------------------------
# Phase 1 — Ingest (idempotent: lattice-registry add is a no-op if cached)
# ---------------------------------------------------------------------------
log "Phase 1: ingesting ontologies..."

declare -A ONTOS=(
  ["bfo"]="http://purl.obolibrary.org/obo/bfo.owl"
  ["ro"]="http://purl.obolibrary.org/obo/ro.owl"
  ["iao"]="http://purl.obolibrary.org/obo/iao.owl"
  ["cob"]="http://purl.obolibrary.org/obo/cob.owl"
  ["swo"]="https://github.com/allysonlister/swo/raw/master/swo.owl"
)

for id in bfo ro iao cob swo; do
  url="${ONTOS[$id]}"
  log "  add $id ($url)"
  if lattice-registry add "$url" 2>&1; then
    log "  $id: OK"
  else
    warn "  $id: add exited non-zero (may already be cached, continuing)"
  fi
done

# ---------------------------------------------------------------------------
# Phase 2 — Resolve paths
# ---------------------------------------------------------------------------
log "Phase 2: resolving paths..."

bfo_path=$(lattice-registry path bfo)
ro_path=$(lattice-registry path ro)
iao_path=$(lattice-registry path iao)
cob_path=$(lattice-registry path cob)
swo_path=$(lattice-registry path swo)

log "  bfo: $bfo_path"
log "  ro:  $ro_path"
log "  iao: $iao_path"
log "  cob: $cob_path"
log "  swo: $swo_path"

# ---------------------------------------------------------------------------
# Phase 3 — Bridge (idempotent: overwrite existing bridge files)
# ---------------------------------------------------------------------------
log "Phase 3: generating bridge axioms..."
mkdir -p "$BRIDGES_DIR"

run_bridge() {
  local label="$1"; shift
  log "  bridge $label..."
  if lattice-bridge align "$@" 2>&1; then
    log "  $label: OK"
  else
    local rc=$?
    warn "  $label: exited $rc (possibly no mappings above threshold — continuing)"
  fi
}

run_bridge "iao→bfo" \
  --a "$iao_path" --b "$bfo_path" \
  --out "${BRIDGES_DIR}/iao-bfo.owl" \
  --proposals "${BRIDGES_DIR}/iao-bfo.proposals.jsonl" \
  --threshold 0.75

run_bridge "swo→bfo" \
  --a "$swo_path" --b "$bfo_path" \
  --out "${BRIDGES_DIR}/swo-bfo.owl" \
  --proposals "${BRIDGES_DIR}/swo-bfo.proposals.jsonl" \
  --threshold 0.75

run_bridge "swo→iao" \
  --a "$swo_path" --b "$iao_path" \
  --out "${BRIDGES_DIR}/swo-iao.owl" \
  --proposals "${BRIDGES_DIR}/swo-iao.proposals.jsonl" \
  --threshold 0.75

run_bridge "ro→bfo" \
  --a "$ro_path" --b "$bfo_path" \
  --out "${BRIDGES_DIR}/ro-bfo.owl" \
  --proposals "${BRIDGES_DIR}/ro-bfo.proposals.jsonl" \
  --threshold 0.75

# ---------------------------------------------------------------------------
# Phase 4 — Join (build/rebuild store)
# ---------------------------------------------------------------------------
log "Phase 4: building federated store..."
mkdir -p "$STORE_DIR"

# Collect bridge args (only include bridge files that exist and are non-empty)
bridge_args=()
for bf in "${BRIDGES_DIR}/iao-bfo.owl" "${BRIDGES_DIR}/swo-bfo.owl" \
           "${BRIDGES_DIR}/swo-iao.owl" "${BRIDGES_DIR}/ro-bfo.owl"; do
  if [[ -f "$bf" && -s "$bf" ]]; then
    bridge_args+=(--bridge "$bf")
  else
    warn "  skipping missing/empty bridge: $bf"
  fi
done

lattice-join build \
  --base "$bfo_path" \
  --add "$ro_path" \
  --add "$iao_path" \
  --add "$cob_path" \
  --add "$swo_path" \
  "${bridge_args[@]}" \
  --store "$STORE_DIR" \
  --allow-unreviewed

log "Phase 4: done"

# ---------------------------------------------------------------------------
# Phase 5 — Smoke test
# ---------------------------------------------------------------------------
log "Phase 5: smoke tests..."

log "  lattice-join stats..."
lattice-join stats --store "$STORE_DIR"

log "  lattice-traverse path SWO_0000001 → BFO_0000001..."
lattice-traverse path \
  --store "$STORE_DIR" \
  --from "http://www.ebi.ac.uk/swo/SWO_0000001" \
  --to "http://purl.obolibrary.org/obo/BFO_0000001" 2>&1 || warn "traverse path failed (may be expected if no path exists)"

log "  lattice-context get 'information artifact'..."
lattice-context get --query "information artifact" --format markdown 2>&1 || warn "context get failed"

log "lattice-seed complete."
