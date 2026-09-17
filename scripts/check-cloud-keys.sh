#!/bin/sh
# Reject a commit/merge that would land Bigscreen's keys in include/bsdr/cloud.h.
# Local `fetch-cloud-key.sh --inject` is fine; this only blocks the git write.
#
# Install (do not git config; .git/hooks is local):
#   ln -sf ../../scripts/check-cloud-keys.sh .git/hooks/pre-commit
#   ln -sf ../../scripts/check-cloud-keys.sh .git/hooks/pre-merge-commit
#
#   scripts/check-cloud-keys.sh              # check the repo cloud.h
#   scripts/check-cloud-keys.sh FILE         # check FILE
#   scripts/check-cloud-keys.sh --self-check
set -eu

# Quoted #define value that looks like an injected key (fetch-cloud-key.sh: 16+ alnum, 64 in practice).
# One-line or `\`-continued. Ignores comments and env-var names.
scan_keys() {  # file -> stdout: one DEFINE_NAME per hit
    awk '
        BEGIN {
            names[0] = "BSDR_CLOUD_API_KEY_DEFAULT"
            names[1] = "BSDR_CLOUD_CLIENT_KEY_DEFAULT"
        }
        {
            if (pending != "") { line = pending $0; pending = "" } else { line = $0 }
            if (line ~ /\\$/) { sub(/\\$/, "", line); pending = line; next }
            for (i = 0; i < 2; i++) {
                n = names[i]
                if (index(line, "#define " n) == 0) continue
                if (!match(line, /"[^"]*"/)) continue
                val = substr(line, RSTART + 1, RLENGTH - 2)
                if (val ~ /^[A-Za-z0-9]{16,}$/) print n
            }
        }
    ' "$1"
}

report() {  # file name [name...]
    file=$1; shift
    case $# in
        1) echo "check-cloud-keys: $1 is set in $file" >&2 ;;
        2) echo "check-cloud-keys: $1 and $2 are set in $file" >&2 ;;
        *) echo "check-cloud-keys: $* are set in $file" >&2 ;;
    esac
    echo "Revert $file (or re-run fetch without --inject / restore the blank defaults)." >&2
}

check_file() {
    [ -f "$1" ] || return 0
    file=$1
    set -- $(scan_keys "$file")
    [ $# -eq 0 ] && return 0
    report "$file" "$@"
    return 1
}

self_check() {
    d=$(mktemp -d)
    trap 'rm -rf "$d"' EXIT
    k64="Abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVXXXXXX"
    k16="0123456789ABCDEF"
    k15="0123456789ABCDE"

    printf '%s\n' \
        '#define BSDR_CLOUD_API_KEY_DEFAULT \' \
        '    ""' \
        '#define BSDR_CLOUD_CLIENT_KEY_DEFAULT \' \
        '    ""' > "$d/blank.h"
    check_file "$d/blank.h" || { echo "check-cloud-keys: blank should pass" >&2; exit 1; }

    printf '%s\n' \
        '#define BSDR_CLOUD_API_KEY_DEFAULT "TODO"' \
        '#define BSDR_CLOUD_CLIENT_KEY_DEFAULT "blank in the public mirror"' > "$d/ph.h"
    check_file "$d/ph.h" || { echo "check-cloud-keys: placeholder should pass" >&2; exit 1; }

    printf '%s\n' \
        '#define BSDR_CLOUD_API_KEY_DEFAULT \' \
        "    \"$k15\"" \
        '#define BSDR_CLOUD_CLIENT_KEY_DEFAULT ""' > "$d/short.h"
    check_file "$d/short.h" || { echo "check-cloud-keys: 15-char should pass" >&2; exit 1; }

    printf '%s\n' \
        '/* BSDR_CLOUD_API_KEY / BSDR_CLOUD_CLIENT_KEY — do not flag comments. */' \
        "/* leaked $k64 */" \
        '#define BSDR_CLOUD_API_KEY_DEFAULT \' \
        '    ""' \
        '#define BSDR_CLOUD_CLIENT_KEY_DEFAULT ""' > "$d/cmt.h"
    check_file "$d/cmt.h" || { echo "check-cloud-keys: comment should pass" >&2; exit 1; }

    printf '%s\n' \
        '#define BSDR_CLOUD_API_KEY_DEFAULT \' \
        "    \"$k64\"" \
        '#define BSDR_CLOUD_CLIENT_KEY_DEFAULT ""' > "$d/api.h"
    check_file "$d/api.h" >/dev/null 2>&1 && { echo "check-cloud-keys: 64-char API key should fail" >&2; exit 1; }

    printf '%s\n' "#define BSDR_CLOUD_CLIENT_KEY_DEFAULT \"$k16\"" > "$d/one.h"
    check_file "$d/one.h" >/dev/null 2>&1 && { echo "check-cloud-keys: 16-char CLIENT key should fail" >&2; exit 1; }

    printf '%s\n' \
        "#define BSDR_CLOUD_API_KEY_DEFAULT \"$k16\"" \
        "#define BSDR_CLOUD_CLIENT_KEY_DEFAULT \"$k64\"" > "$d/both.h"
    got=$(scan_keys "$d/both.h")
    echo "$got" | grep -qx BSDR_CLOUD_API_KEY_DEFAULT || { echo "check-cloud-keys: missed API key" >&2; exit 1; }
    echo "$got" | grep -qx BSDR_CLOUD_CLIENT_KEY_DEFAULT || { echo "check-cloud-keys: missed CLIENT key" >&2; exit 1; }

    echo "check-cloud-keys: self-check ok"
}

if [ "${1:-}" = "--self-check" ]; then
    self_check
    exit 0
fi

if [ -n "${1:-}" ]; then
    check_file "$1"
    exit
fi

if ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    :
else
    # Not a git hook: script lives in scripts/
    ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
fi
check_file "$ROOT/include/bsdr/cloud.h"
