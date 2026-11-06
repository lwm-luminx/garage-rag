"""Bazel test rules for verifying codesign signatures, hardened runtime, and identities."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def _codesign_test_impl(ctx):
    if not ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo]):
        fail("{} only supports macOS targets".format(ctx.label))

    inputs = []
    if ctx.attr.src:
        inputs.extend(ctx.attr.src[DefaultInfo].files.to_list())
    elif ctx.attr.app:
        inputs.extend(ctx.attr.app[DefaultInfo].files.to_list())
    elif ctx.attr.bundle:
        inputs.extend(ctx.attr.bundle[DefaultInfo].files.to_list())
    elif ctx.attr.binary:
        inputs.extend(ctx.attr.binary[DefaultInfo].files.to_list())
    elif ctx.attr.target:
        inputs.extend(ctx.attr.target[DefaultInfo].files.to_list())
    elif ctx.attr.dep:
        inputs.extend(ctx.attr.dep[DefaultInfo].files.to_list())
    elif ctx.attr.srcs:
        for s in ctx.attr.srcs:
            inputs.extend(s[DefaultInfo].files.to_list())

    if not inputs:
        fail("{}: 'src', 'app', 'bundle', 'binary', 'target', 'dep', or 'srcs' must be specified".format(ctx.label))

    test_script = ctx.actions.declare_file(ctx.label.name + "_test.sh")

    signing_identity = ctx.attr.sign if ctx.attr.sign else ctx.attr.signing_identity
    if not signing_identity:
        if hasattr(ctx.attr, "_signing_certificate_name") and ctx.attr._signing_certificate_name:
            cert_from_setting = ctx.attr._signing_certificate_name[BuildSettingInfo].value
            if cert_from_setting:
                signing_identity = cert_from_setting

    is_store_str = "1" if ctx.attr.is_store else "0"
    hardened_runtime_str = "1" if ctx.attr.hardened_runtime else "0"
    deep_verify_str = "1" if ctx.attr.deep_verify else "0"
    exclude_patterns = ctx.attr.exclude_patterns

    excludes_str = "\n".join(['    "{}"'.format(e) for e in exclude_patterns])
    inputs_str = "\n".join(['    "{}"'.format(f.short_path) for f in inputs])

    script_content = """#!/bin/bash
set -euo pipefail

signing_identity="{signing_identity}"
is_store="{is_store}"
hardened_runtime="{hardened_runtime}"
deep_verify="{deep_verify}"

# Strip outer quotes from signing_identity
signing_identity="${{signing_identity#\\\"}}"
signing_identity="${{signing_identity%\\\"}}"

exclude_patterns=(
{excludes}
)

input_short_paths=(
{inputs}
)

resolve_rlocation() {{
    local sp="$1"
    local path=""
    if [ -n "${{RUNFILES_DIR:-}}" ] && [ -e "${{RUNFILES_DIR}}/_main/${{sp}}" ]; then
        path="${{RUNFILES_DIR}}/_main/${{sp}}"
    elif [ -n "${{RUNFILES_DIR:-}}" ] && [ -e "${{RUNFILES_DIR}}/${{sp}}" ]; then
        path="${{RUNFILES_DIR}}/${{sp}}"
    elif [ -n "${{RUNFILES_MANIFEST_FILE:-}}" ]; then
        path="$(grep -m 1 "^_main/${{sp}} " "${{RUNFILES_MANIFEST_FILE}}" 2>/dev/null | cut -d' ' -f2- || true)"
        if [ -z "$path" ] || [ ! -e "$path" ]; then
            path="$(grep -m 1 "^${{sp}} " "${{RUNFILES_MANIFEST_FILE}}" 2>/dev/null | cut -d' ' -f2- || true)"
        fi
    fi

    if [ -z "$path" ] || [ ! -e "$path" ]; then
        if [ -e "${{0}}.runfiles/_main/${{sp}}" ]; then
            path="${{0}}.runfiles/_main/${{sp}}"
        elif [ -e "${{0}}.runfiles/${{sp}}" ]; then
            path="${{0}}.runfiles/${{sp}}"
        elif [ -e "${{sp}}" ]; then
            path="${{sp}}"
        fi
    fi
    echo "$path"
}}

TMP_DIR="$(mktemp -d "${{TMPDIR:-/tmp}}/codesign_test.XXXXXX")"
trap 'chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT

resolved_inputs=()
for sp in "${{input_short_paths[@]}}"; do
    res="$(resolve_rlocation "$sp")"
    if [ -z "$res" ] || [ ! -e "$res" ]; then
        echo "Error: Could not locate input file: $sp in runfiles" >&2
        exit 1
    fi
    resolved_inputs+=("$res")
done

STAGE_DIR="$TMP_DIR/stage"
mkdir -p "$STAGE_DIR"

