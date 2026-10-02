#!/bin/bash
# Records which Mach-O images Garage's processes load at run time, and whether each would pass
# library validation without com.apple.security.cs.disable-library-validation.
#
# Hardened runtime ignores DYLD_PRINT_LIBRARIES, and vmmap needs a task port a hardened process
# does not hand out. lsof needs neither: dyld maps every image it loads, and lsof lists mapped
# files. CPython never unloads an extension module, so a process's mappings only grow; polling
# them and keeping the union catches every load, including processes that exit before the end.
#
#   tools/macos/trace_loaded_images.sh [--app PATH] [--seconds N] [--out DIR]
#
# Start it, then drive the app through every path you care about (ingest a source, backfill,
# search, enrich-facts, the MCP server, the XPC self-tests). Press Ctrl-C, or wait --seconds, and it
# writes:
#
#   DIR/images.tsv   process, image path, class, team id, how it loaded
#   DIR/summary.txt  per process: the non-system images, and every one whose Team ID differs
#                    from the process's own (those are what library validation would reject)
#
# Classes: lib-dynload (stdlib extension), site-packages (third-party extension), bundled
# (anything else inside the app), system (/usr/lib, /System). "How it loaded" is "linked" when
# some image in the same process names it in an LC_LOAD_DYLIB command (the way Python.framework is
# bound through PythonXPCService.framework), and "dlopen" otherwise.
set -uo pipefail

app="/Applications/GarageApp.app"
seconds=0
out="${TMPDIR:-/tmp}/garage-image-trace"

while [ $# -gt 0 ]; do
    case "$1" in
        --app) app="$2"; shift 2 ;;
        --seconds) seconds="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

app="$(cd "$app" 2>/dev/null && pwd -P)" || { echo "no app at the given path" >&2; exit 2; }
mkdir -p "$out"
raw="$out/raw.tsv"   # pid <TAB> executable <TAB> image, deduplicated as it grows
: > "$raw"

# Processes whose executable lives in the app bundle: the app, its XPC services, the helpers,
# and the Postgres binaries it starts.
garage_pids() {
    ps -axo pid=,comm= | while read -r pid comm; do
        case "$comm" in "$app"/*) echo "$pid $comm" ;; esac
    done
}

snapshot() {
    garage_pids | while read -r pid comm; do
        # -Fn: one "n<path>" line per open file; mapped images show as FD "txt".
        lsof -n -P -p "$pid" -a -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | while IFS= read -r image; do
            [ -f "$image" ] || continue
            printf '%s\t%s\t%s\n' "$pid" "$comm" "$image"
        done
    done >> "$raw"
    sort -u -o "$raw" "$raw"
}

finish() {
    trap - INT TERM
    echo
    echo "writing $out/images.tsv and $out/summary.txt"
    report
    exit 0
}
trap finish INT TERM

team_id() {
    local id
    id="$(codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    case "$id" in
        ""|"not set") echo "none" ;;
        *) echo "$id" ;;
    esac
}

classify() {
    case "$1" in
        /usr/lib/*|/System/*|/Library/Apple/*) echo system ;;
        */lib-dynload/*) echo lib-dynload ;;
        */site-packages/*) echo site-packages ;;
        "$app"/*) echo bundled ;;
        *) echo outside-app ;;
    esac
}

report() {
    local images="$out/images.tsv" summary="$out/summary.txt"
    printf 'pid\tprocess\timage\tclass\tteam_id\tloaded_by\n' > "$images"

    # Every install name some image of a process links, by basename: enough to tell a
    # pre-bound library from a dlopen'd one, since the bundle has no two images of one name.
    local pid
    for pid in $(cut -f1 "$raw" | sort -u); do
        local comm linked
        comm="$(awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }' "$raw")"
        linked="$(awk -F'\t' -v p="$pid" '$1 == p { print $3 }' "$raw" | while IFS= read -r image; do
            otool -L "$image" 2>/dev/null | tail -n +2 | awk '{ print $1 }' | sed 's#.*/##'
        done | sort -u)"
        awk -F'\t' -v p="$pid" '$1 == p { print $3 }' "$raw" | while IFS= read -r image; do
            local class team how
            class="$(classify "$image")"
            if [ "$class" = system ]; then
                team="apple"
            else
                team="$(team_id "$image")"
            fi
            if [ "$image" = "$comm" ]; then
                how="main"
            elif grep -qxF "$(basename "$image")" <<< "$linked"; then
                how="linked"
            else
                how="dlopen"
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$comm" "$image" "$class" "$team" "$how"
        done >> "$images"
    done

    {
        echo "Garage loaded-image trace, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "app: $app"
        echo
        for pid in $(tail -n +2 "$images" | cut -f1 | sort -un); do
            local comm own
            comm="$(awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }' "$images")"
            own="$(team_id "$comm")"
            echo "== ${comm#"$app"/} (pid $pid, team $own)"
            awk -F'\t' -v p="$pid" '$1 == p && $4 != "system" && $6 != "main" {
                n[$4 " " $6]++
            } END { for (k in n) printf "   %-28s %d\n", k, n[k] }' "$images" | sort
            local bad
            bad="$(awk -F'\t' -v p="$pid" -v own="$own" \
                '$1 == p && $4 != "system" && $6 != "main" && $5 != own { printf "   %s  %s  %s\n", $5, $6, $3 }' "$images")"
            if [ -n "$bad" ]; then
                echo "   would fail library validation (Team ID differs from the process's):"
                echo "$bad"
            else
                echo "   every non-system image carries the process's Team ID"
            fi
            echo
        done
    } > "$summary"
    cat "$summary"
}

echo "tracing processes under $app; exercise the app, then press Ctrl-C" >&2
start=$(date +%s)
while :; do
    snapshot
    if [ "$seconds" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$seconds" ]; then
        finish
    fi
    sleep 1
done
