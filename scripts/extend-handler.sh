#!/usr/bin/env bash
# extend-handler.sh — mechanical helpers for the rust-extend build path.
#
# The model orchestrates the extend tick (deciding which sub-action this
# tick performs, invoking /rustbuild, verifying ACs). This script
# provides the deterministic, non-judgment-call pieces: parse PRD,
# validate target, read/bump Cargo.toml version, prepend CHANGELOG,
# install built binary.
#
# Subcommands:
#   validate <slug>                  — exit 0 if the PRD has a usable
#                                      build_into rust repo; print JSON
#                                      { slug, build_into, version,
#                                        bump, bin_name|null } to stdout.
#   current-version <build_into>     — print the Cargo.toml [package].version
#                                      of that repo to stdout. Exit 1 if missing.
#   bump-version <build_into> <bump> — rewrite Cargo.toml version per
#                                      patch|minor|major. Print "<old> <new>".
#                                      No git ops.
#   install <build_into>             — `cargo build --release` then install
#                                      every [[bin]] target into ~/.local/bin.
#                                      Print the installed paths.
#   changelog-prepend <build_into> <version> <tldr_file>
#                                    — prepend a `## v<version>` section to
#                                      CHANGELOG.md with the TL;DR content.
#                                      Creates CHANGELOG.md if missing.
#
# Identity for any git commit is the model's job (use
#   git -c user.email=jyen.tech@gmail.com -c user.name="Joe Yen" commit ...
# ); this script never commits.
#
# Exit codes: 0 ok, 1 misuse, 2 PRD/repo not in expected shape.

set -uo pipefail

JQ="${JQ:-/usr/sbin/jq}"
PRD_DIR="${PRD_DIR:-$HOME/Documents/PRDs}"
SCAN="${SCAN:-$(dirname "$0")/scan-prds.sh}"

die() { printf 'extend-handler: %s\n' "$*" >&2; exit "${2:-1}"; }

require_jq() { [ -x "$JQ" ] || die "jq not at $JQ" 1; }

read_prd_json() {
  local slug="$1"
  require_jq
  bash "$SCAN" | "$JQ" -e --arg s "$slug" '.[] | select(.slug == $s)' \
    || die "PRD '$slug' not found by scanner" 2
}

