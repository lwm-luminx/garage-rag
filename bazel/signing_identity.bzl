"""Finds the identity a local build signs with: Apple Development when the keychain has one.

A build from this repository (no distribution) signs with the first of these that applies:

1. `GARAGE_SIGNING_IDENTITY`, set in the environment or with `--repo_env`: a certificate's common
   name, its SHA-1 hash as `security find-identity` prints it, or `-` for ad hoc;
2. an Apple Development certificate with its private key in the keychain search list, so the
   build carries a Team ID and a designated requirement anchored to Apple, which no rebuild
   changes and which `GarageXPCPeerRequirement` accepts;
3. the self-signed local identity from `//tools/signing:local_identity`, when it exists;
4. ad hoc.

The answer is a repository, `@garage_signing_identity`, so that the platform the build runs on
(`//bazel:local_auto`) can name it in its flags: rules_apple's `signing_certificate_name` is
fixed at analysis time, and there is no other way for a keychain lookup to reach it. The
repository is fetched again when the login keychain or `GARAGE_SIGNING_IDENTITY` changes; it
writes the same file when the answer is the same, so that refetch rebuilds nothing.

A development build signed by the App Group's own team (`APP_GROUP_TEAM` in `signing.bzl`) also
claims the App Group, as the Developer ID build does (`GarageAppGroup.entitlements`, which needs no
provisioning profile outside the store), so it and its XPC services can reach the group container
that `~/Library/Application Support/GarageApp` links to once a released build has run. Any other
team's certificate signs without it.

The same repository serves `--config=developer_id` (`//bazel:developer_id`), the Developer ID build
for GitHub releases (`//macapp/package`): the keychain's "Developer ID Application" and "Developer ID
Installer" certificates, and the three Developer ID provisioning profiles it embeds (the app and the
two launcher helper bundles), found among those installed for Xcode
(`~/Library/Developer/Xcode/UserData/Provisioning Profiles`, `~/Library/MobileDevice/Provisioning
Profiles`) or in the folders `GARAGE_PROVISIONING_PROFILES` lists (colon-separated). A profile is
picked by its application identifier, among those that provision every device (Developer ID), the
one that expires last. Nothing about them is checked in; a build that lacks one fails saying which.

A certificate is passed to the build by its common name, never its SHA-1 hash: rules_apple's
codesigningtool looks the identity up with a regex that must match inside the quoted name
`security find-identity` prints, so a hash is "not found". The hash is used only here, to read the
chosen certificate's Team ID. When the keychain holds two valid certificates of the same name (a
renewed one beside the old), rules_apple signs with the first `security` lists. The common name is
also what `codesign_test` looks for in the signature's `Authority=` lines.
"""

load(":signing.bzl", "LOCAL_SIGNING_IDENTITY")

_DEVELOPMENT_PREFIX = "Apple Development: "

def _parse_identities(output):
    """Returns `[(sha1, name)]` from `security find-identity -v -p codesigning` output."""
    identities = []
    for line in output.splitlines():
        line = line.strip()

        # `  1) 0123...ABCD "Apple Development: Jane Doe (ABCDE12345)"`
        if ")" not in line or "\"" not in line:
            continue
        rest = line.split(")", 1)[1].strip()
        sha1 = rest.split(" ", 1)[0]
        if len(sha1) != 40:
            continue
        name = rest[rest.find("\"") + 1:rest.rfind("\"")]
        if name and (sha1, name) not in identities:
            identities.append((sha1, name))
    return identities

def _find_identities(rctx):
    if not rctx.os.name.startswith("mac"):
        return []
    home = rctx.getenv("HOME")
    if home:
        # A new certificate (or a deleted one) changes the login keychain, which refetches this
        # repository. Certificates in another keychain need `--repo_env` or a `bazel fetch --force`.
        keychain = rctx.path(home + "/Library/Keychains/login.keychain-db")
        if keychain.exists:
            rctx.watch(keychain)
    result = rctx.execute(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], quiet = True)
    if result.return_code != 0:
        return []
    return _parse_identities(result.stdout)

# Prints the subject of the certificate whose SHA-1 is $2 among those named $1, one RDN per line.
_SUBJECT_SCRIPT = """
/usr/bin/security find-certificate -a -Z -p -c "$1" 2>/dev/null |
    /usr/bin/awk -v want="$2" '
        /^SHA-1 hash:/ { keep = (toupper($3) == toupper(want)); next }
        keep { print }
    ' |
    /usr/bin/openssl x509 -noout -subject -nameopt sep_multiline,sname 2>/dev/null
"""

