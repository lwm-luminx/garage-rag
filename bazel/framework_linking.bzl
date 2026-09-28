"""Link a binary's Swift code against PythonXPCService.framework instead of a static copy of it.

The XPC services and the launcher helpers import `PythonXPCService` (and PythonKit) as Swift modules,
so their libraries depend on `//macapp/Sources/PythonXPCService`, a `swift_library`, and Bazel links
its archive into the executable. They also link `-framework PythonXPCService`, which carries the same
code, so every class exists twice and the Objective-C runtime warns ("Class ... is implemented in
both ...") and may cast against the wrong copy. The app avoids this with `frameworks =`, but
`macos_xpc_service` has no such attribute, and a helper bundle given one would embed a second copy
of the framework. `framework_linked_library` sits between the binary and its library: it passes the
library's Swift module and headers through, and drops from its linking context every library that
the framework already links (the same subtraction rules_apple makes for `frameworks =`).
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:providers.bzl", "SwiftInfo")

def _library_file(library_to_link):
    return (
        library_to_link.static_library or
        library_to_link.pic_static_library or
        library_to_link.interface_library or
        library_to_link.dynamic_library
    )

def _framework_linked_library_impl(ctx):
    avoid = {}
    for dep in ctx.attr.framework_deps:
        for linker_input in dep[CcInfo].linking_context.linker_inputs.to_list():
            for library in linker_input.libraries:
                avoid[_library_file(library).short_path] = True

    # One linker input, in the dependencies' order, as rules_apple's subtract_linking_contexts builds.
    libraries, user_link_flags, additional_inputs, linkstamps = [], [], [], []
    for dep in ctx.attr.deps:
        for linker_input in dep[CcInfo].linking_context.linker_inputs.to_list():
            libraries.extend([
                library
                for library in linker_input.libraries
                if _library_file(library).short_path not in avoid
            ])
            user_link_flags.extend(linker_input.user_link_flags)
            additional_inputs.extend(linker_input.additional_inputs)
            linkstamps.extend(linker_input.linkstamps)
    linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset(libraries, order = "topological"),
        user_link_flags = user_link_flags,
        additional_inputs = depset(additional_inputs),
        linkstamps = depset(linkstamps),
    )

    cc_info = CcInfo(
        compilation_context = cc_common.merge_compilation_contexts(
            compilation_contexts = [dep[CcInfo].compilation_context for dep in ctx.attr.deps],
        ),
        linking_context = cc_common.create_linking_context(
            linker_inputs = depset([linker_input]),
        ),
    )
    providers = [cc_info, DefaultInfo(files = depset(transitive = [dep[DefaultInfo].files for dep in ctx.attr.deps]))]
    swift_infos = [dep[SwiftInfo] for dep in ctx.attr.deps if SwiftInfo in dep]
    if len(swift_infos) == 1:
        providers.append(swift_infos[0])
    elif swift_infos:
        fail("framework_linked_library takes one Swift library in deps")
    return providers

framework_linked_library = rule(
    implementation = _framework_linked_library_impl,
    attrs = {
        # Named `deps` so rules_apple's aspects (resources, Swift usage) walk through this rule.
        "deps": attr.label_list(
            mandatory = True,
            providers = [CcInfo],
            doc = "The binary's own library.",
        ),
        "framework_deps": attr.label_list(
            mandatory = True,
            providers = [CcInfo],
            doc = "What the framework the binary links was built from; none of it is linked statically.",
        ),
    },
    doc = "`deps`, minus the static libraries a linked framework already carries (see the file's docstring).",
)
