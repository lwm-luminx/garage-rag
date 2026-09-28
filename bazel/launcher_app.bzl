"""The `garage` and `garage-mcp` launchers as helper app bundles.

Each launcher is a small `macos_application` embedded at `Garage.app/Contents/Helpers/<name>.app`,
reached through `Garage.app/Contents/MacOS/<name>` (the stable path the docs and `garage
mcp-install` registrations name), a symlink to the `/bin/sh` forwarder `Contents/Resources/launchers/<name>`
that execs the helper (the link is made by the app's `ipa_post_processor`, link_launchers.sh, as
codesign seals a symlink in MacOS but refuses a script there). A bundle rather than a bare Mach-O in
`Contents/MacOS` because only a bundle can embed a provisioning profile, and only a process whose
application identifier a profile backs may use the data-protection keychain, where the Postgres
password lives in the App Group so the launchers read it without a Keychain prompt (see
`GaragePostgresEndpoint`). `Contents/Helpers` is one of the locations codesign treats as nested
code, so `--deep` verification, notarization and App Store validation all walk it.

The helper embeds no frameworks of its own: it links the app's `Contents/Frameworks/Python.framework` and
`PythonXPCService.framework` (which carries site-python, libpq and libtesseract, as for the XPC services),
four directories up from the helper's executable, hence the `../../../../Frameworks` rpaths.
"""

load("@rules_apple//apple:macos.bzl", "macos_application")
load("@rules_apple//apple:providers.bzl", "AppleBundleInfo")
load("@rules_swift//swift:swift.bzl", "swift_library")
load(
    "//bazel:codesign.bzl",
    "EXPECTED_SIGNING_IDENTITY",
    "HARDENED_RUNTIME_CODESIGNOPTS",
    "HARDENED_RUNTIME_EXPECTED",
    "STORE_EXPECTED",
    "codesign_test",
)
load("//bazel:framework_linking.bzl", "framework_linked_library")

# `Garage.app/Contents/Helpers/<name>.app/Contents/MacOS/<name>` -> `Garage.app/Contents/Frameworks`.
# rules_apple already adds `@executable_path/../Frameworks` and `@loader_path/../Frameworks`
# (the helper's own, empty, Frameworks folder), so only the app's are added here.
LAUNCHER_RPATHS = [
    "@executable_path/../../../../Frameworks",
    "@executable_path/../../../../Frameworks/Python.framework",
    "@loader_path/../../../../Frameworks",
    "@loader_path/../../../../Frameworks/Python.framework",
]

def _bundle_archive_impl(ctx):
    archive = ctx.attr.app[AppleBundleInfo].archive
    return [DefaultInfo(files = depset([archive]))]

bundle_archive = rule(
    implementation = _bundle_archive_impl,
    attrs = {
        "app": attr.label(
            mandatory = True,
            providers = [AppleBundleInfo],
            doc = "The bundle whose archive (.zip, or the bundle directory under tree-artifact outputs) is the only output.",
        ),
    },
    doc = "Just the signed bundle archive of an Apple bundle rule, for tests that must not see its other outputs.",
)

def _rpath_linkopts():
    linkopts = []
    for rpath in LAUNCHER_RPATHS:
        linkopts += ["-Xlinker", "-rpath", "-Xlinker", rpath]
    return linkopts

def garage_launcher_app(
        name,
        bundle_id,
        bundle_name,
        main,
        store_entitlements,
        developer_id_entitlements,
        store_profile,
        developer_id_profile,
        visibility = None):
    """Declares a launcher helper bundle, `<name>` (a `macos_application`), and its codesign test.

    Args:
        name: Target name of the `macos_application`; `<name>_codesign_test` is declared next to it.
        bundle_id: The helper's bundle identifier, which is also its code-signing identifier and
            the last part of its application identifier (`DWVXMLB45Y.<bundle_id>`).
        bundle_name: Name of the bundle and of its executable (`garage` -> `garage.app/Contents/MacOS/garage`).
        main: The `main.swift` that calls `Launcher.run`.
        store_entitlements: Entitlements for `//bazel:is_store` (sandboxed, with the application identifier).
        developer_id_entitlements: Entitlements for `//bazel:is_developer_id` (the application identifier and
            the App Group, not sandboxed).
        store_profile: Label of the Mac Development provisioning profile for `bundle_id`, embedded by
            `--config=appstore` (which signs with Apple Development, like the app).
        developer_id_profile: Label of the Developer ID provisioning profile for `bundle_id`.
        visibility: Visibility of the `macos_application`.
    """
    swift_library(
        name = name + "_main",
        srcs = [main],
        # The rpaths ride on the library, as GarageApp_lib's do: a macos_application's own
        # `linkopts` are handed to the linker with -Wl, where the -Xlinker form is not understood.
        linkopts = _rpath_linkopts(),
        module_name = name.replace("-", "_") + "_main",
        deps = [
            # Interpreter start-up, app launch and the database URL, shared by both launchers.
            "//macapp/Sources/GarageLauncher",
        ],
    )

    macos_application(
        name = name,
        additional_linker_inputs = [
            "//ext/python:python_framework",
            "//macapp/Sources/PythonXPCService:PythonXPCService_signed",
        ],
        bundle_id = bundle_id,
        bundle_name = bundle_name,
        codesignopts = HARDENED_RUNTIME_CODESIGNOPTS,
        entitlements = select({
            "//bazel:is_store": store_entitlements,
            "//bazel:is_developer_id": developer_id_entitlements,
            "//conditions:default": None,
        }),
        executable_name = bundle_name,
        infoplists = ["Info.plist"],
        linkopts = [
            # Link the app's Python.framework directly (PyConfig embedding API); resolved at runtime
            # through the rpaths on the main library (LAUNCHER_RPATHS).
            "-F$(location //ext/python:python_framework)/..",
            "-framework",
            "Python",
            # Loads site-python, libpq and libtesseract with it, as in the XPC services.
            "-F$(location //macapp/Sources/PythonXPCService:PythonXPCService_signed)/..",
            "-framework",
            "PythonXPCService",
        ],
        minimum_os_version = "14.0",
        # Ad-hoc and locally signed builds embed no profile and carry no application identifier; their
        # launchers keep the password in the login keychain, as before. The signed configurations
        # embed the profile for `bundle_id`; a missing one fails the build with a message naming
        # the file (see //bazel:provisioning.bzl).
        provisioning_profile = select({
            "//bazel:is_store": store_profile,
            "//bazel:is_developer_id": developer_id_profile,
            "//conditions:default": None,
        }),
        version = "//macapp/Sources/GarageApp:GarageAppVersion",
        visibility = visibility,
        deps = [
            ":" + name + "_linked",
        ],
    )

    # The launcher's code without the static copy of PythonXPCService.framework's code, which it
    # links from the app (see //bazel:framework_linking.bzl).
    framework_linked_library(
        name = name + "_linked",
        framework_deps = ["//macapp/Sources/PythonXPCService"],
        deps = [":" + name + "_main"],
    )

    # A macos_application's default outputs carry the unsigned linker output next to the archive;
    # the test must only see the signed bundle.
    bundle_archive(
        name = name + "_archive",
        app = ":" + name,
    )

    codesign_test(
        name = name + "_codesign_test",
        src = ":" + name + "_archive",
        hardened_runtime = HARDENED_RUNTIME_EXPECTED,
        is_store = STORE_EXPECTED,
        signing_identity = EXPECTED_SIGNING_IDENTITY,
    )