def _team(rctx, sha1, name):
    """The Team ID (the subject's OU) of an Apple-issued certificate, or "" if it has none."""
    if sha1 == name or not name.startswith(_DEVELOPMENT_PREFIX):
        return ""
    result = rctx.execute(["/bin/sh", "-c", _SUBJECT_SCRIPT, "subject", name, sha1], quiet = True)
    if result.return_code != 0:
        return ""
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.startswith("OU="):
            return line[len("OU="):].strip()
    return ""

def _choose(rctx, identities):
    """Returns `(identity, name, source)`: what codesign gets, what a test expects, and why."""
    override = rctx.getenv("GARAGE_SIGNING_IDENTITY", "").strip()
    if override == "-":
        return ("-", "-", "GARAGE_SIGNING_IDENTITY")
    if override:
        for sha1, name in identities:
            if override.upper() == sha1.upper() or override == name:
                return (sha1, name, "GARAGE_SIGNING_IDENTITY")
        return (override, override, "GARAGE_SIGNING_IDENTITY (not found in the keychain)")
    for sha1, name in identities:
        if name.startswith(_DEVELOPMENT_PREFIX):
            return (sha1, name, "the keychain's Apple Development certificate")
    for _, name in identities:
        if name == LOCAL_SIGNING_IDENTITY:
            # By name, as --config=local_signed passes it, so //bazel:is_local_signed matches.
            return (name, name, "the local identity from //tools/signing:local_identity")
    return ("-", "-", "no signing identity in the keychain")

_DEVELOPER_ID_PREFIX = "Developer ID Application: "
_INSTALLER_PREFIX = "Developer ID Installer: "

# The bundles a Developer ID build embeds a profile in, by the //bazel label flag that names the
# profile, and the bundle identifier its application identifier carries after the team.
_PROFILES = [
    ("app", "me.rickmark.garage-rag"),
    ("garage_cli", "me.rickmark.garage-rag.garage-cli"),
    ("garage_mcp", "me.rickmark.garage-rag.mcp-server-cli"),
]

def _installer_identities(rctx):
    """`find-identity` without `-p codesigning`, which leaves installer certificates out."""
    if not rctx.os.name.startswith("mac"):
        return []
    result = rctx.execute(["/usr/bin/security", "find-identity", "-v"], quiet = True)
    if result.return_code != 0:
        return []
    return _parse_identities(result.stdout)

def _first_named(identities, prefix):
    for _, name in identities:
        if name.startswith(prefix):
            return name
    return ""

def _plist_value(xml, key):
    """The value after `<key>key</key>` in a plist's XML: a string's or date's text, "true", "false" or ""."""
    marker = "<key>" + key + "</key>"
    at = xml.find(marker)
    if at < 0:
        return ""
    rest = xml[at + len(marker):].lstrip()
    if rest.startswith("<true/>"):
        return "true"
    if rest.startswith("<false/>"):
        return "false"
    for tag in ("string", "date"):
        opening = "<" + tag + ">"
        if rest.startswith(opening):
            return rest[len(opening):rest.find("</" + tag + ">")].strip()
    return ""

def _profile_dirs(rctx):
    dirs = [entry.strip() for entry in rctx.getenv("GARAGE_PROVISIONING_PROFILES", "").split(":") if entry.strip()]
    home = rctx.getenv("HOME")
    if home:
        dirs.append(home + "/Library/Developer/Xcode/UserData/Provisioning Profiles")
        dirs.append(home + "/Library/MobileDevice/Provisioning Profiles")
    return dirs

def _developer_id_profiles(rctx):
    """Maps each application identifier to `(expiration, path)` of its newest Developer ID profile."""
    found = {}
    if not rctx.os.name.startswith("mac"):
        return found
    for directory in _profile_dirs(rctx):
        path = rctx.path(directory)
        if not path.exists or not path.is_dir:
            continue
        rctx.watch_tree(path)
        for child in path.readdir():
            if not child.basename.endswith(".provisionprofile"):
                continue
            decoded = rctx.execute(["/usr/bin/security", "cms", "-D", "-i", str(child)], quiet = True)
            if decoded.return_code != 0:
                continue
            xml = decoded.stdout

            # A Developer ID profile provisions every device; development and App Store ones do not.
            if _plist_value(xml, "ProvisionsAllDevices") != "true":
                continue
            app_id = _plist_value(xml, "com.apple.application-identifier")
            expires = _plist_value(xml, "ExpirationDate")
            if app_id and (app_id not in found or expires > found[app_id][0]):
                found[app_id] = (expires, str(child))
    return found

