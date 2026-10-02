"""Rule for assembling a unified Python site-packages directory."""

load("@aspect_rules_py//py/private:providers.bzl", "PyWheelsInfo")
load("@aspect_rules_py//py/private:py_info.bzl", "RulesPyInfo")
load("@rules_apple//apple/internal:providers.bzl", "new_appleresourceinfo")
load("@rules_python//python:py_info.bzl", "PyInfo")

def _python_site_packages_impl(ctx):
    out = ctx.actions.declare_directory(ctx.attr.out if ctx.attr.out else ctx.label.name)

    inputs = []
    wheel_trees = []
    src_files = []

    for dep in ctx.attr.deps:
        if PyWheelsInfo in dep:
            for wheel in dep[PyWheelsInfo].wheels.to_list():
                if hasattr(wheel, "install_tree") and wheel.install_tree:
                    inputs.append(wheel.install_tree)
                    wheel_trees.append(wheel.install_tree)
        if RulesPyInfo in dep:
            for f in dep[RulesPyInfo].transitive_sources.to_list():
                inputs.append(f)
                src_files.append(f)
        elif PyInfo in dep:
            for f in dep[PyInfo].transitive_sources.to_list():
                inputs.append(f)
                src_files.append(f)
        elif DefaultInfo in dep:
            for f in dep[DefaultInfo].files.to_list():
                inputs.append(f)
                src_files.append(f)

    wheel_args = ctx.actions.args()
    wheel_args.add(out.path)
    wheel_args.add(str(len(wheel_trees)))
    for tree in wheel_trees:
        wheel_args.add(tree.path)

    wheel_args.add(str(len(src_files)))
    for f in src_files:
        wheel_args.add(f.path)

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [out],
        arguments = [wheel_args],
        command = """
set -euo pipefail

out="$1"
num_wheels="$2"
shift 2

wheels=()
while [ "$num_wheels" -gt 0 ]; do
    wheels+=("$1")
    shift
    num_wheels=$((num_wheels - 1))
done

num_srcs="$1"
shift 1

srcs=()
while [ "$num_srcs" -gt 0 ]; do
    srcs+=("$1")
    shift
    num_srcs=$((num_srcs - 1))
done

mkdir -p "$out"

if [ "${#wheels[@]}" -gt 0 ]; then
    for w in "${wheels[@]}"; do
        if [ -d "$w" ]; then
            # Find site-packages or top-level package contents in wheel install tree
            sp_dirs=$(find "$w" -type d -name "site-packages" 2>/dev/null || true)
            if [ -n "$sp_dirs" ]; then
                for sp in $sp_dirs; do
                    if [ -d "$sp" ]; then
                        cp -RL "$sp/." "$out/" 2>/dev/null || true
                    fi
                done
            else
                cp -RL "$w/." "$out/" 2>/dev/null || true
            fi
        fi
    done
fi

if [ "${#srcs[@]}" -gt 0 ]; then
    for s in "${srcs[@]}"; do
        if [ -f "$s" ]; then
            # Determine target path inside site-packages
            # If path contains 'garage_python/src/', strip prefix
            rel_path="$s"
            if [[ "$s" == external/* ]]; then
                # A source archive's own layout (external/<repo>/<package>/...).
                rel_path="${s#external/*/}"
            elif [[ "$s" == *"garage_python/src/"* ]]; then
                rel_path="${s#*garage_python/src/}"
            elif [[ "$s" == *"src/"* ]]; then
                rel_path="${s#*src/}"
            fi
            mkdir -p "$out/$(dirname "$rel_path")"
            cp -L "$s" "$out/$rel_path"
        fi
    done
fi

# Garage ships Apple Silicon only, but universal2 wheels (grpcio, lxml, cryptography, ...)
# carry an x86_64 slice too. Thin each fat extension to arm64 here, so the App Store archive,
# which takes these files as they are, ships none; macos_lipo_app (//bazel:lipo.bzl) thins
# the Developer ID app again as a whole. The arm64 slice keeps its own signature.
if command -v lipo >/dev/null 2>&1; then
    chmod -R u+w "$out"
    find "$out" -type f \\( -name '*.so' -o -name '*.dylib' \\) -print0 |
        while IFS= read -r -d '' f; do
            archs="$(lipo -archs "$f" 2>/dev/null || true)"
            case " $archs " in
                "  " | " arm64 ") ;;
                *" arm64 "*)
                    lipo -thin arm64 "$f" -output "$f.thin"
                    mv "$f.thin" "$f"
                    ;;
            esac
        done
fi
""",
        mnemonic = "PythonSitePackages",
        progress_message = "Assembling Python site-packages for {}".format(ctx.label),
    )

    return [
        DefaultInfo(
            files = depset([out]),
            runfiles = ctx.runfiles(files = [out]),
        ),
        new_appleresourceinfo(
            owners = depset([]),
            unowned_resources = depset([]),
        ),
    ]

python_site_packages = rule(
    implementation = _python_site_packages_impl,
    doc = "Assembles wheel dependencies and source modules into a single site-packages directory.",
    attrs = {
        "deps": attr.label_list(
            mandatory = True,
            doc = "Python library or binary targets whose transitive dependencies and sources should be packaged.",
        ),
        "out": attr.string(
            doc = "Output directory name. Defaults to target name.",
        ),
    },
)
