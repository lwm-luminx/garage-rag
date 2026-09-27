#!/usr/bin/env bash
# Notarizes and staples the Developer ID release, in the order Gatekeeper needs:
#
#   aspect build //macapp/package:GarageApp
#   aspect run //macapp/package:notarize_all
#
#   1. notarize the signed app (bazel-bin/macapp/package/GarageApp.zip);
#   2. staple the ticket to Garage.app and zip the stapled copy;
#   3. build and sign the installer from that stapled app;
#   4. notarize the installer, then staple it.
#
# It leaves, in dist/ at the root of the checkout:
#   - Garage-<version>.zip, the stapled app, for Sparkle (publish_appcast) and the GitHub release;
#   - GarageInstaller_arm64.pkg, the stapled installer, whose app is stapled too.
#
# The installer is built here and not by a Bazel action because the app has to be notarized
# first, and notarizing needs the notary service; an installer built at build time would carry
# an app with no ticket. See macapp/README.md ("Cutting a release") and RELEASING.md.
set -euo pipefail

die() {
    echo "notarize_all: $*" >&2
    exit 1
}

archive="" keychain_profile="" installer_identity="" identifier=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive) archive="$2"; shift 2 ;;
        --keychain-profile) keychain_profile="$2"; shift 2 ;;
        --installer-identity) installer_identity="$2"; shift 2 ;;
        --identifier) identifier="$2"; shift 2 ;;
        *) die "unknown argument $1" ;;
    esac
done

[[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]] || die "run this with 'aspect run //macapp/package:notarize_all'"
[[ -f "$archive" ]] || die "missing runfile '$archive'; run 'aspect build //macapp/package:GarageApp' first"
[[ -n "$keychain_profile" && -n "$installer_identity" && -n "$identifier" ]] ||
    die "--keychain-profile, --installer-identity and --identifier are required"
# Resolve the runfile before leaving the runfiles directory.
archive="$(cd "$(dirname "$archive")" && pwd -P)/$(basename "$archive")"
cd "$BUILD_WORKSPACE_DIRECTORY"

work="$(mktemp -d "${TMPDIR:-/tmp}/garage-notarize.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Submits one file and waits. notarytool exits 0 for a submission Apple rejected, so the
# status is read from its JSON; a rejection prints the notary log.
notarize() {
    local file="$1" result id status
    echo "==> Notarizing $(basename "$file") (this waits for the notary service)"
    result="$(xcrun notarytool submit "$file" --keychain-profile "$keychain_profile" --wait --output-format json)" ||
        die "notarytool submit failed for $file"
    id="$(json_field id <<<"$result")"
    status="$(json_field status <<<"$result")"
    echo "    submission $id: $status"
    if [[ "$status" != "Accepted" ]]; then
        xcrun notarytool log "$id" --keychain-profile "$keychain_profile" >&2 || true
        die "notarization of $(basename "$file") was not accepted ($status)"
    fi
    submissions+=("$(basename "$file"): $id")
}

json_field() {
    /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}

staple() {
    echo "==> Stapling $(basename "$1")"
    xcrun stapler staple "$1"
    xcrun stapler validate "$1"
}

submissions=()

# 1. The app.
mkdir "$work/root"
ditto -x -k "$archive" "$work/root"
app="$work/root/Garage.app"
[[ -d "$app" ]] || die "$archive does not contain Garage.app"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
build="$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")"
echo "==> Garage $version (build $build)"
notarize "$archive"

# 2. Staple it, and zip the stapled copy.
staple "$app"
mkdir -p dist
zip="dist/Garage-$version.zip"
pkg="dist/GarageInstaller_arm64.pkg"
rm -f "$zip" "$pkg"
ditto -c -k --keepParent "$app" "$zip"

# 3. The installer, from the stapled app. It is not relocatable, so it always installs to
#    /Applications rather than "updating" a copy of Garage it finds elsewhere on the disk.
pkgbuild --analyze --root "$work/root" "$work/component.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$work/component.plist"
pkgbuild --root "$work/root" --component-plist "$work/component.plist" \
    --install-location /Applications --identifier "$identifier" --version "$version" \
    --sign "$installer_identity" --timestamp \
    "$pkg"

# 4. Notarize and staple the installer.
notarize "$pkg"
staple "$pkg"

cat <<EOF

Garage $version (build $build) is notarized and stapled:
  $zip
  $pkg
Notary submissions:
$(printf '  %s\n' "${submissions[@]}")
EOF
