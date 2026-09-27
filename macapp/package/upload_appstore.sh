#!/usr/bin/env bash
# Exports the App Store archive, validates it with App Store Connect and uploads it to TestFlight,
# the steps Xcode Organizer's Validate App and Distribute App did by hand:
#
#   aspect run //macapp/package:upload_appstore --bazel-flag=--config=appstore_release
#   aspect run //macapp/package:upload_appstore --bazel-flag=--config=appstore_release -- --validate-only
#   aspect run //macapp/package:upload_appstore --bazel-flag=--config=appstore_release -- --export-only
#
#   1. copy //macapp:GarageStore.xcarchive out of bazel-out, which is read-only;
#   2. install the three Mac App Store profiles, so xcodebuild finds them by name;
#   3. `xcodebuild -exportArchive`: re-sign with Apple Distribution and those profiles, nested code
#      first, and build the installer package signed with the Mac Installer Distribution identity;
#   4. `xcrun altool --validate-app`, then `--upload-app`, with an App Store Connect API key.
#
# It leaves dist/Garage-<version>-<build>-AppStore.pkg, the file it uploaded, which Transporter
# can also upload by hand.
#
# The API key (App Store Connect → Users and Access → Integrations → Team Keys, role Developer or
# App Manager) is read from the login keychain, stored once with:
#
#   security add-generic-password -U -s me.rickmark.garage-rag.asc-api-key \
#       -a <KEY ID> -j <ISSUER ID> -w "$(base64 < AuthKey_<KEY ID>.p8)"
#
# GARAGE_ASC_KEY_ID, GARAGE_ASC_ISSUER_ID and GARAGE_ASC_KEY_PATH (the .p8 file) override it.
# The key is written to a private temporary folder for altool and removed on exit.
# See macapp/README.md ("App Store configuration") and RELEASING.md.
set -euo pipefail

KEYCHAIN_SERVICE="me.rickmark.garage-rag.asc-api-key"

die() {
    echo "upload_appstore: $*" >&2
    exit 1
}

archive="" team="" signing_identity="Apple Distribution"
installer_identity="3rd Party Mac Developer Installer" mode="upload"
profiles=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive) archive="$2"; shift 2 ;;
        --team) team="$2"; shift 2 ;;
        --profile) profiles+=("$2"); shift 2 ;;
        --signing-identity) signing_identity="$2"; shift 2 ;;
        --installer-identity) installer_identity="$2"; shift 2 ;;
        --validate-only) mode="validate"; shift ;;
        --export-only) mode="export"; shift ;;
        *) die "unknown argument $1" ;;
    esac
done

[[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]] ||
    die "run this with 'aspect run //macapp/package:upload_appstore --bazel-flag=--config=appstore_release'"
