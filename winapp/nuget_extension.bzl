"""The module extension behind @winapp_nuget (winapp.MODULE.bazel)."""

load(":nuget.bzl", "winapp_nuget_packages")

def _winapp_nuget_impl(module_ctx):
    winapp_nuget_packages()
    return module_ctx.extension_metadata(reproducible = True)

winapp_nuget = module_extension(implementation = _winapp_nuget_impl)
