"""The signing seam: how a repository that holds signing identities declares a signed platform.

This repository builds ad hoc or with the local self-signed identity (`//bazel:local_adhoc`,
`//bazel:local_signed`). The Developer ID and App Store builds are made from garage-enterprise,
which holds the identities, the provisioning profiles and the release targets, and declares its
platforms with `signed_macos_platform`. The macro sets the flags this repository's BUILD files
select on:

- rules_apple's `signing_certificate_name`: the identity every bundle and `codesign` target
  signs with (`//bazel:codesign.bzl` reads it when a target names none);
- `//bazel:distribution`: `developer_id` or `store`, behind `//bazel:is_developer_id` and
  `//bazel:is_store`, which pick entitlements, hardened runtime and the store-only resources;
- the three provisioning-profile label flags, embedded in the app and the two launcher helper
  bundles under those two distributions;
- optionally, Garage.app's entitlements (`//bazel:store_app_entitlements` or
  `//bazel:developer_id_app_entitlements`, by distribution) and the Swift module of app extensions
  (`//macapp/Sources/GarageApp:extensions`, module `GarageAppExtensions`, the contract in
  `//macapp/Sources/GarageAppExtensionKit`). Left out, the app is this repository's: its own
  entitlements and no extensions.

The flags are written with their canonical labels (`str(Label(...))`), so the platform resolves
them whether this module is the root or `@garage_rag` under another one.
"""

def _flag(label, value):
    return "--" + str(Label(label)) + "=" + value

def signed_macos_platform(
        name,
        distribution,
        signing_identity,
        app_provisioning_profile,
        garage_cli_provisioning_profile,
        garage_mcp_provisioning_profile,
        app_entitlements = None,
        app_extensions = None,
        **kwargs):
    """Declares a macOS (Apple silicon) platform for a signed distribution of the app.

    Args:
        name: The platform's name.
        distribution: `"developer_id"` or `"store"` (a value of `//bazel:distribution`).
        signing_identity: The certificate's common name, as `codesign -s` takes it.
        app_provisioning_profile: Label of the profile embedded in Garage.app under this
            distribution, absolute in the declaring repository (`//macapp:X.provisionprofile`).
        garage_cli_provisioning_profile: The same for the `garage` helper bundle.
        garage_mcp_provisioning_profile: The same for the `garage-mcp` helper bundle.
        app_entitlements: Label of Garage.app's entitlements under this distribution, in place of
            this repository's file for it; None keeps that file.
        app_extensions: Label of a swift_library with module name `GarageAppExtensions` exporting
            `GarageAppExtensions.installed` (see //macapp/Sources/GarageAppExtensions); None links
            no extensions.
        **kwargs: Passed to `platform` (`visibility`, ...).
    """
    if distribution not in ("developer_id", "store"):
        fail("{}: distribution must be developer_id or store, not {}".format(name, distribution))
    flags = [
        "--apple_platform_type=macos",
        _flag("@rules_apple//apple/build_settings:signing_certificate_name", signing_identity),
        _flag("//bazel:distribution", distribution),
        _flag("//bazel:app_provisioning_profile", app_provisioning_profile),
        _flag("//bazel:garage_cli_provisioning_profile", garage_cli_provisioning_profile),
        _flag("//bazel:garage_mcp_provisioning_profile", garage_mcp_provisioning_profile),
    ]
    if app_entitlements:
        flags.append(_flag("//bazel:{}_app_entitlements".format(distribution), app_entitlements))
    if app_extensions:
        flags.append(_flag("//macapp/Sources/GarageApp:extensions", app_extensions))
    native.platform(
        name = name,
        constraint_values = [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
        flags = flags,
        **kwargs
    )
