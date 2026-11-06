"""A macos_application built for another platform: the signed distributions' app targets.

The repository that holds the signing identities (garage-enterprise) declares a platform with
`//bazel:platforms.bzl` and wraps `//macapp/Sources/GarageApp:GarageApp` in
`platform_macos_application(platform = ...)`, which transitions the app onto it. The runner it
writes unpacks the bundle into a fixed folder (see below) and execs the app.
"""

load(
    "@rules_apple//apple:providers.bzl",
    "AppleBundleInfo",
    "AppleExtraOutputsInfo",
)

def _platform_transition_impl(settings, attr):
    return {
        "//command_line_option:platforms": [str(attr.platform)],
        "//command_line_option:macos_cpus": ["arm64"],
    }

platform_transition = transition(
    implementation = _platform_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:platforms",
        "//command_line_option:macos_cpus",
    ],
)

def _transition_app_impl(ctx):
    target = ctx.attr.app[0]
    orig_executable = target[DefaultInfo].files_to_run.executable

    # Not `ctx.label.name`: these targets are named `Garage.app`, and Gatekeeper
    # treats an exec'd file whose path ends in `.app` as an app bundle. An
    # unsigned script with a provenance xattr fails that assessment, so
    # syspolicyd SIGKILLs the launcher and `bazel run` exits 137 before the app
    # ever starts.
    executable = ctx.actions.declare_file(ctx.label.name.removesuffix(".app") + "_run")
    bundle_info = target[AppleBundleInfo] if AppleBundleInfo in target else None
    if bundle_info and bundle_info.archive:
        # Not rules_apple's runner: it unzips into a fresh `mktemp -d` and deletes
        # it when the app exits. Garage's database reset launches a new instance
        # from its own bundle and then quits, so that cleanup pulls the bundle
        # (Postgres, Python, the icon) out from under the new instance. Unzip into
        # a fixed folder instead, replaced by the next `bazel run` and never
        # deleted on exit, and exec the binary so its output stays in the terminal.
        archive_rlocation = ctx.workspace_name + "/" + bundle_info.archive.short_path
        bundle_dir = bundle_info.bundle_name + bundle_info.bundle_extension
        runner_content = """#!/bin/bash
set -euo pipefail
ARCHIVE=""
if [ -n "${{RUNFILES_DIR:-}}" ] && [ -f "${{RUNFILES_DIR}}/{archive}" ]; then
    ARCHIVE="${{RUNFILES_DIR}}/{archive}"
elif [ -f "${{0}}.runfiles/{archive}" ]; then
    ARCHIVE="${{0}}.runfiles/{archive}"
elif [ -n "${{RUNFILES_MANIFEST_FILE:-}}" ]; then
    ARCHIVE="$(grep -m 1 "^{archive} " "${{RUNFILES_MANIFEST_FILE}}" 2>/dev/null | cut -d' ' -f2- || true)"
fi
if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
    echo "Error: could not locate the app archive ({archive})" >&2
    exit 1
fi

RUN_DIR="${{TMPDIR:-/tmp}}/garage-bazel-run/{name}"
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"
unzip -qq "$ARCHIVE" -d "$RUN_DIR"
APP="$RUN_DIR/{bundle_dir}"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist")"
exec "$APP/Contents/MacOS/$EXECUTABLE" "$@"
""".format(
            archive = archive_rlocation,
            bundle_dir = bundle_dir,
            name = ctx.label.name.removesuffix(".app"),
        )
        ctx.actions.write(
            output = executable,
            content = runner_content,
            is_executable = True,
        )
        runfiles = ctx.runfiles(files = [bundle_info.archive]).merge(target[DefaultInfo].default_runfiles)
    elif orig_executable:
        rlocation = ctx.workspace_name + "/" + orig_executable.short_path
        runner_content = """#!/bin/bash
set -euo pipefail
EXEC_FILE=""
if [ -n "${{RUNFILES_DIR:-}}" ] && [ -x "${{RUNFILES_DIR}}/{rlocation}" ]; then
    EXEC_FILE="${{RUNFILES_DIR}}/{rlocation}"
elif [ -n "${{RUNFILES_MANIFEST_FILE:-}}" ]; then
    EXEC_FILE="$(grep -m 1 "^{rlocation} " "${{RUNFILES_MANIFEST_FILE}}" 2>/dev/null | cut -d' ' -f2- || true)"
fi

if [ -z "$EXEC_FILE" ] || [ ! -x "$EXEC_FILE" ]; then
    if [ -x "${{0}}.runfiles/{rlocation}" ]; then
        EXEC_FILE="${{0}}.runfiles/{rlocation}"
    elif [ -x "{short_path}" ]; then
        EXEC_FILE="{short_path}"
    fi
fi

if [ -z "$EXEC_FILE" ] || [ ! -x "$EXEC_FILE" ]; then
    echo "Error: Could not locate application executable ({short_path})" >&2
    exit 1
fi

exec "$EXEC_FILE" "$@"
""".format(
            rlocation = rlocation,
            short_path = orig_executable.short_path,
        )
        ctx.actions.write(
            output = executable,
            content = runner_content,
            is_executable = True,
        )
        runfiles = ctx.runfiles(files = [orig_executable]).merge(target[DefaultInfo].default_runfiles)
    else:
        ctx.actions.write(
            output = executable,
            content = "#!/bin/bash\nexit 0\n",
            is_executable = True,
        )
        runfiles = target[DefaultInfo].default_runfiles

    providers = [
        DefaultInfo(
            files = target[DefaultInfo].files,
            executable = executable,
            runfiles = runfiles,
        ),
    ]
    if OutputGroupInfo in target:
        providers.append(target[OutputGroupInfo])
    if AppleBundleInfo in target:
        providers.append(target[AppleBundleInfo])
    if AppleExtraOutputsInfo in target:
        providers.append(target[AppleExtraOutputsInfo])
    return providers

platform_macos_application = rule(
    implementation = _transition_app_impl,
    executable = True,
    attrs = {
        "app": attr.label(
            cfg = platform_transition,
            mandatory = True,
            doc = "The macos_application to build for `platform`.",
        ),
        "platform": attr.label(
            mandatory = True,
            doc = "The platform to build it for, declared with //bazel:platforms.bzl's signed_macos_platform.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Builds a macos_application for the given platform, with a runner that launches the bundle.",
)
