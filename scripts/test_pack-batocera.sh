#!/usr/bin/env bash
# Fails if pack-batocera.sh or install.sh drop the SHARE layout / stub guard.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/opt/bsdrX/bin" "$WORK/opt/bsdrX/lib"
printf '#!/bin/sh\necho fake\n' > "$WORK/opt/bsdrX/bin/bsdr_agent"
chmod +x "$WORK/opt/bsdrX/bin/bsdr_agent"
dd if=/dev/zero of="$WORK/opt/bsdrX/lib/libavdevice.so.60" bs=1 count=32529 status=none

"$ROOT/scripts/pack-batocera.sh" --opt "$WORK/opt/bsdrX" --out "$WORK/dist" --version 0.0.0-test
TAR="$WORK/dist/bsdr-agent_0.0.0-test_batocera.tar.gz"
test -f "$TAR"

tar -tzf "$TAR" | grep -qx 'bsdr-agent-batocera/install.sh'
tar -tzf "$TAR" | grep -qx 'bsdr-agent-batocera/userdata/system/services/bsdrx'
tar -tzf "$TAR" | grep -qx 'bsdr-agent-batocera/opt/bsdrX/bin/bsdr_agent'

# stub must be refused
dd if=/dev/zero of="$WORK/opt/bsdrX/lib/libavdevice.so.60" bs=1 count=17000 status=none
if "$ROOT/scripts/pack-batocera.sh" --opt "$WORK/opt/bsdrX" --out "$WORK/dist-stub" --version stub 2>/dev/null; then
  echo "expected pack to refuse stub libavdevice" >&2
  exit 1
fi
dd if=/dev/zero of="$WORK/opt/bsdrX/lib/libavdevice.so.60" bs=1 count=32529 status=none

tar -xzf "$TAR" -C "$WORK"
SHARE="$WORK/share" START=0 "$WORK/bsdr-agent-batocera/install.sh"
test -x "$WORK/share/opt/bsdrX/bin/bsdr_agent"
test -x "$WORK/share/system/services/bsdrx"
grep -q 'use_kmsgrab=1' "$WORK/share/system/.config/bsdr_agent/settings"

echo "ok pack-batocera"
