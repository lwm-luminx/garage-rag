"""Rules for building and serving Jekyll static websites with Bazel."""

def _rlocation_path(ctx, file):
    """The path of `file` in a runfiles tree: an external repository's files sit beside the main one's."""
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return ctx.workspace_name + "/" + file.short_path

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

    # Generate an executable runner script for `bazel run`: `jekyll serve` over the workspace's sources
    # (so edits show up live), opened in the browser.
    executable = ctx.actions.declare_file(ctx.label.name + "_runner.sh")

    runner_template = """#!/usr/bin/env bash
set -euo pipefail

# The rules_ruby launcher behind jekyll finds Ruby, the Gemfile and the gems through RUNFILES_DIR,
# falling back to its own "$0.runfiles", which doesn't exist when it is reached through ours. `bazel
# run` sets neither variable, so find this runner's runfiles and hand them down.
if [[ -z "${RUNFILES_DIR:-}" && -z "${RUNFILES_MANIFEST_FILE:-}" ]]; then
    if [[ -d "$0.runfiles" ]]; then
        RUNFILES_DIR="$0.runfiles"
    elif [[ -f "$0.runfiles_manifest" ]]; then
        RUNFILES_MANIFEST_FILE="$0.runfiles_manifest"
    elif [[ -f "$0.runfiles/MANIFEST" ]]; then
        RUNFILES_MANIFEST_FILE="$0.runfiles/MANIFEST"
    fi
fi

JEKYLL_BIN=""
if [[ -n "${RUNFILES_DIR:-}" ]]; then
    RUNFILES_DIR="$(cd "$RUNFILES_DIR" && pwd)"
    export RUNFILES_DIR
    JEKYLL_BIN="$RUNFILES_DIR/__RLOCATION__"
elif [[ -n "${RUNFILES_MANIFEST_FILE:-}" ]]; then
    export RUNFILES_MANIFEST_FILE
    JEKYLL_BIN="$(grep -m 1 "^__RLOCATION__ " "$RUNFILES_MANIFEST_FILE" | cut -d' ' -f2- || true)"
fi
if [[ -z "$JEKYLL_BIN" || ! -x "$JEKYLL_BIN" ]]; then
    echo "Error: could not find jekyll (__RLOCATION__) in the runfiles; run this with bazel run" >&2
    exit 1
fi

if [[ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
    echo "Error: serve the site with bazel run, which serves the workspace's own sources" >&2
    exit 1
fi
SRC_DIR="$BUILD_WORKSPACE_DIRECTORY/__SRC_DIR__"
WORKSPACE_DIR="$BUILD_WORKSPACE_DIRECTORY"

# Files kept outside the site's sources (site_files) go where the built site has them; each such
# path is in the site's .gitignore.
__SITE_FILE_COPIES__

# Build into a temporary folder, not _site in the sources or the read-only runfiles tree, and keep no
# .jekyll-cache beside the sources.
DEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jekyll-__NAME__.XXXXXX")"
trap 'rm -rf "$DEST_DIR"' EXIT

"$JEKYLL_BIN" serve --source "$SRC_DIR" --destination "$DEST_DIR" --disable-disk-cache \\
    --livereload --open-url "$@"
"""
    serve_copies = "\n".join([
        'mkdir -p "$(dirname "$SRC_DIR/{dest}")" && cp "$WORKSPACE_DIR/{src}" "$SRC_DIR/{dest}"'.format(src = f.short_path, dest = site_path)
        for target, site_path in site_files
        for f in target.files.to_list()
    ])
    runner_content = (
        runner_template
            .replace("__RLOCATION__", _rlocation_path(ctx, ctx.executable.jekyll))
            .replace("__SRC_DIR__", src_dir)
            .replace("__NAME__", ctx.label.name)
            .replace("__SITE_FILE_COPIES__", serve_copies)
    )

    ctx.actions.write(
        output = executable,
        content = runner_content,
        is_executable = True,
    )

    # The built site rides in the runfiles, so building the target still builds (and checks) it.
    runfiles = ctx.runfiles(files = inputs + [executable, out_dir]).merge(ctx.attr.jekyll[DefaultInfo].default_runfiles)

    return [
        # The runner is the only default output: `aspect run` executes a target's default output rather
        # than its DefaultInfo executable, and with the site directory there it ran a file from inside it.
        DefaultInfo(
            files = depset([executable]),
            executable = executable,
            runfiles = runfiles,
        ),
        # The built site itself: `bazel build //docs:site --output_groups=site`.
        OutputGroupInfo(site = depset([out_dir])),
    ]

jekyll_site = rule(
    implementation = _jekyll_site_impl,
    doc = "Builds a Jekyll website into a static output directory. `bazel run` serves the workspace's " +
          "sources with live reload and opens the site in the browser; extra arguments go to `jekyll serve`.",
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
