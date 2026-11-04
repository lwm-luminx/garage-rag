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

A certificate is passed to codesign by its SHA-1 hash, which stays unambiguous when the keychain
holds two valid certificates of the same name (a renewed one beside the old); its common name is
what `codesign_test` looks for in the signature's `Authority=` lines.
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

def _signing_identity_impl(rctx):
    identity, name, source = _choose(rctx, _find_identities(rctx))
    team = _team(rctx, identity, name) if rctx.os.name.startswith("mac") else ""
    rctx.file("BUILD.bazel", "exports_files([\"identity.bzl\"])\n")
    rctx.file("identity.bzl", """\"\"\"The identity local builds sign with. Generated by //bazel:signing_identity.bzl.\"\"\"

# Chosen from: {source}.
# What rules_apple's signing_certificate_name is set to under //bazel:local_auto.
AUTO_SIGNING_IDENTITY = {identity}

# The common name codesign_test expects in the signature (`-` for ad hoc).
AUTO_SIGNING_IDENTITY_NAME = {name}

# The Team ID of an Apple Development certificate, "" otherwise. When it is the App Group's team
# (//bazel:signing.bzl APP_GROUP_TEAM), the build claims the App Group (//bazel:is_local_app_group).
AUTO_SIGNING_TEAM = {team}
""".format(source = source, identity = repr(identity), name = repr(name), team = repr(team)))

signing_identity = repository_rule(
    implementation = _signing_identity_impl,
    # Fetched again after a server restart too, which picks up a certificate added to a keychain
    # other than the watched login keychain.
    local = True,
    configure = True,
    doc = "Writes `identity.bzl` with the identity a local build signs with; see this file's docstring.",
)
