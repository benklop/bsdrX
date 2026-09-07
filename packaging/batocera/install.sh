#!/bin/sh
# Install the bundled /opt/bsdrX tree onto Batocera SHARE.
# Overlay /opt is empty after reboot — persist under /userdata and bind-mount.
#
#   tar -xzf bsdr-agent_<ver>_batocera.tar.gz
#   cd bsdr-agent-batocera && ./install.sh
#
# Env: SHARE (default /userdata), BSDRX_OPT (default /opt/bsdrX),
#      START=0 skip batocera-services, KEEP_SETTINGS=1 never overwrite settings.
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SHARE="${SHARE:-/userdata}"
OPT="${BSDRX_OPT:-/opt/bsdrX}"
PERSIST="$SHARE/opt/bsdrX"
START="${START:-1}"
AGENT="$HERE/opt/bsdrX/bin/bsdr_agent"
AVDEV="$HERE/opt/bsdrX/lib/libavdevice.so.60"

if [ ! -x "$AGENT" ]; then
  echo "install.sh: missing $AGENT" >&2
  exit 1
fi
if [ ! -f "$AVDEV" ]; then
  echo "install.sh: missing $AVDEV" >&2
  exit 1
fi
# nexlab stub is ~17K and has no kmsgrab; refuse to install it.
avsz=$(wc -c < "$AVDEV")
if [ "$avsz" -lt 25000 ]; then
  echo "install.sh: libavdevice.so.60 is ${avsz} bytes (kmsgrab-less stub)" >&2
  exit 1
fi

mkdir -p "$PERSIST" "$SHARE/system/services" "$SHARE/system/bsdrx" \
  "$SHARE/system/.config/bsdr_agent" "$SHARE/system/logs"
cp -a "$HERE/opt/bsdrX/." "$PERSIST/"
install -m 0755 "$HERE/userdata/system/services/bsdrx" "$SHARE/system/services/bsdrx"

settings="$SHARE/system/.config/bsdr_agent/settings"
if [ ! -f "$settings" ]; then
  printf 'use_vaapi=1\nuse_kmsgrab=1\n' > "$settings"
fi

if [ "$(id -u)" = 0 ]; then
  mkdir -p "$OPT"
  if [ -f /proc/mounts ] && ! grep -q " $OPT " /proc/mounts; then
    mount --bind "$PERSIST" "$OPT" || true
  fi
fi

if [ "$START" = 1 ] && command -v batocera-services >/dev/null 2>&1; then
  batocera-services enable bsdrx
  batocera-services stop bsdrx 2>/dev/null || true
  batocera-services start bsdrx
fi

echo "bsdrX installed at $PERSIST (bind $OPT)"
echo "service: $SHARE/system/services/bsdrx"
echo "panel:   http://<host>:8088  (override via $SHARE/system/bsdrx/bsdrx.env)"
