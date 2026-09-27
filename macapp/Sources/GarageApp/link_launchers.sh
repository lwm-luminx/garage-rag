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
# It also gives every framework in Contents/Frameworks the versioned layout the Mac App Store
# requires (ITMS-90291/90292, "Malformed Framework"; see the Anatomy of Framework Bundles):
#   - rules_apple's macos_framework builds PythonXPCService.framework flat, iOS style (binary,
#     Info.plist, Frameworks and resources at the top). It moves into Versions/A, with Info.plist
#     and the resources under Versions/A/Resources, where Bundle.resourceURL finds them;
#   - the darwin sandbox hands a tree artifact over with its symlinks resolved, so a versioned
#     framework can arrive with Versions/Current and its top-level entries as real copies.
# Then Versions/Current links to the one version, and the binary and each top-level entry link to
# Versions/Current/<entry>. codesign accepts either layout, so only store validation catches this.
# The bundle is signed after this step, frameworks included, so a stale _CodeSignature goes.
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
    [ -d "$fw" ] || continue
    versions="$fw/Versions"
    binary="$(basename "$fw" .framework)"
    if [ ! -d "$versions" ]; then
        # Flat: code in Versions/A, everything else in Versions/A/Resources.
        mkdir -p "$versions/A/Resources"
        rm -rf "${fw:?}/_CodeSignature"
        for entry in "$fw"/* "$fw"/.[!.]*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            name="$(basename "$entry")"
            case "$name" in
                Versions) ;;
                "$binary" | Frameworks | Headers | Modules | PrivateHeaders | Libraries | XPCServices | Helpers)
                    mv "$entry" "$versions/A/$name" ;;
                Resources) cp -R "$entry"/. "$versions/A/Resources/" && rm -rf "$entry" ;;
                *) mv "$entry" "$versions/A/Resources/$name" ;;
            esac
        done
    fi
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
    # The binary, Resources, and the entries already at the top (resolved copies or links): a
    # version's _CodeSignature, or Python's bin, has no top-level link.
    for entry in "$versions/$version"/*; do
        name="$(basename "$entry")"
        [ "$name" != "_CodeSignature" ] || continue
        if [ -e "$fw/$name" ] || [ -L "$fw/$name" ] || [ "$name" = "$binary" ] || [ "$name" = Resources ] ||
            [ "$name" = Frameworks ]; then
            rm -rf "${fw:?}/$name"
            ln -s "Versions/Current/$name" "$fw/$name"
        fi
    done
done
