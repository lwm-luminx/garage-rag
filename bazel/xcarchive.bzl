"""An .xcarchive of the app built for a signed platform.

The archive is assembled here rather than with rules_apple's `xcarchive`, which
unpacks the app with Python's zipfile: that writes symlinks out as plain files,
so a versioned framework (Sparkle.framework's Versions/Current, Sparkle and
Resources links) lost its signature in the archive while the same framework
in the .app was signed. `ditto` keeps symlinks, and the action verifies the
archived app's signature so a broken one fails the build, not the upload.
"""

load("@rules_apple//apple:providers.bzl", "AppleBundleInfo", "AppleDsymBundleInfo")
load("//bazel:macos_application.bzl", "platform_transition")

_ASSEMBLE = """set -euo pipefail
bundle="$1"
out="$2"
shift 2
# The rest: the app's dSYM bundles (--apple_generate_dsym), for crash symbolication. Every other
# Mach-O in the app gets one from dsymutil below.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -d "$bundle" ]; then
    ditto "$bundle" "$work/$(basename "$bundle")"
else
    ditto -x -k "$bundle" "$work"
fi
app="$(find "$work" -maxdepth 2 -type d -name '*.app' | head -n 1)"
if [ -z "$app" ]; then
    echo "xcarchive: no .app inside $bundle" >&2
    exit 1
fi

name="$(basename "$app")"
mkdir -p "$out/Products/Applications" "$out/dSYMs"
ditto "$app" "$out/Products/Applications/$name"
archived="$out/Products/Applications/$name"

if ! codesign --verify --deep --strict --verbose=2 "$archived"; then
    echo "xcarchive: $name is not validly signed inside the archive" >&2
    exit 1
fi

# A dSYM's name does not matter (tools match by UUID), but two can differ only in case
# (Garage.app.dSYM, the helper's garage.app.dSYM), which a case-insensitive volume would merge into
# one; the second gets a suffix. cp -L copies the DWARF files Bazel links from its cache, so the
# archive keeps them when it is moved or the cache is cleaned.
unique_dsym_path() {
    local base="$1" candidate n=1
    candidate="$out/dSYMs/$base"
    while [ -e "$candidate" ] || [ -n "$(find "$out/dSYMs" -maxdepth 1 -iname "$(basename "$candidate")" -print -quit)" ]; do
        n=$((n + 1))
        candidate="$out/dSYMs/${base%.dSYM}-$n.dSYM"
    done
    printf '%s\n' "$candidate"
}
for dsym in "$@"; do
    cp -RL "$dsym" "$(unique_dsym_path "$(basename "$dsym")")"
done

# App Store Connect asks for a dSYM matching the UUID of every Mach-O in the app. Bazel makes them
# for the Swift targets only; the rest (Postgres, ICU, the Rust libraries) are built by
# their own build systems, so dsymutil makes one here from whatever debug information the binary
# keeps. Symlinks and binaries whose UUIDs already have a dSYM are skipped.
known="$work/uuids"
: >"$known"
for dsym in "$out"/dSYMs/*.dSYM; do
    [ -d "$dsym" ] && dwarfdump --uuid "$dsym" | awk '{print $2}' >>"$known"
done
find "$archived" -type f -print0 | while IFS= read -r -d '' file; do
    case "$(file -b "$file")" in *Mach-O*) ;; *) continue ;; esac
    uuids="$(dwarfdump --uuid "$file" 2>/dev/null | awk '{print $2}')"
    [ -n "$uuids" ] || continue
    missing=0
    for uuid in $uuids; do grep -qx "$uuid" "$known" || missing=1; done
    [ "$missing" = 1 ] || continue
    dsym="$(unique_dsym_path "$(basename "$file").dSYM")"
    if dsymutil --quiet "$file" -o "$dsym" 2>/dev/null; then
        printf '%s\n' $uuids >>"$known"
    else
        echo "xcarchive: no dSYM for ${file#$archived/}" >&2
        rm -rf "$dsym"
    fi
done

plist="$archived/Contents/Info.plist"
read_key() { plutil -extract "$1" raw -o - "$plist" 2>/dev/null || true; }
details="$(codesign -dvv "$archived" 2>&1)"
identity="$(printf '%s\\n' "$details" | sed -n 's/^Authority=//p' | head -n 1)"
team="$(printf '%s\\n' "$details" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
executable="$archived/Contents/MacOS/$(read_key CFBundleExecutable)"
info="$out/Info.plist"
plutil -create xml1 "$info"
plutil -insert ArchiveVersion -integer 2 "$info"
plutil -insert CreationDate -date "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$info"
plutil -insert Name -string "${name%.app}" "$info"
plutil -insert SchemeName -string "${name%.app}" "$info"
plutil -insert ApplicationProperties -dictionary "$info"
plutil -insert ApplicationProperties.ApplicationPath -string "Applications/$name" "$info"
plutil -insert ApplicationProperties.CFBundleIdentifier -string "$(read_key CFBundleIdentifier)" "$info"
plutil -insert ApplicationProperties.CFBundleShortVersionString -string "$(read_key CFBundleShortVersionString)" "$info"
plutil -insert ApplicationProperties.CFBundleVersion -string "$(read_key CFBundleVersion)" "$info"
plutil -insert ApplicationProperties.SigningIdentity -string "$identity" "$info"
if [ -n "$team" ] && [ "$team" != "not set" ]; then
    plutil -insert ApplicationProperties.Team -string "$team" "$info"
fi
plutil -insert ApplicationProperties.Architectures -array "$info"
for arch in $(lipo -archs "$executable"); do
    plutil -insert ApplicationProperties.Architectures -string "$arch" -append "$info"
done
"""

