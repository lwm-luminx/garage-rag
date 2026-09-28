"""Rules for building and serving Jekyll static websites with Bazel."""

def _jekyll_site_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.label.name)

    inputs = []
    inputs.extend(ctx.files.srcs)
    if ctx.file.config:
        inputs.append(ctx.file.config)
    inputs.extend(ctx.files.data)
    site_files = ctx.attr.site_files.items()
    for target, _ in site_files:
        inputs.extend(target.files.to_list())

    src_dir = ctx.attr.source_dir if ctx.attr.source_dir else ctx.label.package
    if not src_dir:
        src_dir = "."

    config_path = ctx.file.config.path if ctx.file.config else (src_dir + "/_config.yml")

    # Build action
    args = ctx.actions.args()
    args.add("build")
    args.add("--source", src_dir)
    args.add("--destination", out_dir.path)
    if ctx.file.config:
        args.add("--config", ctx.file.config.path)
    if ctx.attr.flags:
        args.add_all(ctx.attr.flags)

    # Files kept outside the site's sources are copied into the built site under their site path.
    copies = []
    for target, site_path in site_files:
        for f in target.files.to_list():
            copies.append((f.path, site_path))
    copy_commands = "".join([
        '\nmkdir -p "$(dirname "$out/{dest}")" && cp "{src}" "$out/{dest}"'.format(src = src, dest = dest)
        for src, dest in copies
    ])

    ctx.actions.run_shell(
        mnemonic = "JekyllBuild",
        progress_message = "Building Jekyll site %{label}",
        tools = [ctx.executable.jekyll],
        inputs = inputs,
        outputs = [out_dir],
        arguments = [ctx.executable.jekyll.path, out_dir.path, args],
        command = 'set -euo pipefail\njekyll="$1"; out="$2"; shift 2\n"$jekyll" "$@"' + copy_commands,
    )

    # Generate an executable runner script for `bazel run`
    executable = ctx.actions.declare_file(ctx.label.name + "_runner.sh")
    rlocation_jekyll = ctx.workspace_name + "/" + ctx.executable.jekyll.short_path

    runner_template = """#!/usr/bin/env bash
set -euo pipefail

JEKYLL_BIN=""
if [ -n "${RUNFILES_DIR:-}" ] && [ -x "${RUNFILES_DIR}/__RLOCATION__" ]; then
    JEKYLL_BIN="${RUNFILES_DIR}/__RLOCATION__"
elif [ -n "${RUNFILES_MANIFEST_FILE:-}" ]; then
    JEKYLL_BIN="$(grep -m 1 "^__RLOCATION__ " "${RUNFILES_MANIFEST_FILE}" 2>/dev/null | cut -d' ' -f2- || true)"
fi

if [ -z "$JEKYLL_BIN" ] || [ ! -x "$JEKYLL_BIN" ]; then
    if [ -x "${0}.runfiles/__RLOCATION__" ]; then
        JEKYLL_BIN="${0}.runfiles/__RLOCATION__"
    elif [ -x "__SHORT_PATH__" ]; then
        JEKYLL_BIN="__SHORT_PATH__"
    fi
fi

if [ -z "$JEKYLL_BIN" ] || [ ! -x "$JEKYLL_BIN" ]; then
    echo "Error: Could not locate Jekyll executable (__SHORT_PATH__)" >&2
    exit 1
fi

SRC_DIR="${BUILD_WORKSPACE_DIRECTORY:-.}/__SRC_DIR__"
WORKSPACE_DIR="${BUILD_WORKSPACE_DIRECTORY:-.}"

# Files kept outside the site's sources (site_files) go where the built site has them; each such
# path is in the site's .gitignore.
__SITE_FILE_COPIES__
exec "$JEKYLL_BIN" serve --source "$SRC_DIR" "$@"
"""
    serve_copies = "\n".join([
        'mkdir -p "$(dirname "$SRC_DIR/{dest}")" && cp "$WORKSPACE_DIR/{src}" "$SRC_DIR/{dest}"'.format(src = f.short_path, dest = site_path)
        for target, site_path in site_files
        for f in target.files.to_list()
    ])
    runner_content = runner_template.replace("__RLOCATION__", rlocation_jekyll).replace("__SHORT_PATH__", ctx.executable.jekyll.short_path).replace("__SRC_DIR__", src_dir).replace("__SITE_FILE_COPIES__", serve_copies)

    ctx.actions.write(
        output = executable,
        content = runner_content,
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = inputs + [executable]).merge(ctx.attr.jekyll[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            files = depset([out_dir]),
            executable = executable,
            runfiles = runfiles,
        ),
    ]

jekyll_site = rule(
    implementation = _jekyll_site_impl,
    doc = "Builds a Jekyll website into a static output directory.",
    executable = True,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Source files for the Jekyll website (Markdown, HTML, layouts, assets, etc.).",
        ),
        "config": attr.label(
            allow_single_file = True,
            doc = "The _config.yml configuration file.",
        ),
        "source_dir": attr.string(
            doc = "Source directory relative to the workspace root. Defaults to the package directory.",
        ),
        "flags": attr.string_list(
            doc = "Additional flags to pass to jekyll build.",
        ),
        "jekyll": attr.label(
            default = "@bundle//bin:jekyll",
            executable = True,
            cfg = "exec",
            doc = "The jekyll executable.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional data files to make available during the build.",
        ),
        "site_files": attr.label_keyed_string_dict(
            allow_files = True,
            doc = "Files kept outside the site's sources, each copied into the built site at the path " +
                  "given (relative to the site root, e.g. \".data/models.json\"). `bazel run` copies them " +
                  "into the source folder before serving, so list those paths in the site's .gitignore.",
        ),
    },
)
