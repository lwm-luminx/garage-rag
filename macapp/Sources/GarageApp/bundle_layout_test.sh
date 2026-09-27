#!/bin/bash
# Checks the launcher layout of the built Garage.app (its .zip is the one argument):
#
#   Contents/MacOS/garage, garage-mcp              executable /bin/sh forwarders (not Mach-O)
#   Contents/Helpers/garage.app                    bundle ID me.rickmark.garage-rag.garage-cli
#   Contents/Helpers/garage-mcp.app                bundle ID me.rickmark.garage-rag.mcp-server-cli
#
# with each helper's executable a Mach-O that reaches the app's Frameworks through its rpaths,
# marked LSUIElement, and `garage version` running through the forwarder: the forwarder resolves
# the helper, the helper resolves the app bundle, and the embedded interpreter starts from the
# app's PythonXPCService.framework. `version` needs no database, so no app is started and no
# Keychain is read. It also checks that PythonXPCService's code is only in the app's framework:
# `garage version` prints no "Class ... is implemented in both" warning, and no helper or XPC
# service binary defines the framework's types. Every versioned framework in Contents/Frameworks
# keeps its links (Versions/Current and the top-level entries), which App Store validation needs.
set -euo pipefail

archive="$1"
work="$(mktemp -d "${TMPDIR:-/tmp}/bundle_layout_test.XXXXXX")"
trap 'chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"' EXIT
# The archive is a .zip, or the bundle directory itself under tree-artifact outputs.
if [ -d "$archive" ]; then
    /usr/bin/ditto "$archive" "$work/$(basename "$archive")"
elif [ -f "$archive" ]; then
    /usr/bin/ditto -x -k "$archive" "$work"
else
    echo "no archive at $archive" >&2
    exit 1
fi
app="$work/Garage.app"
[ -d "$app" ] || { echo "no Garage.app in $archive" >&2; exit 1; }

failures=0
fail() {
    echo "[FAIL] $*"
    failures=$((failures + 1))
}
pass() {
    echo "[PASS] $*"
}

