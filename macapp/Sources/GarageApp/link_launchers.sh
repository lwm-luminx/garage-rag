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
# It also checks, without repairing anything, that every framework in Contents/Frameworks has the
# versioned layout the Mac App Store requires (ITMS-90291/90292, "Malformed Framework"): a
# Versions/Current link to a version folder, and the binary and each other top-level entry a link
# to Versions/Current/<entry>. codesign accepts a flat framework, so only store validation would
# otherwise catch one. PythonXPCService.framework gets the layout from macos_versioned_framework
# (//bazel:macos_framework.bzl), Python.framework from its apple_dynamic_framework_import.
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
    name="$(basename "$fw")"
    binary="$(basename "$fw" .framework)"
    current="$fw/Versions/Current"
    if [ ! -L "$current" ] || [ ! -d "$current/" ]; then
        echo "link_launchers: $name is not versioned (no Versions/Current link to a version)" >&2
        exit 1
    fi
    [ -L "$fw/$binary" ] || { echo "link_launchers: $name: $binary is not a link" >&2; exit 1; }
    for entry in "$fw"/*; do
        top="$(basename "$entry")"
        [ "$top" != Versions ] || continue
        if [ ! -L "$entry" ] || [ "$(readlink "$entry")" != "Versions/Current/$top" ]; then
            echo "link_launchers: $name: $top is not a link to Versions/Current/$top" >&2
            exit 1
        fi
    done
done
