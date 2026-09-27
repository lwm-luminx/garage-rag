#!/usr/bin/env bash
# Adds a signed Sparkle entry for one Developer ID release to docs/appcast.xml.
#
#   aspect run //macapp/package:publish_appcast -- v1.5 [--notes notes.md]
#   aspect run //macapp/package:publish_appcast -- --check-live
#
# The first form takes the stapled dist/Garage-<version>.zip that notarize_all wrote, checks it
# (version matches the tag, notarized, arm64 only, newer than every entry already in the
# feed, and the Keychain's EdDSA key is the one the shipped app trusts), runs Sparkle's
# generate_appcast over it, verifies the entry it wrote, and leaves:
#   - docs/appcast.xml with the new entry, to commit;
#   - dist/Garage-<version>.zip, the exact archive the entry signs, to upload to the release.
#
# The second form fetches the feed from its SUFeedURL and checks that every enclosure is
# a download that exists, which is the last step before announcing a release.
#
# The private key never leaves the login Keychain: generate_appcast and sign_update read it
# there. See macapp/README.md ("Cutting a release") for the whole flow.
set -euo pipefail

readonly REPO_DOWNLOADS="https://github.com/rickmark/garage-rag/releases/download"

die() {
    echo "publish_appcast: $*" >&2
    exit 1
}

usage() {
    sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

archive="" generate_appcast="" sign_update="" generate_keys="" sparkle_plist=""
tag="" notes="" check_live=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive) archive="$2"; shift 2 ;;
        --generate-appcast) generate_appcast="$2"; shift 2 ;;
        --sign-update) sign_update="$2"; shift 2 ;;
        --generate-keys) generate_keys="$2"; shift 2 ;;
        --sparkle-plist) sparkle_plist="$2"; shift 2 ;;
        --notes) notes="$2"; shift 2 ;;
        --check-live) check_live=1; shift ;;
        -h | --help) usage ;;
        -*) die "unknown option $1" ;;
        *) [[ -z "$tag" ]] || usage; tag="$1"; shift ;;
    esac
done

[[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]] || die "run this with 'aspect run //macapp/package:publish_appcast'"
for f in "$archive" "$generate_appcast" "$sign_update" "$generate_keys" "$sparkle_plist"; do
    [[ -e "$f" ]] || die "missing runfile '$f'"
done
# Resolve the runfiles before leaving the runfiles directory.
archive="$(cd "$(dirname "$archive")" && pwd -P)/$(basename "$archive")"
generate_appcast="$(cd "$(dirname "$generate_appcast")" && pwd -P)/$(basename "$generate_appcast")"
sign_update="$(cd "$(dirname "$sign_update")" && pwd -P)/$(basename "$sign_update")"
generate_keys="$(cd "$(dirname "$generate_keys")" && pwd -P)/$(basename "$generate_keys")"
sparkle_plist="$(cd "$(dirname "$sparkle_plist")" && pwd -P)/$(basename "$sparkle_plist")"
cd "$BUILD_WORKSPACE_DIRECTORY"
feed="docs/appcast.xml"

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }

if [[ "$check_live" == 1 ]]; then
    feed_url="$(plist_value "$sparkle_plist" SUFeedURL)"
    echo "==> Fetching $feed_url"
    live="$(mktemp)"
    trap 'rm -f "$live"' EXIT
    curl -fsSL --proto '=https' -o "$live" "$feed_url" || die "could not fetch $feed_url"
    cmp -s "$live" "$feed" || echo "warning: the served feed differs from $feed (Pages may still be deploying)" >&2
    urls="$(/usr/bin/python3 - "$live" <<'PY'
import sys
import xml.etree.ElementTree as ET
for enclosure in ET.parse(sys.argv[1]).getroot().iter("enclosure"):
    print(enclosure.get("url", ""))
PY
)"
    [[ -n "$urls" ]] || die "the served feed has no entries"
    status=0
    while IFS= read -r url; do
        if curl -fsSLI --proto '=https' -o /dev/null "$url"; then
            echo "ok       $url"
        else
            echo "MISSING  $url" >&2
            status=1
        fi
    done <<<"$urls"
    exit "$status"
fi

[[ -n "$tag" ]] || usage
[[ -z "$notes" || -f "$notes" ]] || die "no release notes at $notes"
[[ -f "$feed" ]] || die "no $feed in $BUILD_WORKSPACE_DIRECTORY"

work="$(mktemp -d "${TMPDIR:-/tmp}/garage-appcast.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# 1. What is being released: the stapled archive notarize_all left in dist/, which has to be
#    the build bazel-bin holds now, not one left over from an earlier release.
/usr/bin/unzip -p "$archive" Garage.app/Contents/Info.plist >"$work/built-Info.plist" ||
    die "$archive does not contain Garage.app"