read_cargo_version() {
  local cargo="$1/Cargo.toml"
  [ -f "$cargo" ] || die "no Cargo.toml at $cargo" 2
  awk -F'=' '
    $1 ~ /^[[:space:]]*\[/ { in_pkg = ($1 ~ /\[package\]/) ? 1 : 0; next }
    in_pkg && $1 ~ /^[[:space:]]*version[[:space:]]*$/ {
      v = $2; gsub(/[[:space:]"]/, "", v); print v; exit
    }
  ' "$cargo"
}

cmd_validate() {
  [ -n "${1:-}" ] || die "usage: validate <slug>" 1
  local slug="$1" json build_into bump
  json="$(read_prd_json "$slug")"
  build_into="$(printf '%s' "$json" | "$JQ" -r '.build_into // ""')"
  bump="$(printf '%s' "$json" | "$JQ" -r '.build_version_bump // "minor"')"
  [ -n "$build_into" ] || die "PRD '$slug' has no build_into" 2
  [ -d "$build_into" ] || die "build_into '$build_into' is not a directory" 2
  [ -f "$build_into/Cargo.toml" ] || die "no Cargo.toml in '$build_into'" 2
  local version bin_name
  version="$(read_cargo_version "$build_into")"
  [ -n "$version" ] || die "could not read version from $build_into/Cargo.toml" 2
  bin_name="$(awk '
    /^[[:space:]]*\[\[bin\]\]/ { in_bin = 1; next }
    /^[[:space:]]*\[/ { in_bin = 0 }
    in_bin && /^[[:space:]]*name[[:space:]]*=/ {
      v = $0; sub(/^[^=]*=/, "", v); gsub(/[[:space:]"]/, "", v); print v; exit
    }
  ' "$build_into/Cargo.toml")"
  "$JQ" -cn \
    --arg slug "$slug" \
    --arg build_into "$build_into" \
    --arg version "$version" \
    --arg bump "$bump" \
    --arg bin_name "$bin_name" \
    '{slug:$slug, build_into:$build_into, version:$version, bump:$bump,
      bin_name: (if $bin_name == "" then null else $bin_name end)}'
}

cmd_current_version() {
  [ -n "${1:-}" ] || die "usage: current-version <build_into>" 1
  read_cargo_version "$1" || die "could not read version" 2
}

cmd_bump_version() {
  local target="${1:-}" kind="${2:-minor}"
  [ -n "$target" ] || die "usage: bump-version <build_into> <patch|minor|major>" 1
  local cargo="$target/Cargo.toml"
  local old new maj mi pa
  old="$(read_cargo_version "$target")" || die "version read failed" 2
  IFS='.' read -r maj mi pa <<<"$old"
  case "$kind" in
    patch) pa=$((pa+1)) ;;
    minor) mi=$((mi+1)); pa=0 ;;
    major) maj=$((maj+1)); mi=0; pa=0 ;;
    *) die "unknown bump kind: $kind (want patch|minor|major)" 1 ;;
  esac
  new="${maj}.${mi}.${pa}"
  # Replace ONLY the first [package].version line. awk to be safe.
  awk -v old="$old" -v new="$new" '
    BEGIN { in_pkg = 0; done = 0 }
    /^\[/ { in_pkg = ($0 ~ /^\[package\]/) ? 1 : 0 }
    in_pkg && !done && $0 ~ /^[[:space:]]*version[[:space:]]*=/ {
      sub("\"" old "\"", "\"" new "\""); done = 1
    }
    { print }
  ' "$cargo" > "$cargo.new" && mv "$cargo.new" "$cargo"
  printf '%s %s\n' "$old" "$new"
}

cmd_install() {
  local target="${1:-}"
  [ -n "$target" ] || die "usage: install <build_into>" 1
  [ -f "$target/Cargo.toml" ] || die "no Cargo.toml in $target" 2
  ( cd "$target" && cargo build --release ) || die "cargo build failed" 2

  # Helper: install one binary, routing through rollout install when the dest
  # backs a live systemd-user unit (PRD-vigil-build-restart-wiring).
  # Appends the chosen install path ("rollout-install" or "install-m755" or
  # "install-m755-fallback") to /tmp/extend-install-verdict.<$$> for the
  # caller's log.  Returns 0 on success, non-zero on install failure.
  local _verdict_file="/tmp/extend-install-verdict.$$"
  _install_one_bin() {
    local src="$1" dest="$2"
    local _unit_helper
    _unit_helper="$(dirname "${BASH_SOURCE[0]}")/unit-for-dest.sh"
    local _backing_unit=""
    if [ -x "$_unit_helper" ]; then
      _backing_unit="$(bash "$_unit_helper" "$dest" 2>/dev/null || true)"
    fi
    if [ -n "$_backing_unit" ]; then
      # This dest backs a daemon unit.
      if command -v rollout &>/dev/null; then
        # Use rollout install for safe install+restart.
        rollout install "$src" --dest "$dest" \
          || die "rollout install of $dest failed" 2
        printf 'rollout-install  %s  unit=%s\n' "$dest" "$_backing_unit" \
          >> "$_verdict_file"
      else
        # rollout not yet available — fall back gracefully.
        printf 'extend-handler: WARNING: rollout not installed; ' >&2
        printf 'falling back to install -m755 for %s (unit %s not restarted)\n' \
          "$dest" "$_backing_unit" >&2
        install -Dm755 "$src" "$dest" || die "install of $dest failed" 2
        printf 'install-m755-fallback  %s  unit=%s  pending=daemon-installed-but-not-restarted\n' \
          "$dest" "$_backing_unit" >> "$_verdict_file"
        # Append a Pending note to gossip so self-review sees it.
        local _gossip="$HOME/wintermute/rustbuild/notes/gossip.md"
        if [ -d "$(dirname "$_gossip")" ]; then
          printf '\n- [%s] Pending: daemon `%s` installed binary `%s` but NOT restarted — `rollout install` unavailable (install-m755-fallback)\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_backing_unit" "$dest" \
            >> "$_gossip"
        fi
      fi
    else
      # No backing unit — plain install, no change to existing behaviour.
      install -Dm755 "$src" "$dest" || die "install of $dest failed" 2
      printf 'install-m755  %s  unit=none\n' "$dest" >> "$_verdict_file"
    fi
  }

  local installed=()
  while IFS= read -r bin; do
    [ -n "$bin" ] || continue
    local _dest="$HOME/.local/bin/$bin"
    _install_one_bin "$target/target/release/$bin" "$_dest"
    installed+=("$_dest")
  done < <(awk '
    /^[[:space:]]*\[\[bin\]\]/ { in_bin = 1; next }
    /^[[:space:]]*\[/ { in_bin = 0 }
    in_bin && /^[[:space:]]*name[[:space:]]*=/ {
      v = $0; sub(/^[^=]*=/, "", v); gsub(/[[:space:]"]/, "", v); print v
    }
  ' "$target/Cargo.toml")
  if [ ${#installed[@]} -eq 0 ]; then
    # Library-only crate. Try the package name as a fallback (single-bin convention).
    local pkg
    pkg="$(awk '
      /^[[:space:]]*\[/ { in_pkg = ($0 ~ /^[[:space:]]*\[package\]/) ? 1 : 0 }
      in_pkg && /^[[:space:]]*name[[:space:]]*=/ {
        v = $0; sub(/^[^=]*=/, "", v); gsub(/[[:space:]"]/, "", v); print v; exit
      }
    ' "$target/Cargo.toml")"
    if [ -n "$pkg" ] && [ -f "$target/target/release/$pkg" ]; then
      local _dest="$HOME/.local/bin/$pkg"
      _install_one_bin "$target/target/release/$pkg" "$_dest"
      installed+=("$_dest")
    fi
  fi
  # Print verdicts (install path taken) then installed paths, for caller's log.
  if [ -f "$_verdict_file" ]; then
    printf '[install-verdict] ' >&2
    cat "$_verdict_file" >&2
    rm -f "$_verdict_file"
  fi
  printf '%s\n' "${installed[@]}"
}

cmd_changelog_prepend() {
  local target="${1:-}" version="${2:-}" tldr_file="${3:-}"
  [ -n "$target" ] && [ -n "$version" ] && [ -n "$tldr_file" ] \
    || die "usage: changelog-prepend <build_into> <version> <tldr_file>" 1
  [ -f "$tldr_file" ] || die "tldr file not found: $tldr_file" 2
  local clog="$target/CHANGELOG.md"
  local date_today tldr_body
  date_today="$(date -u +%Y-%m-%d)"
  tldr_body="$(cat "$tldr_file")"
  # Fix per PRD-build-changelog-prepend-fix: previous impl used $() to
  # assemble the new section, which strips trailing newlines and mashes
  # the new section into the existing # Changelog header. awk preserves
  # an existing top-level header at line 1 and slots the new section
  # immediately under it.
  if [ -f "$clog" ]; then
    awk -v ver="$version" -v dt="$date_today" -v body="$tldr_body" '
      BEGIN { stripped_header = 0; printed_new = 0 }
      NR == 1 && /^#[[:space:]]+([Cc]hangelog|CHANGELOG)[[:space:]]*$/ {
        print
        stripped_header = 1
        next
      }
      NR == 2 && stripped_header && /^[[:space:]]*$/ { print; next }
      !printed_new {
        if (!stripped_header) {
          print "# Changelog"
          print ""
        }
        print "## v" ver " — " dt
        print ""
        print body
        print ""
        printed_new = 1
      }
      { print }
    ' "$clog" > "$clog.new" && mv "$clog.new" "$clog"
  else
    {
      printf '# Changelog\n\n## v%s — %s\n\n%s\n' "$version" "$date_today" "$tldr_body"
    } > "$clog"
  fi
  printf '%s\n' "$clog"
}

case "${1:-}" in
  validate)          shift; cmd_validate "$@" ;;
  current-version)   shift; cmd_current_version "$@" ;;
  bump-version)      shift; cmd_bump_version "$@" ;;
  install)           shift; cmd_install "$@" ;;
  changelog-prepend) shift; cmd_changelog_prepend "$@" ;;
  ""|-h|--help)
    cat <<'EOF'
extend-handler.sh — rust-extend mechanical helpers
  validate <slug>
  current-version <build_into>
  bump-version <build_into> <patch|minor|major>
  install <build_into>
  changelog-prepend <build_into> <version> <tldr_file>
EOF
    ;;
  *) die "unknown subcommand: $1 (try --help)" 1 ;;
esac
