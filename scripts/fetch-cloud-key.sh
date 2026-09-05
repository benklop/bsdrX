#!/bin/sh
# fetch-cloud-key.sh — pull Bigscreen's app keys out of the official clients.
#
# The keys are Bigscreen's property and stay blank in this repo (see the README).
# Default modes only print. --inject writes the matching #define in
# include/bsdr/cloud.h so a subsequent compile bakes the key in.
#
#   companion (default) — RDC Squirrel installer, Electron config.js
#   --client / --friends — Play Store "Bigscreen Friends" APK
#                          (com.bcrossappdev.bigscreenfriends), Hermes string table
#
# Usage:
#   scripts/fetch-cloud-key.sh                 # print companion key
#   scripts/fetch-cloud-key.sh --client        # print Friends/client key
#   scripts/fetch-cloud-key.sh --export        # export BSDR_CLOUD_API_KEY=...
#   scripts/fetch-cloud-key.sh --export --client
#   scripts/fetch-cloud-key.sh --inject        # write companion into cloud.h
#   scripts/fetch-cloud-key.sh --inject --client
#   scripts/fetch-cloud-key.sh --installer=PATH
#   scripts/fetch-cloud-key.sh --client --apk=PATH
#   eval "$(scripts/fetch-cloud-key.sh --export)"
#   eval "$(scripts/fetch-cloud-key.sh --export --client)"
#
# Needs: 7z, python3. Companion download: curl or wget.
# Friends download: apkeep (`cargo install apkeep`) unless --apk= is given.
set -eu

# Pinned to the RDC build documented in include/bsdr/cloud.h (config.js v0.950.2).
DEFAULT_URL="${BSDR_RDC_SETUP_URL:-https://rdc.bigscreencloud.com/Bigscreen-RDC-0.950.2-c1b4b4/BigscreenRemoteDesktopSetup.exe}"
FRIENDS_PKG="${BSDR_FRIENDS_PKG:-com.bcrossappdev.bigscreenfriends}"

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export_mode=0
inject=0
client_mode=0
cloud_h="${BSDR_CLOUD_H:-$ROOT/include/bsdr/cloud.h}"
installer=""
apk=""
url="$DEFAULT_URL"
self_check=0

usage() { sed -n '2,/^set -eu$/p' "$0" | sed '$d'; }

for arg in "$@"; do
    case "$arg" in
        --export) export_mode=1 ;;
        --inject) inject=1 ;;
        --inject=*) inject=1; cloud_h=${arg#--inject=} ;;
        --client|--friends) client_mode=1 ;;
        --self-check) self_check=1 ;;
        --installer=*) installer=${arg#--installer=} ;;
        --apk=*) apk=${arg#--apk=} ;;
        --url=*) url=${arg#--url=} ;;
        -h|--help) usage; exit 0 ;;
        --installer|--url|--apk)
            echo "fetch-cloud-key: use $arg=PATH" >&2; exit 2 ;;
        *) echo "fetch-cloud-key: unknown arg '$arg' (see --help)" >&2; exit 2 ;;
    esac
done

# apiServerApiKey in the official RDC config.js — 64-char alphanumeric in 0.950.2.
extract_rdc_key() {  # file -> stdout
    python3 -c '
import re, sys
data = open(sys.argv[1], "rb").read().decode("latin1")
m = re.search(r"apiServerApiKey\s*:\s*\"([A-Za-z0-9]{16,})\"", data)
if not m:
    sys.stderr.write("fetch-cloud-key: apiServerApiKey not found in %s\n" % sys.argv[1])
    sys.exit(1)
print(m.group(1))
' "$1"
}