def _signed_xcarchive_impl(ctx):
    info = ctx.attr.bundle[AppleBundleInfo]
    dsyms = ctx.attr.bundle[AppleDsymBundleInfo].transitive_dsyms if AppleDsymBundleInfo in ctx.attr.bundle else depset()
    out = ctx.actions.declare_directory(ctx.label.name + "/" + info.bundle_name + ".xcarchive")
    args = ctx.actions.args()
    args.add(info.archive)
    args.add(out.path)
    args.add_all(dsyms, expand_directories = False)
    ctx.actions.run_shell(
        inputs = depset([info.archive], transitive = [dsyms]),
        outputs = [out],
        arguments = [args],
        command = _ASSEMBLE,
        mnemonic = "XcarchiveAssemble",
        progress_message = "Assembling %s.xcarchive" % info.bundle_name,
        # ditto, codesign, lipo and plutil are macOS tools.
        execution_requirements = {"no-remote": "1", "requires-darwin": "1"},
    )
    return [DefaultInfo(files = depset([out]))]

_raw_xcarchive = rule(
    implementation = _signed_xcarchive_impl,
    attrs = {
        "bundle": attr.label(
            mandatory = True,
            providers = [AppleBundleInfo],
            doc = "The signed macos_application to archive.",
        ),
    },
    doc = "An .xcarchive of a signed app, assembled with ditto so framework symlinks and signatures survive.",
)

def _transition_archive_impl(ctx):
    target = ctx.attr.archive[0]
    providers = [target[DefaultInfo]]
    if OutputGroupInfo in target:
        providers.append(target[OutputGroupInfo])
    return providers

_platform_xcarchive = rule(
    implementation = _transition_archive_impl,
    attrs = {
        "archive": attr.label(
            cfg = platform_transition,
            mandatory = True,
            doc = "The raw xcarchive target to build for `platform`.",
        ),
        "platform": attr.label(
            mandatory = True,
            doc = "The platform to build it for (//bazel:platforms.bzl).",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Builds an xcarchive for the given platform.",
)

def platform_xcarchive(name, bundle, platform, **kwargs):
    """An .xcarchive of `bundle` built for `platform`, as the App Store upload takes it.

    Args:
        name: The target name.
        bundle: The signed `macos_application` to archive.
        platform: The platform to build it for, which signs with a distribution identity that
            only a release machine has, so the target is `manual` and `//...` never builds it.
        **kwargs: Passed to the rule (`visibility`, `tags`).
    """
    raw_name = "_" + name.replace(".", "_") + "_raw"
    _raw_xcarchive(
        name = raw_name,
        bundle = bundle,
        tags = ["manual"],
    )
    tags = kwargs.pop("tags", [])
    if "manual" not in tags:
        tags = tags + ["manual"]
    _platform_xcarchive(
        name = name,
        archive = ":" + raw_name,
        platform = platform,
        tags = tags,
        **kwargs
    )
