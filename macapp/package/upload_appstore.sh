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
# App Manager) is read from the login keychain: the item the `asc` CLI saves for this Mac (account
# asc:credential:<LocalHostName>), or GARAGE_ASC_KEYCHAIN_ACCOUNT / _LABEL, or one stored with:
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
        # This script's own item, else the one the `asc` App Store Connect CLI saves for this Mac
        # (account "asc:credential:<LocalHostName>", IDs in its kind field as
        # asc:metadata:{"key_id":…,"issuer_id":…}), else one labelled "ASC API Key (<name>)".
        # GARAGE_ASC_KEYCHAIN_ACCOUNT or GARAGE_ASC_KEYCHAIN_LABEL names another.
        host="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
        if [[ -n "${GARAGE_ASC_KEYCHAIN_ACCOUNT:-}" ]]; then
            candidates=("-a|$GARAGE_ASC_KEYCHAIN_ACCOUNT")
        elif [[ -n "${GARAGE_ASC_KEYCHAIN_LABEL:-}" ]]; then
            candidates=("-l|$GARAGE_ASC_KEYCHAIN_LABEL")
        else
            candidates=("-s|$KEYCHAIN_SERVICE" "-a|asc:credential:$host" "-l|ASC API Key ($host)")
        fi
        item=() attributes=""
        for candidate in "${candidates[@]}"; do
            if attributes="$(security find-generic-password "${candidate%%|*}" "${candidate#*|}" 2>/dev/null)"; then
                item=("${candidate%%|*}" "${candidate#*|}")
                break
            fi
        done
        [[ ${#item[@]} -gt 0 ]] ||
            die "no App Store Connect API key in the keychain (looked for: ${candidates[*]}); store it once with:
  security add-generic-password -U -s $KEYCHAIN_SERVICE -a <KEY ID> -j <ISSUER ID> -w \"\$(base64 < AuthKey_<KEY ID>.p8)\""
        secret="$(security find-generic-password "${item[@]}" -w)" ||
            die "could not read the API key from the keychain item ${item[*]}"
        # The secret may be the .p8 itself, its base64, the hex `security` prints for multi-line
        # data, or JSON carrying the key and its IDs. The IDs come from the environment, then that
        # JSON or an asc:metadata: attribute, then the item's account (key ID) and comment (issuer ID).
        ids="$(umask 077 && KEY_ID="$key_id" ISSUER_ID="$issuer_id" SECRET="$secret" ATTRIBUTES="$attributes" \
            /usr/bin/python3 - "$work/private_keys" <<'EOF'
import base64, binascii, json, os, re, sys

secret = os.environ["SECRET"].strip()
fields = {}

def pem(text):
    return text if "PRIVATE KEY-----" in text else None

if re.fullmatch(r"[0-9a-fA-F]+", secret) and len(secret) % 2 == 0:
    secret = binascii.unhexlify(secret).decode("utf-8", "replace").strip()
key = None
if secret.startswith("{"):
    fields = {k.lower().replace("_", "").replace("-", ""): v for k, v in json.loads(secret).items() if isinstance(v, str)}
    key = next((pem(v) for v in fields.values() if pem(v)), None)
    if key is None:
        # Some tools keep the key file and store only its path.
        path = next((v for v in fields.values() if v.endswith(".p8") and os.path.isfile(os.path.expanduser(v))), None)
        key = pem(open(os.path.expanduser(path)).read()) if path else None
else:
    key = pem(secret)
if key is None:
    try:
        key = pem(base64.b64decode(secret, validate=True).decode("utf-8"))
    except (binascii.Error, UnicodeDecodeError):
        pass
if key is None:
    sys.exit("the keychain item holds no recognizable .p8 private key")

attrs = dict(re.findall(r'^\s*"(\w+)"<blob>="(.*)"$', os.environ["ATTRIBUTES"], re.M))
for value in attrs.values():
    if value.startswith("asc:metadata:"):
        meta = json.loads(value.removeprefix("asc:metadata:"))
        fields.update({k.lower().replace("_", "").replace("-", ""): v for k, v in meta.items() if isinstance(v, str)})
uuid = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
key_id = os.environ["KEY_ID"] or fields.get("keyid") or fields.get("apikey") or ""
if not key_id and re.fullmatch(r"[A-Z0-9]{4,}", attrs.get("acct", "")):
    key_id = attrs["acct"]
issuer = os.environ["ISSUER_ID"] or fields.get("issuerid") or fields.get("issuer") or ""
if not issuer:
    issuer = attrs.get("icmt", "")
if not issuer:
    issuer = next((m.group(0) for v in attrs.values() if (m := re.search(uuid, v))), "")
if not key_id or not issuer:
    sys.exit("found the key but not its key ID or issuer ID; set GARAGE_ASC_KEY_ID and GARAGE_ASC_ISSUER_ID")
with open(os.path.join(sys.argv[1], f"AuthKey_{key_id}.p8"), "w") as f:
    f.write(key.strip() + "\n")
print(key_id, issuer)
EOF
        )" || die "could not use the API key in the keychain item ${item[*]}"
        read -r key_id issuer_id <<<"$ids"
    fi
    chmod 600 "$work/private_keys/AuthKey_$key_id.p8"
    # altool looks for AuthKey_<id>.p8 here before its default folders.
    export API_PRIVATE_KEYS_DIR="$work/private_keys"
fi

# 2. Install each profile under its UUID, where xcodebuild looks, and map bundle IDs to UUIDs.
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
    # By UUID, not name: an older profile of the same name (for a previous distribution
    # certificate) left in the folder would otherwise be picked and fail the export.
    mapping+=("$bundle_id=$uuid")
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
