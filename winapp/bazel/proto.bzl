"""C# sources from a .proto, generated as Grpc.Tools generates them in the .NET SDK build.

A csproj's `<Protobuf Include="x.proto" GrpcServices="Client|Server|Both" />` runs the protoc and
grpc_csharp_plugin shipped in the Grpc.Tools package. This rule runs the same two binaries, from the
same package (@winapp_nuget//grpc.tools), with the same options, so both builds compile identical
code against the pinned Google.Protobuf and Grpc runtimes:

    protoc --csharp_out=OUT --plugin=protoc-gen-grpc=PLUGIN --grpc_out=OUT [--grpc_opt=no_server]
           --proto_path=<Grpc.Tools>/build/native/include --proto_path=<the .proto's folder> x.proto

Outputs follow protoc's naming: `garage.proto` gives `Garage.cs` and, with services, `GarageGrpc.cs`.
"""

_GRPC_OPTIONS = {
    "Both": [],
    "Client": ["no_server"],
    "None": None,
    "Server": ["no_client"],
}

GrpcToolsPlatformInfo = provider(
    doc = "Grpc.Tools' tools/ folder for the machine that runs protoc (Protobuf_ToolsOs/_ToolsCpu).",
    fields = ["dir"],
)

def _grpc_tools_platform_impl(ctx):
    return [GrpcToolsPlatformInfo(dir = ctx.attr.dir)]

grpc_tools_platform = rule(
    implementation = _grpc_tools_platform_impl,
    attrs = {"dir": attr.string(mandatory = True)},
    doc = "Names Grpc.Tools' folder for the platform it is configured for; used in the exec configuration.",
)

def _pascal(stem):
    return "".join([part[:1].upper() + part[1:] for part in stem.replace("-", "_").split("_")])

def _tool(files, platform_dir, name):
    for f in files:
        if f.path.endswith("tools/%s/%s" % (platform_dir, name)):
            return f
    fail("Grpc.Tools has no tools/%s/%s" % (platform_dir, name))

def _csharp_proto_srcs_impl(ctx):
    proto = ctx.file.src
    grpc_options = _GRPC_OPTIONS[ctx.attr.grpc_services]
    stem = _pascal(proto.basename.removesuffix(".proto"))
    outs = [ctx.actions.declare_file("%s/%s.cs" % (ctx.label.name, stem))]
    if grpc_options != None:
        outs.append(ctx.actions.declare_file("%s/%sGrpc.cs" % (ctx.label.name, stem)))
    out_dir = outs[0].dirname

    files = ctx.files._grpc_tools
    platform_dir = ctx.attr._platform[GrpcToolsPlatformInfo].dir
    protoc = _tool(files, platform_dir, "protoc")
    plugin = _tool(files, platform_dir, "grpc_csharp_plugin")
    include = protoc.path.split("/tools/")[0] + "/build/native/include"

    args = ["--csharp_out=" + out_dir]
    if grpc_options != None:
        args += ["--plugin=protoc-gen-grpc=$PLUGIN", "--grpc_out=" + out_dir]
        args += ["--grpc_opt=" + option for option in grpc_options]
    # The folder the .proto's name is taken from, which the descriptor embeds. Grpc.Tools uses
    # the project folder (ProtoRoot) for a .proto inside the project, `Protos/services.proto`,
    # and a linked one's own folder, `garage.proto`.
    root = proto.dirname
    if ctx.attr.proto_root:
        root = "/".join([p for p in [proto.root.path, ctx.label.workspace_root, ctx.label.package, ctx.attr.proto_root] if p and p != "."])
    args += ["--proto_path=" + include, "--proto_path=" + root, proto.path]

    # A NuGet package is a zip, which keeps no executable bit: run copies marked executable. A
    # shell action, so macOS and Linux only (Windows builds winapp/ with `dotnet`).
    ctx.actions.run_shell(
        inputs = files + [proto],
        outputs = outs,
        command = """set -eu
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "{protoc}" "$tmp/protoc" && cp "{plugin}" "$tmp/plugin" && chmod +x "$tmp/protoc" "$tmp/plugin"
PLUGIN="$tmp/plugin"
"$tmp/protoc" {args}
""".format(protoc = protoc.path, plugin = plugin.path, args = " ".join(args)),
        mnemonic = "GrpcToolsProtoc",
        progress_message = "Generating C# for %{label}",
    )
    return [DefaultInfo(files = depset(outs))]

_csharp_proto_srcs = rule(
    implementation = _csharp_proto_srcs_impl,
    attrs = {
        "grpc_services": attr.string(default = "Both", values = _GRPC_OPTIONS.keys()),
        "proto_root": attr.string(),
        "src": attr.label(allow_single_file = [".proto"], mandatory = True),
        "_grpc_tools": attr.label(default = "@winapp_nuget//grpc.tools:files", cfg = "exec"),
        # protoc runs on the exec platform, which is not the target one when cross-building (the
        # repository's default target platform is a macOS one, Linux included).
        "_platform": attr.label(default = "//winapp/bazel:grpc_tools_platform", cfg = "exec"),
    },
)

def csharp_proto_srcs(name, src, grpc_services = "Both", proto_root = None, **kwargs):
    """The C# a csproj's `<Protobuf Include=src GrpcServices=grpc_services />` generates.

    `proto_root` is the project folder, relative to this package (".") for a .proto inside the
    project; leave it unset for one linked from elsewhere.
    """
    _csharp_proto_srcs(
        name = name,
        src = src,
        grpc_services = grpc_services,
        proto_root = proto_root or "",
        **kwargs
    )
