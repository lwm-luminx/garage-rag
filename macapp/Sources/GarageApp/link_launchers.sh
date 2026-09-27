#!/bin/bash
# rules_apple `ipa_post_processor` for Garage.app: runs on the assembled bundle before it is
# signed, with one argument, a directory whose only entry is Garage.app. It creates the stable
# command-line entry points
#
#   Contents/MacOS/garage      -> ../Resources/launchers/garage
#   Contents/MacOS/garage-mcp  -> ../Resources/launchers/garage-mcp
#
# as symlinks to the forwarder scripts, which exec the launcher helper bundles in
# Contents/Helpers. A symlink rather than the script itself in Contents/MacOS: codesign treats
# every file there as nested code that must carry a signature of its own, which a script cannot,
# while a symlink is sealed as a symlink (a `symlink` entry in CodeResources) and `--deep --strict`
# verification accepts it. Bazel cannot ship a symlink as a source file, hence this step.
#
# It also puts back the links of each versioned framework in Contents/Frameworks. The darwin
# sandbox hands a tree artifact over with its symlinks resolved, so PythonXPCService.framework
# arrived with Versions/Current and the top-level PythonXPCService, Resources and Frameworks as
# real copies. codesign accepts that, but App Store validation rejects it (ITMS-90291/90292,
# "Malformed Framework"). Versions/Current becomes a link to the one version and each top-level
# entry a link to Versions/Current/<entry>, as in the Anatomy of Framework Bundles.
set -euo pipefail

root="$1"
app="$(find "$root" -mindepth 1 -maxdepth 1 -type d -name '*.app' | head -n 1)"
if [ -z "$app" ]; then
    echo "link_launchers: no .app in $root" >&2
    exit 1
fi

for name in garage garage-mcp; do
    forwarder="$app/Contents/Resources/launchers/$name"
    if [ ! -f "$forwarder" ]; then
        echo "link_launchers: missing forwarder $forwarder" >&2
        exit 1
    fi
    chmod 755 "$forwarder"
    link="$app/Contents/MacOS/$name"
    rm -f "$link"
    ln -s "../Resources/launchers/$name" "$link"
done

for fw in "$app"/Contents/Frameworks/*.framework; do
    versions="$fw/Versions"
    [ -d "$versions" ] || continue
    version=""
    if [ -L "$versions/Current" ]; then
        version="$(readlink "$versions/Current")"
    else
        candidates=()
        for d in "$versions"/*/; do
            n="$(basename "$d")"
            [ "$n" = "Current" ] || candidates+=("$n")
        done
        if [ "${#candidates[@]}" -eq 1 ]; then
            version="${candidates[0]}"
        elif [ "${#candidates[@]}" -eq 0 ] && [ -d "$versions/Current" ]; then
            # Only a resolved Current: it becomes the version rules_apple names A.
            mv "$versions/Current" "$versions/A"
            version="A"
        fi
    fi
    if [ -z "$version" ] || [ ! -d "$versions/$version" ]; then
        echo "link_launchers: cannot tell which version $(basename "$fw") is" >&2
        exit 1
    fi
    rm -rf "$versions/Current"
    ln -s "$version" "$versions/Current"
    # Only the entries already at the top (resolved copies or links) and the binary: a version's
    # _CodeSignature, or Python's bin, has no top-level link.
    binary="$(basename "$fw" .framework)"
    for entry in "$versions/$version"/*; do
        name="$(basename "$entry")"
        [ "$name" != "_CodeSignature" ] || continue
        if [ -e "$fw/$name" ] || [ -L "$fw/$name" ] || [ "$name" = "$binary" ]; then
            rm -rf "${fw:?}/$name"
            ln -s "Versions/Current/$name" "$fw/$name"
        fi
    done
done
