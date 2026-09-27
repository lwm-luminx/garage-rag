"""Rules for codesigning binaries and directories of binaries on macOS."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_apple//apple/internal:providers.bzl", "new_appleresourceinfo")
load("//bazel:codesign_test.bzl", _codesign_test = "codesign_test", _codesign_validation_test = "codesign_validation_test", _codesign_verify_test = "codesign_verify_test")
load("//bazel:signing.bzl", "DEVELOPER_ID_IDENTITY", "LOCAL_SIGNING_IDENTITY", "STORE_IDENTITY", "UNCHAINED_IDENTITIES")

codesign_test = _codesign_test
codesign_verify_test = _codesign_verify_test
codesign_validation_test = _codesign_validation_test

# Hardened runtime also turns on *library validation*: every Mach-O the process
# loads must carry the same Team ID as the main executable, and that Team ID has
# to come from an Apple-issued certificate. An ad-hoc signature carries no Team
# ID at all, and the self-signed local identity's is not Apple-issued, so
# neither can load its own bundled frameworks — `bazel run //macapp` dies in
# dyld with "mapping process and mapped file (non-platform) have different Team
# IDs".
#
# Hardened runtime is only *required* for notarization, so enable it for the
# signed distribution configs and leave it off for the local ones. The
# distribution configs sign everything with one Team ID, every extension module
# in site-python included, so validation passes there and neither ships
# com.apple.security.cs.disable-library-validation.
# tools/macos/trace_loaded_images.sh checks that at run time.
HARDENED_RUNTIME_CODESIGNOPTS = select({
    "//bazel:is_developer_id": ["--options=runtime"],
    "//bazel:is_store": ["--options=runtime"],
    "//conditions:default": [],
})

# The assertion side of the same rule: codesign_test defaults to requiring
# hardened runtime, which an ad-hoc build deliberately does not have. Pass this
# to a codesign_test whose subject is signed by either path so the expectation
# tracks the config instead of contradicting it.
HARDENED_RUNTIME_EXPECTED = select({
    "//bazel:is_developer_id": True,
    "//bazel:is_store": True,
    "//conditions:default": False,
})

# The identity a codesign_test should expect, mirroring the platforms in
# //bazel:BUILD.bazel. Pass this rather than re-listing the configs at each call
# site, so a new signing config only has to be taught to one select.
EXPECTED_SIGNING_IDENTITY = select({
    "//bazel:is_developer_id": DEVELOPER_ID_IDENTITY,
    "//bazel:is_local_signed": LOCAL_SIGNING_IDENTITY,
    "//bazel:is_store": STORE_IDENTITY,
    "//conditions:default": "-",
})

# Companion to the above for codesign_test's `is_store`, which turns on the
# Apple-Distribution-specific assertions.
STORE_EXPECTED = select({
    "//bazel:is_store": True,
    "//conditions:default": False,
})

def _without_hardened_runtime(codesign_args):
    """Drops the `runtime` flag from any --options= argument, keeping the rest."""
    kept = []
    for arg in codesign_args:
        if arg.startswith("--options="):
            flags = [f for f in arg[len("--options="):].split(",") if f and f != "runtime"]
            if flags:
                kept.append("--options=" + ",".join(flags))
        else:
            kept.append(arg)
    return kept

def _codesign_impl(ctx):
    if not ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo]):
        fail("{} only supports macOS targets".format(ctx.label))

    inputs = []
    if ctx.attr.src:
        inputs.extend(ctx.attr.src[DefaultInfo].files.to_list())
    elif ctx.attr.dep:
        inputs.extend(ctx.attr.dep[DefaultInfo].files.to_list())
    elif ctx.attr.srcs:
        for s in ctx.attr.srcs:
            inputs.extend(s[DefaultInfo].files.to_list())

    if not inputs:
        fail("{}: 'src', 'dep', or 'srcs' must be specified and non-empty".format(ctx.label))

    out_name = ctx.attr.out if ctx.attr.out else ctx.label.name
    is_dir = False
    if ctx.attr.src and ctx.attr.src[DefaultInfo].files_to_run and ctx.attr.src[DefaultInfo].files_to_run.executable:
        is_dir = False
    elif ctx.attr.dep and ctx.attr.dep[DefaultInfo].files_to_run and ctx.attr.dep[DefaultInfo].files_to_run.executable:
        is_dir = False
    elif ctx.attr.is_framework or out_name.endswith(".framework"):
        is_dir = True
    elif len(inputs) == 1:
        input_file = inputs[0]
        is_dir = input_file.is_directory
    else:
        is_dir = True

    if is_dir:
        output = ctx.actions.declare_directory(out_name)
    else:
        output = ctx.actions.declare_file(out_name)

    signing_identity = ctx.attr.sign if ctx.attr.sign else ctx.attr.signing_identity
    if not signing_identity or signing_identity == "-":
        if hasattr(ctx.attr, "_signing_certificate_name") and ctx.attr._signing_certificate_name:
            cert_from_setting = ctx.attr._signing_certificate_name[BuildSettingInfo].value
            if cert_from_setting:
                signing_identity = cert_from_setting
    if not signing_identity:
        signing_identity = "-"

    codesign_args = []
    if ctx.attr.codesignopts:
        codesign_args.extend(ctx.attr.codesignopts)
    if ctx.attr.options:
        for opt in ctx.attr.options:
            if opt.startswith("-"):
                codesign_args.append(opt)
            else:
                codesign_args.append("--options=" + opt)
    if not codesign_args:
        codesign_args.append("--options=runtime")

    # Hardened runtime implies library validation, and neither an ad-hoc
    # signature nor the self-signed local identity has an Apple-issued Team ID
    # for that to match against — so a binary signed either way cannot load its
    # own sibling dylibs ("different Team IDs" at dyld time). Callers ask for
    # hardened runtime because the *distribution* builds need it to notarize;
    # silently dropping it locally is what makes a locally built bundle
    # runnable. See HARDENED_RUNTIME_CODESIGNOPTS for the rules_apple side.
    if signing_identity in UNCHAINED_IDENTITIES:
        codesign_args = _without_hardened_runtime(codesign_args)

    extra_inputs = []
    default_entitlements_path = ""
    if ctx.file.entitlements:
        extra_inputs.append(ctx.file.entitlements)
        default_entitlements_path = ctx.file.entitlements.path

    entitlements_by_filename = {}
    for filename, entitlement in ctx.attr.entitlements_by_filename.items():
        entitlement_file = entitlement.files.to_list()[0]
        extra_inputs.append(entitlement_file)
        entitlements_by_filename[filename] = entitlement_file.path

    if ctx.attr.timestamp:
        codesign_args.append("--timestamp")

    dylibs_only = ctx.attr.dylibs_only or ctx.attr.dylib_only or ctx.attr.only_dylibs

    output_zip = None
    if ctx.attr.is_framework:
        output_zip = ctx.actions.declare_file(ctx.label.name + ".framework.zip")

    args = ctx.actions.args()
    args.add(output.path)
    args.add("dir" if is_dir else "file")
    args.add(signing_identity)
    args.add("1" if dylibs_only else "0")
    args.add(default_entitlements_path)
    args.add(output_zip.path if output_zip else "")
    args.add(str(len(entitlements_by_filename)))
    for filename, entitlement_path in entitlements_by_filename.items():
        args.add(filename)
        args.add(entitlement_path)
    args.add(str(len(codesign_args)))
    args.add_all(codesign_args)
    args.add(str(len(inputs)))
    for f in inputs:
        args.add(f.path)

    action_outputs = [output, output_zip] if output_zip else [output]

    ctx.actions.run_shell(
        inputs = inputs + extra_inputs,
        outputs = action_outputs,
        arguments = [args],
        execution_requirements = {
            "no-sandbox": "1",
        },
        command = """