# Hermes v96 string table: the unique 64-char alnum literal (Friends BEARER_TOKEN).
extract_friends_key() {  # index.android.bundle -> stdout
    python3 -c '
import re, struct, sys

def hermes_strings(data):
    if data[:8] != bytes.fromhex("c61fbc03c103191f"):
        raise ValueError("not a Hermes v96 bundle")
    ver = struct.unpack_from("<I", data, 8)[0]
    if ver != 96:
        raise ValueError("Hermes version %d (need 96)" % ver)
    (func_count, kind_count, ident_count, string_count,
     overflow_count, storage_size) = struct.unpack_from("<IIIIII", data, 40)
    def align4(n):
        return (n + 3) & ~3
    p = 128 + func_count * 16
    p = align4(p) + kind_count * 4
    p = align4(p) + ident_count * 4
    p = align4(p)
    small = p
    p += string_count * 4
    p = align4(p)
    ovf = p
    p += overflow_count * 8
    p = align4(p)
    blob = data[p:p + storage_size]
    out = []
    for i in range(string_count):
        e = struct.unpack_from("<I", data, small + 4 * i)[0]
        is_utf16 = e & 1
        offset = (e >> 1) & 0x7FFFFF
        length = (e >> 24) & 0xFF
        if length == 0xFF:
            offset, length = struct.unpack_from("<II", data, ovf + 8 * offset)
        raw = blob[offset:offset + (length * 2 if is_utf16 else length)]
        out.append(raw.decode("utf-16le" if is_utf16 else "latin1", "replace"))
    return out

data = open(sys.argv[1], "rb").read()
try:
    strs = hermes_strings(data)
except ValueError as e:
    sys.stderr.write("fetch-cloud-key: %s\n" % e)
    sys.exit(1)
keys = [s for s in strs if re.fullmatch(r"[A-Za-z0-9]{64}", s)]
# The RDC companion key can also appear; drop it if both are present.
skip = sys.argv[2] if len(sys.argv) > 2 else ""
keys = [k for k in keys if k != skip]
if len(keys) != 1:
    sys.stderr.write("fetch-cloud-key: expected one 64-char client key in Hermes strings, found %d\n" % len(keys))
    sys.exit(1)
print(keys[0])
' "$1" "${2:-}"
}

# Replace the quoted #define (one-line or `\`-continued). Key must be alphanumeric.
inject_key() {  # key file DEFINE_NAME
    python3 -c '
import re, sys
key, path, name = sys.argv[1], sys.argv[2], sys.argv[3]
if not re.fullmatch(r"[A-Za-z0-9]+", key):
    sys.stderr.write("fetch-cloud-key: refusing to inject non-alphanumeric key\n")
    sys.exit(1)
text = open(path, encoding="utf-8").read()
pat = r"(#define " + re.escape(name) + r"\s*\\?\s*\")[^\"]*(\")"
new, n = re.subn(pat, lambda m: m.group(1) + key + m.group(2), text, count=1)
if n != 1:
    sys.stderr.write("fetch-cloud-key: %s not found in %s\n" % (name, path))
    sys.exit(1)
open(path, "w", encoding="utf-8").write(new)
' "$1" "$2" "$3"
}

# Zip/7z integrity. apkeep (and a dropped curl) can leave a truncated file and
# still exit 0; the next run must not treat that as a cache hit.
archive_ok() { 7z t "$1" >/dev/null 2>&1; }

if [ "$self_check" -eq 1 ]; then
    tmp=$(mktemp)
    hdr=$(mktemp)
    hbc=$(mktemp)
    trap 'rm -f "$tmp" "$hdr" "$hbc"' EXIT
    printf 'exports.config = { apiServerApiKey: "Abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV" };\n' > "$tmp"
    got=$(extract_rdc_key "$tmp")
    expect="Abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV"
    [ "$got" = "$expect" ] || { echo "fetch-cloud-key: rdc self-check failed" >&2; exit 1; }
    # Minimal Hermes v96 with one 64-char string.
    friends_expect="4bcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVXXXXXX"
    python3 -c '