check_framework_links() {
    local fw="$1" name
    name="$(basename "$fw")"
    [ -d "$fw/Versions" ] || return 0
    if [ ! -L "$fw/Versions/Current" ]; then
        fail "$name: Versions/Current is not a symlink"
        return
    fi
    local entry top ok=1
    for entry in "$fw/Versions/Current"/*; do
        top="$fw/$(basename "$entry")"
        # Entries with no top-level counterpart (_CodeSignature, Python's bin) need no link.
        [ -e "$top" ] || [ -L "$top" ] || [ "$(basename "$entry")" = "${name%.framework}" ] || continue
        if [ ! -L "$top" ] || [ "$(readlink "$top")" != "Versions/Current/$(basename "$entry")" ]; then
            fail "$name: $(basename "$entry") is not a symlink to Versions/Current/$(basename "$entry")"
            ok=0
        fi
    done
    [ "$ok" = 1 ] && pass "$name: Versions/Current and its top-level entries are symlinks"
}

check_forwarder() {
    local name="$1" helper="$2"
    local link="$app/Contents/MacOS/$name"
    local script="$app/Contents/Resources/launchers/$name"
    if [ ! -L "$link" ]; then
        fail "$name: Contents/MacOS/$name is not a symlink"
        return
    fi
    local target
    target="$(readlink "$link")"
    [ "$target" = "../Resources/launchers/$name" ] \
        || fail "$name: Contents/MacOS/$name links to '$target', expected ../Resources/launchers/$name"
    if [ ! -f "$script" ] || [ -L "$script" ]; then
        fail "$name: Contents/Resources/launchers/$name is not a regular file"
        return
    fi
    [ -x "$script" ] || fail "$name: forwarder script is not executable"
    if file -b "$script" | grep -q "Mach-O"; then
        fail "$name: forwarder is a Mach-O, not a script"
    fi
    head -n 1 "$script" | grep -q '^#!/bin/sh' || fail "$name: forwarder does not start with #!/bin/sh"
    grep -q "Helpers/$helper/Contents/MacOS" "$script" || fail "$name: forwarder does not name Helpers/$helper"
    pass "$name: Contents/MacOS/$name -> Resources/launchers/$name, forwarding to Helpers/$helper"
}

check_helper() {
    local name="$1" bundle_id="$2"
    local helper="$app/Contents/Helpers/$name.app"
    local plist="$helper/Contents/Info.plist"
    local executable="$helper/Contents/MacOS/$name"
    [ -d "$helper" ] || { fail "$name: no Contents/Helpers/$name.app"; return; }
    [ -f "$plist" ] || { fail "$name: helper has no Info.plist"; return; }

    local actual_id
    actual_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || true)"
    [ "$actual_id" = "$bundle_id" ] || fail "$name: CFBundleIdentifier is '$actual_id', expected '$bundle_id'"
    local ui_element
    ui_element="$(/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$plist" 2>/dev/null || true)"
    [ "$ui_element" = "true" ] || fail "$name: LSUIElement is '$ui_element', expected true"
    local cf_executable
    cf_executable="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null || true)"
    [ "$cf_executable" = "$name" ] || fail "$name: CFBundleExecutable is '$cf_executable', expected '$name'"

    [ -x "$executable" ] || { fail "$name: helper executable missing or not executable"; return; }
    file -b "$executable" | grep -q "Mach-O" || fail "$name: helper executable is not a Mach-O"
    local load_commands linked
    load_commands="$(otool -l "$executable" 2>/dev/null || true)"
    linked="$(otool -L "$executable" 2>/dev/null || true)"
    grep -qF -- "path @executable_path/../../../../Frameworks (offset" <<<"$load_commands" \
        || fail "$name: helper lacks the @executable_path/../../../../Frameworks rpath"
    grep -q -- "Python.framework" <<<"$linked" || fail "$name: helper does not link Python.framework"
    grep -q -- "PythonXPCService.framework" <<<"$linked" \
        || fail "$name: helper does not link PythonXPCService.framework"

    local signing_id
    signing_id="$(codesign -dv "$helper" 2>&1 | sed -n 's/^Identifier=//p')"
    [ "$signing_id" = "$bundle_id" ] || fail "$name: signing identifier is '$signing_id', expected '$bundle_id'"
    pass "$name: Contents/Helpers/$name.app is $bundle_id"
}

check_forwarder garage garage.app
check_forwarder garage-mcp garage-mcp.app
check_helper garage me.rickmark.garage-rag.garage-cli
check_helper garage-mcp me.rickmark.garage-rag.mcp-server-cli
for fw in "$app"/Contents/Frameworks/*.framework; do
    check_framework_links "$fw"
done

# No stray bare launchers left in Contents/MacOS: the app's executable and the two forwarders only.
for entry in "$app/Contents/MacOS"/*; do
    case "$(basename "$entry")" in
        GarageApp|garage|garage-mcp) ;;
        *) fail "unexpected entry in Contents/MacOS: $(basename "$entry")" ;;
    esac
done

# Through the forwarder, end to end. GARAGE_NO_APP_LAUNCH guards against any path that would
# open the app; `version` takes none.
output="$(cd "$work" && GARAGE_NO_APP_LAUNCH=1 "$app/Contents/MacOS/garage" version 2>&1)" && status=0 || status=$?
if [ "$status" -ne 0 ]; then
    fail "garage version exited $status through the forwarder:"
    printf '%s\n' "$output" | sed 's/^/       /'
else
    pass "garage version through the forwarder: $(printf '%s' "$output" | head -n 1)"
fi
# A class compiled into the helper and into PythonXPCService.framework is loaded twice, and the
# Objective-C runtime says so on stderr ("Class ... is implemented in both ...").
if grep -q -- "is implemented in both" <<<"$output"; then
    fail "garage version loads classes twice:"
    printf '%s\n' "$output" | grep "is implemented in both" | sed 's/^/       /'
else
    pass "garage version loads no class twice"
fi

# One PythonXPCService.framework, the app's, and no helper or XPC service with its own copy of the
# framework's code (//bazel:framework_linking.bzl): each links the framework instead. The check
# looks for the Swift type descriptors of a class from each module the framework carries, and
# first confirms the framework itself defines them, so a stripped binary cannot pass unchecked.
copies="$(find "$app" -type d -name PythonXPCService.framework | wc -l | tr -d ' ')"
if [ "$copies" = "1" ] && [ -d "$app/Contents/Frameworks/PythonXPCService.framework" ]; then
    pass "one PythonXPCService.framework, in Contents/Frameworks"
else
    fail "expected one PythonXPCService.framework, in Contents/Frameworks; found $copies:"
    find "$app" -type d -name PythonXPCService.framework | sed 's/^/       /'
fi
# The descriptors are ones whose mangled names spell the type out: Swift's word substitution
# shortens a name that repeats its module's words (GarageXPCServiceBase is 06GarageB4BaseCMn).
# Symbol lists go to grep as here-strings, not through a pipe: `grep -q` exits at the first match,
# and under pipefail the writer's SIGPIPE would turn that match into a failure.
descriptors=(
    '16GarageFileLoggerCMn'
    '9PythonKit11PyReferenceCMn'
)
framework_binary="$app/Contents/Frameworks/PythonXPCService.framework/PythonXPCService"
framework_symbols="$(/usr/bin/nm -U -j "$framework_binary" 2>/dev/null || true)"
for descriptor in "${descriptors[@]}"; do
    grep -q -- "$descriptor" <<<"$framework_symbols" \
        || fail "PythonXPCService.framework does not define $descriptor; the duplicate check below cannot see it"
done
for binary in "$app"/Contents/Helpers/*.app/Contents/MacOS/* "$app"/Contents/XPCServices/*.xpc/Contents/MacOS/*; do
    [ -f "$binary" ] || continue
    name="${binary#"$app"/Contents/}"
    symbols="$(/usr/bin/nm -U -j "$binary" 2>/dev/null || true)"
    duplicated=""
    for descriptor in "${descriptors[@]}"; do
        if grep -q -- "$descriptor" <<<"$symbols"; then
            duplicated="$duplicated $descriptor"
        fi
    done
    if [ -n "$duplicated" ]; then
        fail "$name defines what PythonXPCService.framework already carries:$duplicated"
    elif grep -q -- "PythonXPCService.framework/" <<<"$(/usr/bin/otool -L "$binary" 2>/dev/null || true)"; then
        pass "$name links PythonXPCService.framework and carries none of its code"
    else
        fail "$name does not link PythonXPCService.framework"
    fi
done

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "bundle layout OK"