set -euo pipefail

output="$1"
kind="$2"
signing_identity="$3"
dylibs_only="$4"
default_entitlements="$5"
output_zip="$6"
num_entitlements_by_filename="$7"
shift 7

entitlement_filenames=()
entitlement_paths=()
while [ "$num_entitlements_by_filename" -gt 0 ]; do
    entitlement_filenames+=("$1")
    entitlement_paths+=("$2")
    shift 2
    num_entitlements_by_filename=$((num_entitlements_by_filename - 1))
done

num_opts="$1"
shift 1

opts=()
while [ "$num_opts" -gt 0 ]; do
    opts+=("$1")
    shift
    num_opts=$((num_opts - 1))
done

num_inputs="$1"
shift 1

inputs=("$@")

signing_identity="${signing_identity#\\\"}"
signing_identity="${signing_identity%\\\"}"

fix_macho() {
    local file="$1"
    if [ -L "$file" ] || [ ! -f "$file" ]; then
        return
    fi
    if ! file -b "$file" | grep -q "Mach-O"; then
        return
    fi
    if file -b "$file" | grep -q "ar archive"; then
        return
    fi

    # Fix install name (ID) if needed
    local dylib_id
    dylib_id="$(otool -D "$file" 2>/dev/null | tail -n +2 | head -n 1 || true)"
    if [ -n "$dylib_id" ]; then
        if [[ "$dylib_id" == *"/Python.framework/"* ]] || [[ "$file" == *"/Python.framework/"* ]]; then
            /usr/bin/install_name_tool -id "@rpath/Python.framework/Versions/3.14/Python" "$file" 2>/dev/null || true
        elif [[ "$dylib_id" == /Users/* ]] || [[ "$dylib_id" == */_bazel* ]] || [[ "$dylib_id" == /sandbox/* ]] || [[ "$dylib_id" == ./* ]] || [[ "$dylib_id" == /* && "$dylib_id" != /usr/lib/* && "$dylib_id" != /System/* && "$dylib_id" != /Library/* ]]; then
            /usr/bin/install_name_tool -id "@rpath/$(basename "$file")" "$file" 2>/dev/null || true
        fi
    fi

    # Fix dependencies
    otool -L "$file" 2>/dev/null | tail -n +2 | while IFS= read -r line; do
        dep="${line#"${line%%[![:space:]]*}"}"
        dep="${dep%% *}"
        if [ -z "$dep" ]; then
            continue
        fi

        if [[ "$file" == *"/Python.framework/Versions/"*"/bin/"* ]] || [[ "$file" == *"/Python.framework/bin/"* ]] || [[ "$file" == *"/Versions/"*"/bin/"* ]] || [[ "$file" == *"/bin/python"* ]]; then
            if [[ "$dep" == *"/Python.framework/"* ]] || [[ "$dep" == "@rpath/Python"* ]] || [[ "$dep" == *"/Python" && "$dep" != "/usr/lib/"* && "$dep" != "/System/"* ]]; then
                /usr/bin/install_name_tool -change "$dep" "@executable_path/../Python" "$file" 2>/dev/null || true
            fi
        elif [[ "$dep" == *"/Python.framework/"* ]] && [[ "$dep" != "@rpath/Python.framework/"* ]]; then
            /usr/bin/install_name_tool -change "$dep" "@rpath/Python.framework/Versions/3.14/Python" "$file" 2>/dev/null || true
        elif [[ "$dep" == /DLC/* ]]; then
            /usr/bin/install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$file" 2>/dev/null || true
        elif [[ "$dep" == ./* ]]; then
            /usr/bin/install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$file" 2>/dev/null || true
        elif [[ "$dep" == /Users/* ]] || [[ "$dep" == */_bazel* ]] || [[ "$dep" == /sandbox/* ]]; then
            /usr/bin/install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$file" 2>/dev/null || true
        fi
    done

    # If it is inside Python.framework/Versions/.../bin
    if [[ "$file" == *"/Python.framework/Versions/"*"/bin/"* ]] || [[ "$file" == *"/Python.framework/bin/"* ]] || [[ "$file" == *"/Versions/"*"/bin/"* ]]; then
        /usr/bin/install_name_tool -add_rpath "@loader_path/.." "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@loader_path/../.." "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@loader_path/../../.." "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@loader_path/../../../.." "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@executable_path/.." "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@executable_path/../.." "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@executable_path/../../.." "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@executable_path/../../../.." "$file" 2>/dev/null || true
    fi

    if [[ "$file" == *".xpc/Contents/MacOS/"* ]]; then
        /usr/bin/install_name_tool -add_rpath "@loader_path/../Frameworks" "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@loader_path/../Frameworks/Python.framework" "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@loader_path/../../../../Frameworks" "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@loader_path/../../../../Frameworks/Python.framework" "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks/Python.framework" "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@executable_path/../../../../Frameworks" "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@executable_path/../../../../Frameworks/Python.framework" "$file" 2>/dev/null || true
    elif [[ "$file" == *".app/Contents/MacOS/"* ]] || [[ "$file" == *"/MacOS/"* ]]; then
        /usr/bin/install_name_tool -add_rpath "@loader_path/../Frameworks" "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@loader_path/../Frameworks/Python.framework" "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$file" 2>/dev/null || true
        /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks/Python.framework" "$file" 2>/dev/null || true
    fi
}

codesign_file() {
    local file="$1"
    local filename
    local entitlements
    local sign_opts

    filename="$(basename "$file")"
    entitlements="$default_entitlements"

    for i in "${!entitlement_filenames[@]}"; do
        if [ "$filename" = "${entitlement_filenames[$i]}" ]; then
            entitlements="${entitlement_paths[$i]}"
            break
        fi
    done

    sign_opts=(${opts[@]+"${opts[@]}"})
    if [ -n "$entitlements" ]; then
        sign_opts+=("--entitlements" "$entitlements")
    fi

    chmod 755 "$file" || echo "CHMOD FAILED ON $file"
    fix_macho "$file"
    /usr/bin/codesign -f -s "$signing_identity" ${sign_opts[@]+"${sign_opts[@]}"} "$file"
}

if [ "$kind" = "dir" ]; then
    rm -rf "$output"
    mkdir -p "$output"
    # If one of the inputs matches the output directory basename, copy only that input
    matched_input=""
    for input_path in "${inputs[@]}"; do
        if [ "$(basename "$input_path")" = "$(basename "$output")" ]; then
            matched_input="$input_path"
            break
        fi
    done

    if [ -n "$matched_input" ]; then
        if [ -d "$matched_input" ]; then
            tar -cf - -C "$matched_input" . | (cd "$output" && tar -xf -)
        elif [[ "$matched_input" == *.zip ]]; then
            tmp_unzip="$(mktemp -d)"
            /usr/bin/unzip -q -o "$matched_input" -d "$tmp_unzip"
            if [ -d "$tmp_unzip/$(basename "$output")" ]; then
                tar -cf - -C "$tmp_unzip/$(basename "$output")" . | (cd "$output" && tar -xf -)
            else
                tar -cf - -C "$tmp_unzip" . | (cd "$output" && tar -xf -)
            fi
            rm -rf "$tmp_unzip"
        else
            cp -P "$matched_input" "$output/"
        fi
    else
        for input_path in "${inputs[@]}"; do
            if [[ "$input_path" == *.zip ]]; then
                tmp_unzip="$(mktemp -d)"
                /usr/bin/unzip -q -o "$input_path" -d "$tmp_unzip"
                if [ -d "$tmp_unzip/$(basename "$output")" ]; then
                    tar -cf - -C "$tmp_unzip/$(basename "$output")" . | (cd "$output" && tar -xf -)
                else
                    tar -cf - -C "$tmp_unzip" . | (cd "$output" && tar -xf -)
                fi
                rm -rf "$tmp_unzip"
            elif [ -d "$input_path" ]; then
                if [[ "$input_path" == *.dSYM* ]]; then
                    continue
                fi
                if [ -d "$input_path/$(basename "$output")" ]; then
                    tar -cf - -C "$input_path/$(basename "$output")" . | (cd "$output" && tar -xf -)
                else
                    tar -cf - -C "$input_path" . | (cd "$output" && tar -xf -)
                fi
            else
                if [[ "$input_path" == *.dSYM* ]]; then
                    continue
                fi
                mkdir -p "$output/$(dirname "$input_path")"
                cp -P "$input_path" "$output/$input_path"
            fi
        done
    fi
    find "$output" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$output" -type f -exec chmod 755 {} + 2>/dev/null || true
    find "$output" -name "*.dSYM" -exec rm -rf {} + 2>/dev/null || true

    if [ -d "$output/Versions" ]; then
        rm -rf "$output/bin" "$output/bazel-out" "$output/Contents" "$output/Versions/Current" 2>/dev/null || true
        rm -rf "$output/Versions"/*/lib "$output/lib" 2>/dev/null || true
        find "$output" -name "*.dSYM" -exec rm -rf {} + 2>/dev/null || true
        find "$output" -name "*.app" -exec rm -rf {} + 2>/dev/null || true
        latest_ver="$(ls -1 "$output/Versions" | grep -v Current | tail -n 1)"
        if [ -n "$latest_ver" ]; then
            (cd "$output/Versions" && ln -sf "$latest_ver" Current)
        fi
        for link_target in Python Headers Resources; do
            if [ -e "$output/Versions/Current/$link_target" ]; then
                rm -rf "$output/$link_target"
                (cd "$output" && ln -sf "Versions/Current/$link_target" "$link_target")
            fi
        done
    fi

    # Remove site-python test directory and Python.framework lib directory if present before signing
    find "$output" -depth -type d \\( -name "test" -path "*/site-python/test" -o -name "test" -path "$output/test" \\) -exec rm -rf {} + 2>/dev/null || true
    find "$output" -depth -type d \\( -name "lib" -path "*/Python.framework/Versions/*/lib" -o -name "lib" -path "*/Python.framework/lib" \\) -exec rm -rf {} + 2>/dev/null || true

    # Ensure all regular files are independent writable copies (break hardlinks)
    for file in $(find "$output" -type f); do
        if [ ! -L "$file" ]; then
            chmod 755 "$file"
        fi
    done

    find "$output" -type f | while IFS= read -r file; do
        case "$file" in
            *.a|*.dSYM/*|*.dSYM) continue ;;
        esac
        if [ "$dylibs_only" = "1" ]; then
            filename="$(basename "$file")"
            case "$filename" in
                *.dylib|*.dylib.*) ;;
                *) continue ;;
            esac
        fi
        if file -b "$file" | grep -q "ar archive"; then
            continue
        fi
        if file -b "$file" | grep -q "Mach-O"; then
            codesign_file "$file"
        fi
    done

    if [ -d "$output/Versions" ]; then
        for ver_dir in "$output/Versions"/*; do
            if [ -d "$ver_dir" ] && [ ! -L "$ver_dir" ]; then
                if [ -f "$ver_dir/Python" ]; then
                    codesign_file "$ver_dir/Python"
                fi
                codesign_file "$ver_dir"
            fi
        done
        codesign_file "$output"
    elif [ -n "$output_zip" ] || [[ "$output" == *.framework ]]; then
        codesign_file "$output"
    fi

    if [ -n "$output_zip" ]; then
        abs_output_zip="$PWD/$output_zip"
        rm -f "$abs_output_zip"
        (cd "$(dirname "$output")" && zip -y -r -q -0 "$abs_output_zip" "$(basename "$output")")
    fi
else
    mkdir -p "$(dirname "$output")"
    cp -pL "${inputs[0]}" "$output"
    chmod u+w "$output" 2>/dev/null || true
    should_sign=1
    if [ "$dylibs_only" = "1" ]; then
        filename="$(basename "$output")"
        case "$filename" in
            *.dylib|*.dylib.*) ;;
            *) should_sign=0 ;;
        esac
    fi
    if [ "$should_sign" = "1" ] && file -b "$output" | grep -q "Mach-O"; then
        codesign_file "$output"
    fi
fi
""",
        mnemonic = "Codesign",
        progress_message = "Codesigning {}".format(ctx.label),
    )

    output_files = [output]
    default_info_kwargs = {
        "files": depset(output_files),
        "runfiles": ctx.runfiles(files = output_files),
    }
    if not is_dir:
        default_info_kwargs["executable"] = output

    providers = [DefaultInfo(**default_info_kwargs)]

    if ctx.attr.is_framework and output_zip:
        # rules_apple's default bundler unpacks a zip in the `framework` bucket into
        # Contents/Frameworks; its tree-artifact bundler copies the file as it is, which left a
        # `<name>.framework.zip` in Frameworks that then failed to sign. Hand that bundler the
        # signed framework directory instead.
        framework_resource = output if ctx.attr.framework_as_directory else output_zip
        resource_info = new_appleresourceinfo(
            framework = [
                (None, None, depset([framework_resource])),
            ],
            owners = depset([(framework_resource.short_path, str(ctx.label))]),
            unowned_resources = depset([]),
        )
        providers.append(resource_info)

    return providers

codesign = rule(
    implementation = _codesign_impl,
    attrs = {
        "codesignopts": attr.string_list(
            doc = "Extra options passed directly to codesign.",
        ),
        "dep": attr.label(
            doc = "Dependency to codesign (alias for src).",
        ),
        "dylib_only": attr.bool(
            default = False,
            doc = "Alias for dylibs_only.",
        ),
        "dylibs_only": attr.bool(
            default = False,
            doc = "Whether to only sign dynamic libraries (.dylib files).",
        ),
        "entitlements": attr.label(
            allow_single_file = True,
            doc = "Default entitlements plist file to embed.",
        ),
        "entitlements_by_filename": attr.string_keyed_label_dict(
            allow_files = True,
            doc = "Entitlements plist files to use for specific output basenames.",
        ),
        "framework_as_directory": attr.bool(
            default = False,
            doc = "With is_framework, give the bundle the signed framework directory rather than its zip. " +
                  "Set it under apple.experimental.tree_artifact_outputs=1 (//bazel:tree_artifact_outputs), " +
                  "whose bundler copies framework resources as-is instead of unpacking zips.",
        ),
        "is_framework": attr.bool(
            default = False,
            doc = "Whether this target is an Apple framework bundle to embed under Contents/Frameworks.",
        ),
        "only_dylibs": attr.bool(
            default = False,
            doc = "Alias for dylibs_only.",
        ),
        "options": attr.string_list(
            default = ["runtime"],
            doc = "Codesign options (e.g. ['runtime']). Defaults to ['runtime'].",
        ),
        "out": attr.string(
            doc = "Output file or directory name. Defaults to target name.",
        ),
        "parent_dir": attr.string(
            default = "",
            doc = "Subdirectory inside Contents/Resources to place this resource.",
        ),
        "sign": attr.string(
            doc = "Signing identity (alias for signing_identity).",
        ),
        "signing_identity": attr.string(
            default = "",
            doc = "Signing identity or certificate. Defaults to the active signing certificate build setting, or '-' for ad-hoc signing.",
        ),
        "src": attr.label(
            doc = "Source target or file to codesign.",
        ),
        "srcs": attr.label_list(
            doc = "Source targets or files to codesign.",
        ),
        "timestamp": attr.bool(
            default = False,
            doc = "Whether to request a timestamp authority signature.",
        ),
        "_macos_constraint": attr.label(
            default = Label("@platforms//os:macos"),
        ),
        "_signing_certificate_name": attr.label(
            default = Label("@rules_apple//apple/build_settings:signing_certificate_name"),
        ),
    },
    doc = "Codesigns Mach-O binaries and directories of binaries with specified options.",
)