import struct, sys
key = sys.argv[1].encode()
assert len(key) == 64
hdr = bytearray(128)
hdr[0:8] = bytes.fromhex("c61fbc03c103191f")
struct.pack_into("<I", hdr, 8, 96)
# uint32s starting at 32: fileLength, global, funcs, kinds, idents, strings, overflow, storage
struct.pack_into("<8I", hdr, 32, 128 + 4 + 64, 0, 0, 0, 0, 1, 0, 64)
entry = (64 << 24)  # ascii, offset 0, length 64
open(sys.argv[2], "wb").write(bytes(hdr) + struct.pack("<I", entry) + key)
' "$friends_expect" "$hbc"
    got=$(extract_friends_key "$hbc")
    [ "$got" = "$friends_expect" ] || { echo "fetch-cloud-key: friends self-check failed" >&2; exit 1; }
    printf '%s\n' \
        '#define BSDR_CLOUD_API_KEY_DEFAULT \' \
        '    ""' \
        '#define BSDR_CLOUD_CLIENT_KEY_DEFAULT \' \
        '    "keepme"' > "$hdr"
    inject_key "$expect" "$hdr" BSDR_CLOUD_API_KEY_DEFAULT
    grep -q "\"$expect\"" "$hdr" || { echo "fetch-cloud-key: inject self-check failed" >&2; exit 1; }
    grep -q '"keepme"' "$hdr" || { echo "fetch-cloud-key: inject clobbered CLIENT_KEY" >&2; exit 1; }
    inject_key "$expect" "$hdr" BSDR_CLOUD_CLIENT_KEY_DEFAULT
    grep -c "\"$expect\"" "$hdr" | grep -qx 2 || { echo "fetch-cloud-key: client inject failed" >&2; exit 1; }
    printf 'PK\x03\x04' > "$tmp"
    archive_ok "$tmp" && { echo "fetch-cloud-key: truncated zip accepted" >&2; exit 1; }
    echo "fetch-cloud-key: self-check ok"
    exit 0
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "fetch-cloud-key: need $1 ($2)" >&2; exit 1; }; }
# cargo-installed apkeep often lives next to rustc, not on PATH.
if ! command -v apkeep >/dev/null 2>&1; then
    for d in "$HOME/.cargo/bin" "$HOME/.asdf/installs/rust/"*/bin; do
        [ -x "$d/apkeep" ] && PATH="$d:$PATH" && break
    done
fi
need python3 "python3"
need 7z "p7zip / p7zip-full / p7zip-plugins"

download() {  # url dest — write .part then rename so a drop never poisons cache
    part=$2.part
    rm -f "$part"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 3 -o "$part" "$1" || { rm -f "$part"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$part" "$1" || { rm -f "$part"; return 1; }
    else
        echo "fetch-cloud-key: need curl or wget" >&2; return 1
    fi
    mv "$part" "$2"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cache="${XDG_CACHE_HOME:-$HOME/.cache}/bsdrx"
mkdir -p "$cache"

if [ "$client_mode" -eq 1 ]; then
    if [ -n "$apk" ]; then
        [ -f "$apk" ] || { echo "fetch-cloud-key: no such file: $apk" >&2; exit 1; }
        pkg=$apk
        archive_ok "$pkg" || { echo "fetch-cloud-key: incomplete archive: $pkg" >&2; exit 1; }
    else
        need apkeep "cargo install apkeep"
        pkg=""
        for ext in xapk apk; do
            f="$cache/${FRIENDS_PKG}.$ext"
            if [ -f "$f" ]; then
                if archive_ok "$f"; then
                    echo "fetch-cloud-key: using cached Friends package" >&2
                    pkg=$f
                    break
                fi
                echo "fetch-cloud-key: dropping incomplete cache $f" >&2
                rm -f "$f"
            fi
        done
        if [ -z "$pkg" ]; then
            echo "fetch-cloud-key: downloading $FRIENDS_PKG via apkeep ..." >&2
            attempt=1
            while [ "$attempt" -le 3 ]; do
                # apkeep retries in-place then "Skipping..." with exit 0 and a
                # partial file — download to a fresh dir and only promote if complete.
                dl=$work/dl
                rm -rf "$dl"
                mkdir -p "$dl"
                apkeep -a "$FRIENDS_PKG" -d apk-pure "$dl" || true
                for ext in xapk apk; do
                    f="$dl/${FRIENDS_PKG}.$ext"
                    if [ -f "$f" ] && archive_ok "$f"; then
                        mv "$f" "$cache/${FRIENDS_PKG}.$ext"
                        pkg="$cache/${FRIENDS_PKG}.$ext"
                        break
                    fi
                done
                [ -n "$pkg" ] && break
                echo "fetch-cloud-key: incomplete download, retry $attempt/3 ..." >&2
                attempt=$((attempt + 1))
            done
            [ -n "$pkg" ] || { echo "fetch-cloud-key: apkeep did not produce a complete apk/xapk" >&2; exit 1; }
        fi
    fi
    echo "fetch-cloud-key: unpacking Friends APK ..." >&2
    [ -f "$pkg" ] && [ -s "$pkg" ] && archive_ok "$pkg" || {
        echo "fetch-cloud-key: refusing to unpack missing/empty/invalid archive: $pkg" >&2
        exit 1
    }
    case "$pkg" in
        *.xapk)
            7z x -y -o"$work/xapk" "$pkg" >/dev/null
            base=$(find "$work/xapk" \( -name "${FRIENDS_PKG}.apk" -o -name 'base.apk' \) -print -quit)
            [ -n "$base" ] || base=$(find "$work/xapk" -name '*.apk' ! -name 'config.*' -print -quit)
            [ -n "$base" ] || { echo "fetch-cloud-key: no base apk in xapk" >&2; exit 1; }
            7z x -y -o"$work/apk" "$base" assets/index.android.bundle >/dev/null
            ;;
        *)
            7z x -y -o"$work/apk" "$pkg" assets/index.android.bundle >/dev/null
            ;;
    esac
    bundle="$work/apk/assets/index.android.bundle"
    [ -f "$bundle" ] || { echo "fetch-cloud-key: index.android.bundle missing" >&2; exit 1; }
    skip=""
    [ -f "$cloud_h" ] && skip=$(python3 -c '
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"BSDR_CLOUD_API_KEY_DEFAULT\s*\\?\s*\"([^\"]*)\"", t)
print(m.group(1) if m else "")
' "$cloud_h")
    key=$(extract_friends_key "$bundle" "$skip")
    define=BSDR_CLOUD_CLIENT_KEY_DEFAULT
    envname=BSDR_CLOUD_CLIENT_KEY
    role="Friends/client key"
