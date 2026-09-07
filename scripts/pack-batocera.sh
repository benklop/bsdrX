#!/usr/bin/env bash
# pack-batocera.sh — wrap a bundled /opt/bsdrX tree as a Batocera SHARE tarball.
#
#   ./scripts/pack-batocera.sh --opt /path/to/opt/bsdrX --out dist --version 0.3.3
#   ./scripts/pack-batocera.sh --deb dist/bsdr-agent_0.3.3_amd64.deb --out dist
#
# Emits dist/bsdr-agent_<ver>_batocera.tar.gz (top dir: bsdr-agent-batocera/).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPT=""
DEB=""
OUT=""
VERSION=""

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --opt) OPT="${2:-}"; shift 2 ;;
    --deb) DEB="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "pack-batocera: unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$OPT" ] || [ -n "$DEB" ] || { echo "pack-batocera: need --opt or --deb" >&2; exit 1; }
OUT="${OUT:-$ROOT/dist}"
mkdir -p "$OUT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -n "$DEB" ]; then
  [ -f "$DEB" ] || { echo "pack-batocera: no such deb: $DEB" >&2; exit 1; }
  command -v dpkg-deb >/dev/null 2>&1 || { echo "pack-batocera: dpkg-deb required for --deb" >&2; exit 1; }
  dpkg-deb -x "$DEB" "$WORK/deb"
  OPT="$WORK/deb/opt/bsdrX"
  if [ -z "$VERSION" ]; then
    VERSION="$(echo "$(basename "$DEB")" | sed -n 's/^bsdr-agent_\([^_]*\)_amd64\.deb$/\1/p')"
  fi
fi

[ -x "$OPT/bin/bsdr_agent" ] || { echo "pack-batocera: no agent in $OPT" >&2; exit 1; }
AVDEV="$OPT/lib/libavdevice.so.60"
[ -f "$AVDEV" ] || { echo "pack-batocera: missing $AVDEV" >&2; exit 1; }
avsz=$(wc -c < "$AVDEV")
if [ "$avsz" -lt 25000 ]; then
  echo "pack-batocera: libavdevice.so.60 is ${avsz} bytes (refuse nexlab stub)" >&2
  exit 1
fi

if [ -z "$VERSION" ]; then
  VERSION="$(sed -n 's/.*BSDR_VERSION[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/include/bsdr/version.h" 2>/dev/null || true)"
  [ -n "$VERSION" ] || VERSION=0.0.0
fi
VERSION="${VERSION#v}"

STAGE="$WORK/bsdr-agent-batocera"
mkdir -p "$STAGE/opt/bsdrX" "$STAGE/userdata/system/services"
cp -a "$OPT"/. "$STAGE/opt/bsdrX/"
# Batocera iHD is built against system libva 2.23; the Debian 12 bundle ships
# libva 1.17 and cannot load it. Guest /usr/lib provides a matching trio.
find "$STAGE/opt/bsdrX/lib" -maxdepth 1 \( \
  -name 'libva.so*' -o -name 'libva-drm.so*' -o -name 'libva-x11.so*' \
\) -delete
install -m 0755 "$ROOT/packaging/batocera/install.sh" "$STAGE/install.sh"
install -m 0755 "$ROOT/packaging/batocera/userdata/system/services/bsdrx" \
  "$STAGE/userdata/system/services/bsdrx"
install -m 0644 "$ROOT/packaging/batocera/README.md" "$STAGE/README.md"

TAR="$OUT/bsdr-agent_${VERSION}_batocera.tar.gz"
tar -C "$WORK" -czf "$TAR" bsdr-agent-batocera
echo ">> batocera -> $TAR"
