"""Transitioned xcarchive rules and macros.

The archive is assembled here rather than with rules_apple's `xcarchive`, which
unpacks the app with Python's zipfile: that writes symlinks out as plain files,
so a versioned framework (Python.framework's Versions/Current, Python and
Resources links) lost its signature in the archive while the same framework
in the .app was signed. `ditto` keeps symlinks, and the action verifies the
archived app's signature so a broken one fails the build, not the upload.
"""

load("@rules_apple//apple:providers.bzl", "AppleBundleInfo", "AppleDsymBundleInfo")

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

for dsym in "$@"; do
    ditto "$dsym" "$out/dSYMs/$(basename "$dsym")"
done

# App Store Connect asks for a dSYM matching the UUID of every Mach-O in the app. Bazel makes them
# for the Swift targets only; the rest (Postgres, ICU, Python, the extension modules) are built by
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
    dsym="$out/dSYMs/$(basename "$file").dSYM"
    n=1
    while [ -e "$dsym" ]; do n=$((n + 1)); dsym="$out/dSYMs/$(basename "$file")-$n.dSYM"; done
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

def _appstore_transition_impl(settings, attr):
    return {
        "//command_line_option:platforms": ["//bazel:store"],
        "//command_line_option:macos_cpus": ["arm64"],
    }

_appstore_transition = transition(
    implementation = _appstore_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:platforms",
        "//command_line_option:macos_cpus",
    ],
)

def _transition_archive_impl(ctx):
    target = ctx.attr.archive[0]
    providers = [target[DefaultInfo]]
    if OutputGroupInfo in target:
        providers.append(target[OutputGroupInfo])
    return providers

appstore_xcarchive_transition = rule(
    implementation = _transition_archive_impl,
    attrs = {
        "archive": attr.label(
            cfg = _appstore_transition,
            mandatory = True,
            doc = "The raw xcarchive target to build with appstore config.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Builds an xcarchive target with the --config=appstore transition.",
)

def appstore_xcarchive(name, bundle, **kwargs):
    """Creates an xcarchive target configured for App Store distribution via transition."""
    raw_name = "_" + name.replace(".", "_") + "_raw"
    _raw_xcarchive(
        name = raw_name,
        bundle = bundle,
        tags = ["manual"],
    )

    # Like the *_macos_application macros: the archive signs with the App Store
    # identity, which only a release machine has, so `//...` must not build it.
    tags = kwargs.pop("tags", [])
    if "manual" not in tags:
        tags = tags + ["manual"]
    appstore_xcarchive_transition(
        name = name,
        archive = ":" + raw_name,
        tags = tags,
        **kwargs
    )

def xcarchive(name, bundle, **kwargs):
    """Creates an xcarchive target (only supported for App Store configuration)."""
    appstore_xcarchive(name = name, bundle = bundle, **kwargs)