else
    if [ -n "$installer" ]; then
        [ -f "$installer" ] || { echo "fetch-cloud-key: no such file: $installer" >&2; exit 1; }
        exe=$installer
    else
        exe="$cache/BigscreenRemoteDesktopSetup.exe"
        if [ -f "$exe" ] && archive_ok "$exe"; then
            echo "fetch-cloud-key: using cached installer ($exe)" >&2
        else
            [ -f "$exe" ] && { echo "fetch-cloud-key: dropping incomplete cache $exe" >&2; rm -f "$exe"; }
            echo "fetch-cloud-key: downloading official RDC installer ..." >&2
            download "$url" "$exe"
            archive_ok "$exe" || { echo "fetch-cloud-key: installer download incomplete" >&2; rm -f "$exe"; exit 1; }
        fi
    fi
    echo "fetch-cloud-key: unpacking Squirrel installer ..." >&2
    7z x -y -o"$work/setup" "$exe" >/dev/null
    nupkg=$(find "$work/setup" -name '*.nupkg' -print -quit)
    [ -n "$nupkg" ] || { echo "fetch-cloud-key: no .nupkg in installer (not a Squirrel RDC setup?)" >&2; exit 1; }
    echo "fetch-cloud-key: unpacking app.asar ..." >&2
    7z x -y -o"$work/nupkg" "$nupkg" "lib/net45/resources/app.asar" >/dev/null
    asar=$(find "$work/nupkg" -name app.asar -print -quit)
    [ -n "$asar" ] || { echo "fetch-cloud-key: app.asar missing from nupkg" >&2; exit 1; }
    key=$(extract_rdc_key "$asar")
    define=BSDR_CLOUD_API_KEY_DEFAULT
    envname=BSDR_CLOUD_API_KEY
    role="companion key"
fi

if [ "$inject" -eq 1 ]; then
    [ -f "$cloud_h" ] || { echo "fetch-cloud-key: no such file: $cloud_h" >&2; exit 1; }
    inject_key "$key" "$cloud_h" "$define"
    echo "fetch-cloud-key: injected $role into $cloud_h" >&2
fi
if [ "$export_mode" -eq 1 ]; then
    printf "export %s='%s'\n" "$envname" "$key"
else
    printf '%s\n' "$key"
fi
echo "fetch-cloud-key: $role ($envname)" >&2