for item in "${{resolved_inputs[@]}}"; do
    if [ -d "$item" ]; then
        mkdir -p "$STAGE_DIR/$(basename "$item")"
        # Keep symlinks (no -h): a versioned framework's Versions/Current, top-level
        # binary and Resources are links, and flattening them makes codesign call the
        # bundle "ambiguous" and fail a correctly signed framework.
        tar -cf - -C "$item" . | (cd "$STAGE_DIR/$(basename "$item")" && tar -xf -)
    elif [[ "$item" == *.zip ]]; then
        /usr/bin/unzip -q -o "$item" -d "$STAGE_DIR"
    else
        cp "$item" "$STAGE_DIR/"
    fi
done

# The framework's own links are relative and must stay links. Runfiles can also
# reach the real files through absolute symlinks, which tar kept as links: left
# alone they point back into the runfiles tree (codesign then reports "Too many
# levels of symbolic links") and no staged file is a regular file to check. Those
# are replaced by copies of what they point to.
while IFS= read -r link; do
    target="$(readlink "$link")"
    case "$target" in
        /*)
            rm "$link"
            cp -RL "$target" "$link"
            ;;
    esac
done < <(find "$STAGE_DIR" -type l)

# Put back a versioned framework's links. The darwin sandbox hands a tree artifact
# over with them resolved (Versions/Current a real copy of the version, top-level
# Python/Resources/Headers copies too), and codesign rejects that layout as an
# ambiguous bundle. Rebuild Versions/Current -> <version> and each top-level entry
# -> Versions/Current/<entry>; outside the sandbox this recreates the same links.
while IFS= read -r fw; do
    versions="$fw/Versions"
    [ -d "$versions" ] || continue
    version=""
    if [ -L "$versions/Current" ]; then
        version="$(readlink "$versions/Current")"
    else
        candidates=()
        for d in "$versions"/*/; do
            n="$(basename "$d")"
            [ "$n" = "Current" ] || candidates+=("$n")
        done
        if [ "${{#candidates[@]}}" -eq 1 ]; then
            version="${{candidates[0]}}"
        fi
    fi
    [ -n "$version" ] && [ -d "$versions/$version" ] || continue
    rm -rf "$versions/Current"
    ln -s "$version" "$versions/Current"
    for entry in "$versions/$version"/*; do
        top="$fw/$(basename "$entry")"
        if [ -e "$top" ] || [ -L "$top" ]; then
            rm -rf "$top"
            ln -s "Versions/Current/$(basename "$entry")" "$top"
        fi
    done
done < <(find "$STAGE_DIR" -maxdepth 3 -type d -name "*.framework")

should_exclude() {{
    local file_path="$1"
    for pat in "${{exclude_patterns[@]+"${{exclude_patterns[@]}}"}}"; do
        if [ -n "$pat" ] && [[ "$file_path" == *"$pat"* ]]; then
            return 0
        fi
    done
    return 1
}}

echo "============================================================"
echo "Codesign Verification Test"
echo "Expected signing identity: ${{signing_identity:-<any valid>}}"
echo "Store distribution:        $([ "$is_store" = "1" ] && echo "YES" || echo "NO")"
echo "Hardened runtime required: $([ "$hardened_runtime" = "1" ] && echo "YES" || echo "NO")"
echo "============================================================"

total_checked=0
failed_count=0
bundle_failed_count=0

# Verify any top-level bundles
if [ "$deep_verify" = "1" ]; then
    while IFS= read -r bundle_path; do
        [ -d "$bundle_path" ] || continue
        case "$bundle_path" in
            *.dSYM/*|*.dSYM) continue ;;
        esac
        rel_bundle="${{bundle_path#$STAGE_DIR/}}"
        echo "Verifying bundle: $rel_bundle"
        if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle_path" 2>&1; then
            echo "[FAIL] Bundle verification failed: $rel_bundle"
            bundle_failed_count=$((bundle_failed_count + 1))
        else
            echo "[PASS] Bundle valid: $rel_bundle"
        fi
    done < <(find "$STAGE_DIR" -maxdepth 3 -type d \\( -name "*.app" -o -name "*.framework" -o -name "*.xpc" \\))
fi

# Verify each Mach-O binary
while IFS= read -r f; do
    [ -f "$f" ] || continue
    [ ! -L "$f" ] || continue

    case "$f" in
        *.dSYM/*|*.dSYM|*.a|*.o) continue ;;
    esac

    if should_exclude "$f"; then
        continue
    fi

    file_type="$(file -b "$f" 2>/dev/null || true)"
    case "$file_type" in
        *"Mach-O"*)
            case "$file_type" in
                *"object"*) continue ;;
            esac
            total_checked=$((total_checked + 1))
            rel_name="${{f#$STAGE_DIR/}}"
            bin_failed=0

            # 1. Basic codesign verification
            if ! /usr/bin/codesign --verify --strict "$f" 2>&1; then
                echo "[FAIL] $rel_name: codesign verification failed"
                bin_failed=1
            fi

            # 2. Extract codesign details
            cs_out="$(/usr/bin/codesign -dvvv "$f" 2>&1 || true)"

            # 3. Verify Hardened Runtime
            if [ "$hardened_runtime" = "1" ]; then
                if ! echo "$cs_out" | grep -q -E "flags=.*runtime"; then
                    echo "[FAIL] $rel_name: hardened runtime NOT enabled"
                    echo "       Codesign flags: $(echo "$cs_out" | grep "flags=" || echo "none")"
                    bin_failed=1
                fi
            fi

            # 4. Verify Signing Identity if specified
            if [ -n "$signing_identity" ]; then
                if [ "$signing_identity" = "-" ]; then
                    if ! echo "$cs_out" | grep -q -E "(Signature=adhoc|flags=0x2\\\\(adhoc\\\\))"; then
                        echo "[FAIL] $rel_name: signature is not ad-hoc (expected ad-hoc '-')"
                        bin_failed=1
                    fi
                else
                    if ! echo "$cs_out" | grep -q -F "$signing_identity"; then
                        echo "[FAIL] $rel_name: signing identity mismatch"
                        echo "       Expected identity: $signing_identity"
                        echo "       Actual details:"
                        echo "$cs_out" | grep -E "(Authority|Signature|TeamIdentifier|Identifier)" | sed 's/^/         /'
                        bin_failed=1
                    fi
                fi
            fi

            # 5. Store-specific verification
            if [ "$is_store" = "1" ]; then
                if [ -z "$signing_identity" ]; then
                    if ! echo "$cs_out" | grep -q -E "^Authority=(Apple Development|Apple Distribution|3rd Party Mac Developer Application)"; then
                        echo "[FAIL] $rel_name: store binary not signed with an Apple Development or Apple Distribution certificate"
                        bin_failed=1
                    fi
                fi
            fi

            if [ "$bin_failed" -eq 1 ]; then
                failed_count=$((failed_count + 1))
            else
                echo "[PASS] $rel_name"
            fi
            ;;
    esac
done < <(find "$STAGE_DIR" -type f)

echo "============================================================"
echo "Checked $total_checked Mach-O binaries: $((total_checked - failed_count)) passed, $failed_count failed"
if [ "$bundle_failed_count" -gt 0 ]; then
    echo "Bundles: $bundle_failed_count failed verification"
fi
echo "============================================================"

if [ "$total_checked" -eq 0 ]; then
    echo "Error: No Mach-O binaries were found in target inputs" >&2
    exit 1
fi

if [ "$failed_count" -gt 0 ] || [ "$bundle_failed_count" -gt 0 ]; then
    exit 1
fi

exit 0
""".format(
        signing_identity = signing_identity,
        is_store = is_store_str,
        hardened_runtime = hardened_runtime_str,
        deep_verify = deep_verify_str,
        excludes = excludes_str,
        inputs = inputs_str,
    )

    ctx.actions.write(
        output = test_script,
        content = script_content,
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = inputs)
    if ctx.attr.src:
        runfiles = runfiles.merge(ctx.attr.src[DefaultInfo].default_runfiles)
    elif ctx.attr.app:
        runfiles = runfiles.merge(ctx.attr.app[DefaultInfo].default_runfiles)
    elif ctx.attr.dep:
        runfiles = runfiles.merge(ctx.attr.dep[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            executable = test_script,
            runfiles = runfiles,
        ),
    ]

codesign_test = rule(
    implementation = _codesign_test_impl,
    test = True,
    attrs = {
        "app": attr.label(
            doc = "Application target to verify codesign for (alias for src).",
        ),
        "binary": attr.label(
            doc = "Binary target to verify codesign for (alias for src).",
        ),
        "bundle": attr.label(
            doc = "Bundle target to verify codesign for (alias for src).",
        ),
        "deep_verify": attr.bool(
            default = True,
            doc = "Whether to perform deep codesign verification on bundles.",
        ),
        "dep": attr.label(
            doc = "Dependency target to verify codesign for (alias for src).",
        ),
        "exclude_patterns": attr.string_list(
            default = [],
            doc = "Substrings or patterns to exclude from codesign verification.",
        ),
        "hardened_runtime": attr.bool(
            default = True,
            doc = "Whether to verify that hardened runtime is enabled for all Mach-O binaries. Defaults to True.",
        ),
        "is_store": attr.bool(
            default = False,
            doc = "Whether this is an App Store build target. Defaults to False.",
        ),
        "sign": attr.string(
            doc = "Expected signing identity (alias for signing_identity).",
        ),
        "signing_identity": attr.string(
            default = "",
            doc = "Expected signing identity or certificate. Can use select(...) based on build settings.",
        ),
        "src": attr.label(
            doc = "Target or file containing Mach-O binaries to verify codesign for.",
        ),
        "srcs": attr.label_list(
            doc = "Targets or files containing Mach-O binaries to verify codesign for.",
        ),
        "target": attr.label(
            doc = "Target to verify codesign for (alias for src).",
        ),
        "_macos_constraint": attr.label(
            default = Label("@platforms//os:macos"),
        ),
        "_signing_certificate_name": attr.label(
            default = Label("@rules_apple//apple/build_settings:signing_certificate_name"),
        ),
    },
    doc = "Verifies codesign signature, hardened runtime, and signing identity of Mach-O binaries.",
)

codesign_verify_test = codesign_test
codesign_validation_test = codesign_test