[[ -d "$archive" ]] || die "missing runfile '$archive'; build //macapp:GarageStore.xcarchive first"
[[ -n "$team" && ${#profiles[@]} -gt 0 ]] || die "--team and at least one --profile BUNDLE_ID=FILE are required"
# Resolve runfiles before leaving the runfiles directory.
archive="$(cd "$archive" && pwd -P)"
for i in "${!profiles[@]}"; do
    file="${profiles[$i]#*=}"
    [[ -f "$file" ]] || die "missing provisioning profile '$file'"
    profiles[i]="${profiles[$i]%%=*}=$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
done
cd "$BUILD_WORKSPACE_DIRECTORY"

work="$(mktemp -d "${TMPDIR:-/tmp}/garage-appstore.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# 1. A writable copy of the archive. ditto keeps the framework symlinks the signatures cover.
ditto "$archive" "$work/Garage.xcarchive"
chmod -R u+w "$work/Garage.xcarchive"
info="$work/Garage.xcarchive/Info.plist"
version="$(plutil -extract ApplicationProperties.CFBundleShortVersionString raw -o - "$info")"
build="$(plutil -extract ApplicationProperties.CFBundleVersion raw -o - "$info")"
echo "==> Garage $version (build $build) for the Mac App Store"

# Credentials come before the slow export, so a missing key fails at once.
if [[ "$mode" != "export" ]]; then
    key_id="${GARAGE_ASC_KEY_ID:-}" issuer_id="${GARAGE_ASC_ISSUER_ID:-}"
    mkdir -m 700 "$work/private_keys"
    if [[ -n "${GARAGE_ASC_KEY_PATH:-}" ]]; then
        [[ -n "$key_id" && -n "$issuer_id" ]] ||
            die "GARAGE_ASC_KEY_PATH needs GARAGE_ASC_KEY_ID and GARAGE_ASC_ISSUER_ID"
        cp "$GARAGE_ASC_KEY_PATH" "$work/private_keys/AuthKey_$key_id.p8"
    else
        attributes="$(security find-generic-password -s "$KEYCHAIN_SERVICE" 2>/dev/null)" ||
            die "no App Store Connect API key in the keychain; store it once with:
  security add-generic-password -U -s $KEYCHAIN_SERVICE -a <KEY ID> -j <ISSUER ID> -w \"\$(base64 < AuthKey_<KEY ID>.p8)\""
        [[ -n "$key_id" ]] || key_id="$(sed -n 's/^ *"acct"<blob>="\(.*\)"$/\1/p' <<<"$attributes")"
        [[ -n "$issuer_id" ]] || issuer_id="$(sed -n 's/^ *"icmt"<blob>="\(.*\)"$/\1/p' <<<"$attributes")"
        [[ -n "$key_id" && -n "$issuer_id" ]] ||
            die "the keychain item $KEYCHAIN_SERVICE needs the key ID as its account and the issuer ID as its comment"
        (umask 077 && security find-generic-password -s "$KEYCHAIN_SERVICE" -w |
            base64 --decode >"$work/private_keys/AuthKey_$key_id.p8") ||
            die "could not read the API key from the keychain item $KEYCHAIN_SERVICE"
    fi
    chmod 600 "$work/private_keys/AuthKey_$key_id.p8"
    # altool looks for AuthKey_<id>.p8 here before its default folders.
    export API_PRIVATE_KEYS_DIR="$work/private_keys"
fi

# 2. Install each profile under its UUID, where xcodebuild looks, and map bundle IDs to names.
profile_dirs=(
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    "$HOME/Library/MobileDevice/Provisioning Profiles"
)
mapping=()
for entry in "${profiles[@]}"; do
    bundle_id="${entry%%=*}" file="${entry#*=}"
    security cms -D -i "$file" >"$work/profile.plist" || die "cannot decode $file"
    name="$(plutil -extract Name raw -o - "$work/profile.plist")"
    uuid="$(plutil -extract UUID raw -o - "$work/profile.plist")"
    for dir in "${profile_dirs[@]}"; do
        mkdir -p "$dir"
        [[ -f "$dir/$uuid.provisionprofile" ]] || cp "$file" "$dir/$uuid.provisionprofile"
    done
    echo "    $bundle_id: $name ($uuid)"
    mapping+=("$bundle_id=$name")
done

# 3. Export. Bundle IDs contain dots, which plutil reads as key paths, so Python writes the plist.
/usr/bin/python3 - "$work/ExportOptions.plist" "$team" "$signing_identity" "$installer_identity" "${mapping[@]}" <<'EOF'
import plistlib, sys
out, team, identity, installer, *mapping = sys.argv[1:]
options = {
    "method": "app-store-connect",
    "destination": "export",
    "teamID": team,
    "signingStyle": "manual",
    "signingCertificate": identity,
    "installerSigningCertificate": installer,
    "provisioningProfiles": dict(m.split("=", 1) for m in mapping),
    "manageAppVersionAndBuildNumber": False,
}
with open(out, "wb") as f:
    plistlib.dump(options, f)
EOF
echo "==> Exporting (re-signs with $signing_identity; the keychain may ask to use its key)"
xcodebuild -exportArchive -archivePath "$work/Garage.xcarchive" -exportPath "$work/export" \
    -exportOptionsPlist "$work/ExportOptions.plist" || die "xcodebuild -exportArchive failed"
exported="$(find "$work/export" -maxdepth 1 -name '*.pkg' | head -n 1)"
[[ -n "$exported" ]] || die "the export produced no .pkg"
pkgutil --check-signature "$exported"

mkdir -p dist
pkg="dist/Garage-$version-$build-AppStore.pkg"
rm -f "$pkg"
cp "$exported" "$pkg"
if [[ "$mode" == "export" ]]; then
    echo
    echo "Exported $pkg (not validated or uploaded)."
    exit 0
fi

# 4. Validate, then upload. altool exits non-zero on a rejection and prints Apple's errors.
auth=(--apiKey "$key_id" --apiIssuer "$issuer_id")
echo "==> Validating with App Store Connect"
xcrun altool --validate-app -f "$pkg" -t macos "${auth[@]}" || die "App Store Connect rejected $pkg"
if [[ "$mode" == "validate" ]]; then
    echo
    echo "Garage $version (build $build) validated: $pkg (not uploaded)."
    exit 0
fi
echo "==> Uploading to App Store Connect"
xcrun altool --upload-app -f "$pkg" -t macos "${auth[@]}" || die "the upload of $pkg failed"

cat <<EOF

Garage $version (build $build) is uploaded: $pkg
It shows under TestFlight in App Store Connect once Apple has processed it.
EOF
