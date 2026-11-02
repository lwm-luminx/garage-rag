"""The code-signing identities this repository knows about.

Only the local ones. The Developer ID and App Store identities, their provisioning profiles and
the release targets that use them live in the repository the signed builds are made from
(garage-enterprise), which fills in this repository's signing seam: `//bazel:distribution`, the
provisioning-profile label flags and rules_apple's `signing_certificate_name` (see
`//bazel:platforms.bzl`). A build here is ad hoc or signed with the local identity.
"""

# Self-signed, generated per developer by //tools/signing:local_identity. It
# exists so that local builds have a code identity that survives a rebuild:
# an ad-hoc signature's designated requirement pins the cdhash, so every build
# is a different app as far as Keychain ACLs are concerned, while a certificate
# pins the certificate's own hash instead. See that script's header.
LOCAL_SIGNING_IDENTITY = "Garage Local Signing"

# Identities with no Apple-issued chain: usable to establish a stable identity,
# but not to notarize, and — because hardened runtime turns on library
# validation, which these cannot satisfy — not to run with hardened runtime.
UNCHAINED_IDENTITIES = ["-", LOCAL_SIGNING_IDENTITY]
