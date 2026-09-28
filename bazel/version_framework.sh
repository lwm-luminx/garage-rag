#!/bin/bash
# rules_apple `ipa_post_processor` for `macos_versioned_framework` (//bazel:macos_framework.bzl):
# runs on the assembled framework before it is signed and zipped, with one argument, a directory
# whose only entry is <Name>.framework, and turns rules_apple's flat (iOS style) layout into the
# versioned one the Mac App Store requires (ITMS-90291/90292, "Malformed Framework"; see the
# Anatomy of Framework Bundles):
#
#   <Name>.framework/
#     <Name>     -> Versions/Current/<Name>
#     Resources  -> Versions/Current/Resources
#     Frameworks -> Versions/Current/Frameworks   (and Headers, Modules, ... when present)
#     Versions/
#       Current  -> A
#       A/<Name>, A/Frameworks, ...
#       A/Resources/Info.plist and every other resource
#
# Code (the binary and the folders listed below) goes to Versions/A, everything else, Info.plist
# included, to Versions/A/Resources, where Bundle.resourceURL finds it. The links are relative, so
# rules_apple's zip (`zip --symlinks`) and the app's bundletool carry them into the app as links.
set -euo pipefail

root="$1"
frameworks=("$root"/*.framework)
if [ "${#frameworks[@]}" -ne 1 ] || [ ! -d "${frameworks[0]}" ]; then
    echo "version_framework: expected one .framework in $root" >&2
    exit 1
fi
fw="${frameworks[0]}"
binary="$(basename "$fw" .framework)"
version="A"
dest="$fw/Versions/$version"

if [ -e "$fw/Versions" ]; then
    echo "version_framework: $(basename "$fw") already has Versions" >&2
    exit 1
fi
if [ ! -f "$fw/$binary" ]; then
    echo "version_framework: no binary $binary in $(basename "$fw")" >&2
    exit 1
fi

mkdir -p "$dest/Resources"
# Nothing is signed yet; a stale seal would only describe the flat layout.
rm -rf "${fw:?}/_CodeSignature"
for entry in "$fw"/* "$fw"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="$(basename "$entry")"
    case "$name" in
        Versions) ;;
        "$binary" | Frameworks | Headers | Modules | PrivateHeaders | Libraries | XPCServices | Helpers)
            mv "$entry" "$dest/$name" ;;
        Resources) cp -R "$entry"/. "$dest/Resources/" && rm -rf "$entry" ;;
        *) mv "$entry" "$dest/Resources/$name" ;;
    esac
done

ln -s "$version" "$fw/Versions/Current"
for entry in "$dest"/*; do
    name="$(basename "$entry")"
    ln -s "Versions/Current/$name" "$fw/$name"
done
