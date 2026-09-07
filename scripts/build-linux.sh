#!/usr/bin/env bash
# build-linux.sh — inject both Bigscreen app keys into cloud.h, then build
# the Linux AppImage + .deb + Batocera tarball (docker image bsdrx-linux-deps).
#
#   ./scripts/build-linux.sh              # fetch+inject, then ./distribute.sh linux
#   ./scripts/build-linux.sh --no-cache   # force a from-scratch docker image rebuild
#   make appimage                         # same as the first form
#
# Extra args are forwarded to distribute.sh. Needs python3, 7z, curl/wget, docker.
# The Friends/client key also needs apkeep (`cargo install apkeep`).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/fetch-cloud-key.sh" --inject
"$ROOT/scripts/fetch-cloud-key.sh" --inject --client
exec "$ROOT/distribute.sh" linux "$@"