built_short="$(plist_value "$work/built-Info.plist" CFBundleShortVersionString)"
built_build="$(plist_value "$work/built-Info.plist" CFBundleVersion)"
archive="$PWD/dist/Garage-$built_short.zip"
[[ -f "$archive" ]] || die "no $archive; run 'aspect run //macapp/package:notarize_all' first"
mkdir "$work/unpacked"
/usr/bin/ditto -x -k "$archive" "$work/unpacked"
app="$work/unpacked/Garage.app"
[[ -d "$app" ]] || die "$archive does not contain Garage.app"
short="$(plist_value "$app/Contents/Info.plist" CFBundleShortVersionString)"
build="$(plist_value "$app/Contents/Info.plist" CFBundleVersion)"
echo "==> Garage $short (build $build)"
[[ "$tag" == "v$short" ]] || die "tag $tag does not match the archive's version $short (expected v$short)"
[[ "$build" == "$built_build" ]] ||
    die "$archive is build $build, but bazel-bin holds build $built_build; run 'aspect run //macapp/package:notarize_all' again"
[[ "$build" =~ ^[0-9]+$ ]] || die "CFBundleVersion '$build' is not a build number; was the build stamped?"
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$app/Contents/Info.plist" >/dev/null 2>&1 ||
    die "the archive has no SUFeedURL; it is not a Developer ID build"

# 2. It must be the notarized, arm64-only Developer ID build.
archs="$(/usr/bin/lipo -archs "$app/Contents/MacOS/Garage")"
[[ "$archs" == "arm64" ]] || die "Garage.app is built for '$archs'; releases are arm64 only"
assessment="$(/usr/sbin/spctl --assess --type execute -vv "$app" 2>&1 || true)"
grep -q "source=Notarized Developer ID" <<<"$assessment" ||
    die "Garage.app is not notarized (run 'aspect run //macapp/package:notarize_all' first):
$assessment"
/usr/bin/xcrun stapler validate "$app" >/dev/null ||
    die "Garage.app has no stapled ticket (run 'aspect run //macapp/package:notarize_all' first)"

# 3. The new build must be newer than every entry already published, since Sparkle
#    compares CFBundleVersion, not the marketing version.
newest="$(/usr/bin/python3 - "$feed" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
versions = [0]
for item in ET.parse(sys.argv[1]).getroot().iter("item"):
    for el in [item.find(ns + "version"), item.find("enclosure")]:
        if el is not None:
            v = el.text if el.tag == ns + "version" else el.get(ns + "version")
            if v and v.strip().isdigit():
                versions.append(int(v.strip()))
print(max(versions))
PY
)"
((build > newest)) || die "build $build is not newer than build $newest, already in $feed"

# 4. The Keychain key must be the one the shipped app verifies against.
trusted="$(plist_value "$sparkle_plist" SUPublicEDKey)"
keychain_public="$("$generate_keys" -p)" || die "no Sparkle EdDSA key in the login Keychain"
[[ "$keychain_public" == "$trusted" ]] ||
    die "the Keychain's EdDSA public key ($keychain_public) is not SUPublicEDKey ($trusted); updates signed with it would be rejected"

# 5. Generate the entry.
name="Garage-$short"
cp "$archive" "$work/$name.zip"
cp "$feed" "$work/appcast.xml"
embed=()
if [[ -n "$notes" ]]; then
    cp "$notes" "$work/$name.${notes##*.}"
    embed=(--embed-release-notes)
fi
rm -rf "$work/unpacked"
echo "==> Signing the entry (macOS may ask to allow Keychain access)"
"$generate_appcast" --download-url-prefix "$REPO_DOWNLOADS/$tag/" "${embed[@]+"${embed[@]}"}" "$work"

# 6. Check what generate_appcast wrote before it replaces the committed feed.
signature="$(/usr/bin/python3 - "$work/appcast.xml" "$build" "$REPO_DOWNLOADS/$tag/$name.zip" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
path, build, url = sys.argv[1:]
for item in ET.parse(path).getroot().iter("item"):
    version = item.findtext(ns + "version") or item.find("enclosure").get(ns + "version")
    if (version or "").strip() != build:
        continue
    enclosure = item.find("enclosure")
    problems = []
    if enclosure.get("url") != url:
        problems.append(f"enclosure url is {enclosure.get('url')}, expected {url}")
    if not enclosure.get(ns + "edSignature"):
        problems.append("enclosure has no sparkle:edSignature")
    if "arm64" not in (item.findtext(ns + "hardwareRequirements") or ""):
        problems.append("entry has no sparkle:hardwareRequirements arm64, so Intel Macs would be offered it")
    if problems:
        sys.exit("generated entry is wrong: " + "; ".join(problems))
    print(enclosure.get(ns + "edSignature"))
    break
else:
    sys.exit(f"generate_appcast wrote no entry for build {build}")
PY
)" || die "not publishing"
"$sign_update" --verify "$work/$name.zip" "$signature" >/dev/null ||
    die "the entry's signature does not verify against the archive"

# 7. Hand over the feed and the archive.
cp "$work/appcast.xml" "$feed"
mkdir -p dist
cp "$work/$name.zip" "dist/$name.zip"

cat <<EOF

Wrote $feed and dist/$name.zip. Publish them in this order, so the feed never names a
download that does not exist yet:

  gh release upload $tag dist/$name.zip
  git add $feed && git commit -S -m "Add Garage $short to the appcast" && git push
  # once GitHub Pages has deployed:
  aspect run //macapp/package:publish_appcast -- --check-live
EOF
