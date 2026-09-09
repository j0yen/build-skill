#!/usr/bin/env bash
# install-hcloud-selftest.sh — offline proof for install-hcloud.sh
# (requirement 2, PRD-build-burst-lane-ccx53) using a fake curl and a
# throwaway tarball/hash pair, no real GitHub download. The real download +
# real sha256 verify + real reinstall + real gate-burst.sh precondition path
# was additionally exercised live against the real hcloud release and the
# real Hetzner API while this script was written (see the PRD's own field
# notes) — this selftest covers what a live run can't safely re-check every
# time (a deliberately WRONG checksum must be refused, and refusal must
# leave any existing install untouched).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$HERE/install-hcloud.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fails=0
expect() {  # $1=label $2=condition (eval'd)
  if eval "$2"; then echo "ok  $1"; else echo "FAIL $1"; fails=$((fails+1)); fi
}

# ---- build a throwaway "release" tarball + its real sha256s ---------------
mkdir -p "$T/fakebin-content"
printf '#!/bin/sh\necho "fake-hcloud v9.9.9"\n' > "$T/fakebin-content/hcloud"
chmod +x "$T/fakebin-content/hcloud"
BIN_SHA="$(sha256sum "$T/fakebin-content/hcloud" | awk '{print $1}')"
( cd "$T/fakebin-content" && tar -czf "$T/hcloud-linux-amd64.tar.gz" hcloud )
TARBALL_SHA="$(sha256sum "$T/hcloud-linux-amd64.tar.gz" | awk '{print $1}')"

# ---- fake curl: `curl ... -o <dest> <url>` just copies our tarball --------
cat > "$T/curl" <<EOF
#!/usr/bin/env bash
dest=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-o" ]; then dest="\$a"; fi
  prev="\$a"
done
[ -n "\$dest" ] || { echo "fake curl: no -o dest" >&2; exit 2; }
cp "$T/hcloud-linux-amd64.tar.gz" "\$dest"
EOF
chmod +x "$T/curl"

export HCLOUD_INSTALL_DIR="$T/install"
export HCLOUD_CURL_BIN="$T/curl"
export HCLOUD_VERSION="9.9.9"
export HCLOUD_TARBALL_SHA256="$TARBALL_SHA"
export HCLOUD_BIN_SHA256="$BIN_SHA"
mkdir -p "$HCLOUD_INSTALL_DIR"

echo "-- fresh install (no existing binary): downloads, verifies, installs --"
out="$(bash "$INSTALL_SH" 2>&1)"; rc=$?
expect "fresh install exits 0" "[ $rc -eq 0 ]"
expect "fresh install reports 'installed:'" "grep -q '^installed:' <<<\"\$out\""
expect "binary landed at the install path" "[ -x \"\$HCLOUD_INSTALL_DIR/hcloud\" ]"
expect "installed binary matches the pinned sha256" \
  "[ \"\$(sha256sum \"\$HCLOUD_INSTALL_DIR/hcloud\" | awk '{print \$1}')\" = \"\$BIN_SHA\" ]"

echo "-- second run, no --force: skips (idempotent), no curl re-invoked --"
: > "$T/curl.calls"
cat > "$T/curl-tracking" <<EOF
#!/usr/bin/env bash
echo called >> "$T/curl.calls"
exec "$T/curl" "\$@"
EOF
chmod +x "$T/curl-tracking"
out="$(HCLOUD_CURL_BIN="$T/curl-tracking" bash "$INSTALL_SH" 2>&1)"; rc=$?
expect "idempotent re-run exits 0" "[ $rc -eq 0 ]"
expect "idempotent re-run reports 'already-installed:'" "grep -q '^already-installed:' <<<\"\$out\""
expect "idempotent re-run never re-invoked curl" "[ ! -s \"$T/curl.calls\" ]"

echo "-- --force re-installs even though the pin already matches --"
out="$(bash "$INSTALL_SH" --force 2>&1)"; rc=$?
expect "--force exits 0" "[ $rc -eq 0 ]"
expect "--force reports 'installed:'" "grep -q '^installed:' <<<\"\$out\""

echo "-- tarball sha256 mismatch: refuses, leaves the existing install untouched --"
before_sha="$(sha256sum "$HCLOUD_INSTALL_DIR/hcloud" | awk '{print $1}')"
out="$(HCLOUD_TARBALL_SHA256="0000000000000000000000000000000000000000000000000000000000000000" \
       bash "$INSTALL_SH" --force 2>&1)"; rc=$?
expect "mismatch exits nonzero" "[ $rc -ne 0 ]"
expect "mismatch names 'sha256 mismatch'" "grep -q 'sha256 mismatch' <<<\"\$out\""
after_sha="$(sha256sum "$HCLOUD_INSTALL_DIR/hcloud" | awk '{print $1}')"
expect "existing install untouched after a refused mismatch" "[ \"\$before_sha\" = \"\$after_sha\" ]"

echo "-- download failure: refuses, leaves the existing install untouched --"
cat > "$T/curl-fail" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$T/curl-fail"
out="$(HCLOUD_CURL_BIN="$T/curl-fail" bash "$INSTALL_SH" --force 2>&1)"; rc=$?
expect "download failure exits nonzero" "[ $rc -ne 0 ]"
expect "download failure names 'download failed'" "grep -q 'download failed' <<<\"\$out\""
after_sha2="$(sha256sum "$HCLOUD_INSTALL_DIR/hcloud" | awk '{print $1}')"
expect "existing install untouched after a failed download" "[ \"\$before_sha\" = \"\$after_sha2\" ]"

if [ "$fails" -eq 0 ]; then
  echo "=== PASS ==="
  exit 0
else
  echo "=== FAIL ($fails) ==="
  exit 1
fi