# Named .provisionprofile so rules_apple accepts it at analysis and the build fails here, saying which
# profile to install, rather than with "does not produce any provisioning_profile files".
_MISSING_PROFILE = """genrule(
    name = "{target}",
    outs = ["missing/{target}.provisionprofile"],
    cmd = "echo '{message}' >&2; exit 1",
)
"""

def _write_developer_id(rctx, team):
    """Returns the Developer ID identities, their team and the profiles' BUILD targets."""
    application = _first_named(_find_identities(rctx), _DEVELOPER_ID_PREFIX)
    installer = _first_named(_installer_identities(rctx), _INSTALLER_PREFIX)
    if application.endswith(")") and "(" in application:
        # "Developer ID Application: Name (TEAMID)": the team is the parenthesized suffix.
        team = application[application.rfind("(") + 1:-1]
    profiles = _developer_id_profiles(rctx)
    targets = []
    for flag, bundle_id in _PROFILES:
        target = "developer_id_{}_profile".format(flag)
        app_id = team + "." + bundle_id if team else bundle_id
        if app_id in profiles:
            rctx.symlink(profiles[app_id][1], target + ".provisionprofile")
            targets.append('alias(\n    name = "{0}",\n    actual = "{0}.provisionprofile",\n)\n'.format(target))
        else:
            message = ("No Developer ID provisioning profile for {} is installed: install it (double-click it, " +
                       "or Xcode, Settings, Accounts, Download Manual Profiles) or name its folder in " +
                       "GARAGE_PROVISIONING_PROFILES.").format(app_id)
            targets.append(_MISSING_PROFILE.format(target = target, message = message))
    return application, installer, team, "\n".join(targets)

def _signing_identity_impl(rctx):
    identity, name, source = _choose(rctx, _find_identities(rctx))
    team = _team(rctx, identity, name) if rctx.os.name.startswith("mac") else ""

    # rules_apple matches signing_certificate_name against certificate names only (see the
    # docstring), so hand it the name; `identity` was the hash only to look up the team above.
    identity = name
    developer_id, installer, developer_id_team, profile_targets = _write_developer_id(rctx, team or "")
    rctx.file("BUILD.bazel", "package(default_visibility = [\"//visibility:public\"])\n\nexports_files([\"identity.bzl\"])\n\n" + profile_targets)
    rctx.file("identity.bzl", """\"\"\"The identity local builds sign with. Generated by //bazel:signing_identity.bzl.\"\"\"

# Chosen from: {source}.
# What rules_apple's signing_certificate_name is set to under //bazel:local_auto.
AUTO_SIGNING_IDENTITY = {identity}

# The common name codesign_test expects in the signature (`-` for ad hoc).
AUTO_SIGNING_IDENTITY_NAME = {name}

# The Team ID of an Apple Development certificate, "" otherwise. When it is the App Group's team
# (//bazel:signing.bzl APP_GROUP_TEAM), the build claims the App Group (//bazel:is_local_app_group).
AUTO_SIGNING_TEAM = {team}

# The keychain's Developer ID certificates (//bazel:developer_id, //macapp/package), or a placeholder
# naming what is missing, so a Developer ID build without one fails at signing saying so.
DEVELOPER_ID_IDENTITY = {developer_id}
DEVELOPER_ID_INSTALLER_IDENTITY = {installer}
DEVELOPER_ID_TEAM = {developer_id_team}

# The Developer ID profiles' targets here, as the canonical labels a platform's flags need.
DEVELOPER_ID_PROFILES = {{
    "app": str(Label("//:developer_id_app_profile")),
    "garage_cli": str(Label("//:developer_id_garage_cli_profile")),
    "garage_mcp": str(Label("//:developer_id_garage_mcp_profile")),
}}
""".format(
        source = source,
        identity = repr(identity),
        name = repr(name),
        team = repr(team),
        developer_id = repr(developer_id or "(no Developer ID Application certificate in the keychain)"),
        installer = repr(installer or "(no Developer ID Installer certificate in the keychain)"),
        developer_id_team = repr(developer_id_team),
    ))

signing_identity = repository_rule(
    implementation = _signing_identity_impl,
    # Fetched again after a server restart too, which picks up a certificate added to a keychain
    # other than the watched login keychain.
    local = True,
    configure = True,
    doc = "Writes `identity.bzl` with the identity a local build signs with; see this file's docstring.",
)
