"""Provisioning-profile slots: a label that is the profile when the file is checked in, and a
build error naming the file when it is not.

The signed distributions (Developer ID, App Store; declared by garage-enterprise, which holds the
profiles) embed a profile in the app and in each launcher helper bundle. The files are not all
available at once (each comes from the developer portal), and a `select()` branch that names a missing file would break loading for
every configuration. A slot keeps the label valid: with the file present it is the exported source
file; without it, a `manual` genrule that produces the label and fails with a message saying which
profile to create and where to put it. The default (ad-hoc / locally signed) configuration never
selects the slot, so it builds either way.
"""

def provisioning_profile_slot(name, bundle_id, kind):
    """Declares `//<package>:<name>` for a profile file that may be missing.

    Args:
        name: File name of the profile in this package, e.g. `GarageRAGDevelopmentCLI.provisionprofile`.
            When the file exists it must be exported by the package (`exports_files`); nothing is
            declared here for it.
        bundle_id: The App ID the profile must be issued for (in the failure message).
        kind: The profile type to create in the developer portal (in the failure message), such as
            `"Mac Development"` or `"Developer ID Application"`.
    """
    if native.glob([name], allow_empty = True):
        return
    native.genrule(
        name = name.replace(".", "_") + "_missing",
        outs = [name],
        cmd = """
echo >&2
echo "error: the provisioning profile {package}/{name} is not in the repository." >&2
echo "       This configuration embeds it in the bundle whose App ID is {bundle_id}." >&2
echo "       Create a '{kind}' profile for that App ID in the developer portal, download it as" >&2
echo "       {package}/{name}, and build again. See 'Provisioning profiles' in macapp/README.md." >&2
echo >&2
exit 1
""".format(
            bundle_id = bundle_id,
            kind = kind,
            name = name,
            package = native.package_name(),
        ),
        # Never built by `//...`: it is only reached through the signed configurations' select().
        tags = ["manual"],
        visibility = ["//visibility:public"],
    )
