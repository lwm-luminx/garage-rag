"""The Garage app bundle, declared once for the shipped app and the UI tests' model host.

`//macapp/Sources/GarageApp:GarageApp` is the app every configuration ships. The UI tests that
need a model run `//macapp/Tests/GarageAppModelUITests:GarageApp_uitest`, the same bundle with one
XPC service swapped: the testonly `//macapp/Tests/MockLlamaXPCService` (a deterministic engine
behind LlamaXPCService's own front end, under its bundle identifier) in place of
`//macapp/Sources/LlamaXPCService`. Everything else, contents, identifiers, entitlements and
signing, comes from this one macro, so the two cannot drift. Labels are absolute, since the two
apps live in different packages (each writes a Garage.app, so one package cannot hold both).
"""

load("@rules_apple//apple:macos.bzl", "macos_application")
load("//bazel:codesign.bzl", "HARDENED_RUNTIME_CODESIGNOPTS")

# Every XPC service the app embeds except LlamaXPCService, which the caller picks.
GARAGE_XPC_SERVICES = [
    "//macapp/Sources/GarageMCPServerService:GarageMCPServerService",
    "//macapp/Sources/GarageEmbedXPCService:GarageEmbedXPCService",
    "//macapp/Sources/GarageImageEmbedXPCService:GarageImageEmbedXPCService",
    "//macapp/Sources/GarageIngestXPCService:GarageIngestXPCService",
    "//macapp/Sources/GarageXPCService:GarageXPCService",
    "//macapp/Sources/ModelDownloadXPCService:ModelDownloadXPCService",
]

def garage_macos_application(name, llama_xpc_service, **kwargs):
    """The Garage.app bundle (`me.rickmark.garage-rag`).

    Args:
      name: the target name.
      llama_xpc_service: the `macos_xpc_service` embedded as LlamaXPCService.
      **kwargs: passed to `macos_application` (`testonly`, `tags`, `visibility`).
    """
    macos_application(
        name = name,
        additional_contents = {
            # The launchers: helper bundles, with the bundle identifier, entitlements and
            # provisioning profile each needs to read the Postgres password from the App Group
            # keychain (see //bazel:launcher_app.bzl), and the forwarder scripts that
            # link_launchers.sh links from the documented paths Contents/MacOS/garage and garage-mcp.
            "//macapp/Sources/GarageCLI:garage_app": "Helpers",
            "//macapp/Sources/GarageMCPCLI:garage_mcp_app": "Helpers",
            "//macapp/Sources/GarageCLI:garage": "Resources/launchers",
            "//macapp/Sources/GarageMCPCLI:garage-mcp": "Resources/launchers",
            "//macapp/externals:postgres_output": "Resources/postgres",
            "//macapp/externals:schema_output": "Resources/schema",
            "//macapp/externals:postgresql.conf": "Resources",
            "//data/models": "Resources",
            "//docs:config_schema": "Resources",
            "//data/notices:third_party_notices": "Resources",
            "//garage_python:LICENSE": "Resources",
            "//macapp/Sources/GarageApp:PrivacyInfo.xcprivacy": "Resources",
        },
        app_icons = ["//macapp:GarageApp.xcassets"],
        bundle_id = "me.rickmark.garage-rag",
        bundle_name = "Garage",
        codesignopts = HARDENED_RUNTIME_CODESIGNOPTS,
        # Developer ID: the App Group plus the application identifier its profile backs, so the app
        # keeps the Postgres password in the App Group keychain the launchers read without a prompt.
        entitlements = select({
            "//bazel:is_store": "//macapp/Sources/GarageApp:Garage.entitlements",
            "//bazel:is_developer_id": "//macapp/Sources/GarageApp:GarageDeveloperID.entitlements",
            "//conditions:default": None,
        }),
        executable_name = "GarageApp",
        frameworks = [
            "//macapp/Sources/PythonXPCService:PythonXPCService_framework",
        ],
        # Sparkle's SUFeedURL/SUPublicEDKey only belong in the builds that embed
        # Sparkle. The App Store build updates through the App Store.
        infoplists = ["//macapp/Sources/GarageApp:Info.plist"] + select({
            "//bazel:is_store": [],
            "//conditions:default": ["//macapp/Sources/GarageApp:Sparkle.plist"],
        }),
        # Links Contents/MacOS/garage and garage-mcp to the forwarders in Resources/launchers before
        # the bundle is signed (a symlink is what codesign accepts there; a script is not).
        ipa_post_processor = "//macapp/Sources/GarageApp:link_launchers.sh",
        minimum_os_version = "14.0",
        # Store builds sign with Apple Development and this development profile, so they run on
        # registered Macs; Xcode re-signs with Apple Distribution (GarageMacAppConnect) on upload.
        # Developer ID builds embed the Developer ID profile, which backs the application identifier
        # in GarageDeveloperID.entitlements (the data-protection keychain refuses one without it).
        provisioning_profile = select({
            "//bazel:is_store": "//macapp:GarageRAGDevelopmentApp.provisionprofile",
            "//bazel:is_developer_id": "//macapp:GarageRAGDeveloperID.provisionprofile",
            "//conditions:default": None,
        }),
        version = "//macapp/Sources/GarageApp:GarageAppVersion",
        xpc_services = [llama_xpc_service] + GARAGE_XPC_SERVICES,
        deps = [
            "//macapp/Sources/GarageApp:GarageApp_lib",
            "//ext/python:python_framework",
        ],
        **kwargs
    )
