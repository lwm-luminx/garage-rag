#!/usr/bin/env bash
#
# Creates (or re-imports) the self-signed code-signing identity used for local
# builds, so that locally built binaries have a *stable* code identity.
#
# Why this exists
# ---------------
# An ad-hoc signature ("codesign -s -") has no certificate, so the designated
# requirement macOS derives for the binary is
#
#     identifier "com.example.app" and cdhash H"<hash of this exact build>"
#
# Keychain ACLs are stored as designated requirements, so every rebuild — every
# recompile, every new Bazel output — is a different application as far as the
# Keychain is concerned, and the items the app created (the Postgres superuser
# password, the LM Studio token) no longer belong to it. That is the "GarageApp
# wants to access key ..." dialog on every single build.
#
# Signing with a certificate instead anchors the requirement to the certificate:
#
#     identifier "com.example.app" and certificate root = H"<hash of the cert>"
#
# ("root" rather than "leaf" because the certificate is self-signed, so it is
# both.) The cdhash changes on every build; the certificate's hash does not, so
# the Keychain ACL keeps matching until the certificate itself is replaced.
#
# The certificate is self-signed and trusted only in this user's trust settings.
# It is good for exactly one thing — a stable local identity — and is not usable
# for distribution: no Apple-issued chain means no notarization, no Team ID that
# library validation accepts, and no Gatekeeper pass on anyone else's machine.
#
# Sharing one identity across machines
# ------------------------------------
# The requirement embeds the certificate's hash, so two machines that each
# generate their own certificate produce two different identities and neither
# can open the other's Keychain items. To make builds on a second machine count
# as the same application, move the identity rather than making a new one:
#
#     ./local_identity.sh export ~/garage-signing.p12   # on the first machine
#     ./local_identity.sh ensure --import ~/garage-signing.p12   # on the second
#
set -euo pipefail

IDENTITY="Garage Local Signing"
ORGANIZATION="Garage"
# An organizational marker in the subject, nothing more: codesign reads the Team
# Identifier out of an Apple-issued certificate extension, not the OU, so a
# binary signed with this one has no Team ID at all — which is why hardened
# runtime, and the library validation it implies, is off for this config.
TEAM="GARAGELOCAL"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
KEYCHAIN="${GARAGE_SIGNING_KEYCHAIN:-$LOGIN_KEYCHAIN}"
DAYS=3650
IMPORT_P12=""
EXPORT_PATH=""
FORCE=0
COMMAND=""

usage() {
    cat <<USAGE
Usage: local_identity [ensure|show|export <path>|remove] [options]

Commands:
  ensure            Create the identity if it is not already usable (default).
  show              Print the current identity and its designated requirement.
  export <path>     Write the identity to a .p12 for use on another machine.
  remove            Delete the certificate, its key, and its trust setting.

Options:
  --identity NAME   Common name of the certificate (default: $IDENTITY)
  --keychain PATH   Keychain to hold the identity (default: the login keychain)
  --import PATH     Import this .p12 instead of generating a new certificate
  --days N          Validity of a newly generated certificate (default: $DAYS)
  --force           Replace an existing identity of the same name
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        ensure | show | remove)
            COMMAND="$1"
            shift
            ;;
        export)
            COMMAND="export"
            shift
            if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then
                EXPORT_PATH="$1"
                shift
            fi
            ;;
        --identity)
            IDENTITY="$2"
            shift 2
            ;;
        --keychain)
            KEYCHAIN="$2"
            shift 2
            ;;
        --import)
            IMPORT_P12="$2"
            shift 2
            ;;
        --days)
            DAYS="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "error: unrecognized argument '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done
COMMAND="${COMMAND:-ensure}"

# `bazel run` starts in the runfiles tree, where a relative --import or export
# path would not mean what the user typed it to mean.
if [ -n "${BUILD_WORKING_DIRECTORY:-}" ]; then
    cd "$BUILD_WORKING_DIRECTORY"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/garage-signing.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# The SHA-1 of the identity's certificate, or nothing if it is not usable for
# code signing — which covers all three ways it can be missing: no certificate,
# no private key beside it, or a certificate that is not trusted.
identity_hash() {
    /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null |
        awk -v name="\"$IDENTITY\"" 'index($0, name) { print $2; exit }'
}

require_identity() {
    local hash
    hash="$(identity_hash)"
    if [ -z "$hash" ]; then
        echo "error: no usable code-signing identity named '$IDENTITY' in $KEYCHAIN" >&2
        echo "       run: bazel run //tools/signing:local_identity" >&2
        exit 1
    fi
    echo "$hash"
}

# Signs a throwaway copy of a system binary. This is the only check that proves
# the whole chain: that the certificate is trusted for code signing, that the key
# is reachable, and that the requirement which comes out is anchored to the
# certificate rather than to a cdhash.
#
# It is also where the "codesign wants to sign using key ..." dialog appears the
# first time, which is deliberate — better here, in a setup step someone is
# watching, than in the middle of their first build.
verify_identity() {
    local probe="$TMP_DIR/probe"
    cp /bin/echo "$probe"
    if ! /usr/bin/codesign -f -s "$IDENTITY" --keychain "$KEYCHAIN" "$probe" 2>"$TMP_DIR/sign.err"; then
        echo "error: signing a test binary with '$IDENTITY' failed:" >&2
        sed 's/^/       /' "$TMP_DIR/sign.err" >&2
        return 1
    fi
    /usr/bin/codesign --verify --strict "$probe"
    echo "Designated requirement:"
    /usr/bin/codesign -d -r- "$probe" 2>/dev/null | sed -n 's/^designated => /  /p'
    echo "Team identifier: $(/usr/bin/codesign -dvvv "$probe" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
}

cmd_show() {
    local hash
    hash="$(require_identity)"
    echo "Identity: $IDENTITY"
    echo "Keychain: $KEYCHAIN"
    echo "SHA-1:    $hash"
    /usr/bin/security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" |
        /usr/bin/openssl x509 -noout -subject -enddate | sed 's/^/          /'
    verify_identity
}

cmd_export() {
    require_identity >/dev/null
    if [ -z "$EXPORT_PATH" ]; then
        echo "error: export needs a destination path" >&2
        exit 2
    fi
    echo "Exporting '$IDENTITY'. macOS will ask for a password to protect the .p12,"
    echo "and then for permission to release the private key."
    /usr/bin/security export -k "$KEYCHAIN" -t identities -f pkcs12 -o "$EXPORT_PATH"
    chmod 600 "$EXPORT_PATH"
    echo
    echo "Wrote $EXPORT_PATH. It holds a private key: move it over a channel you"
    echo "trust and delete it once the other machine has imported it."
}

cmd_remove() {
    local pem="$TMP_DIR/existing.pem"
    local removed=0
    # The private key goes with the identity, but the trust setting is a separate
    # record keyed by certificate and outlives the certificate if left alone.
    while /usr/bin/security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; do
        /usr/bin/security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" >"$pem"
        /usr/bin/security remove-trusted-cert "$pem" 2>/dev/null || true
        if ! /usr/bin/security delete-identity -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1 &&
            ! /usr/bin/security delete-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
            echo "error: could not delete '$IDENTITY' from $KEYCHAIN" >&2
            exit 1
        fi
        removed=$((removed + 1))
    done
    if [ "$removed" -eq 0 ]; then
        echo "No certificate named '$IDENTITY' in $KEYCHAIN."
        return 0
    fi
    echo "Removed '$IDENTITY' from $KEYCHAIN."
}

cmd_ensure() {
    local existing
    existing="$(identity_hash)"
    if [ -n "$existing" ] && [ "$FORCE" -eq 0 ] && [ -z "$IMPORT_P12" ]; then
        echo "'$IDENTITY' is already usable in $KEYCHAIN (SHA-1 $existing)."
        verify_identity
        return 0
    fi
    if [ -n "$existing" ]; then
        echo "Replacing the existing '$IDENTITY' certificate. Anything signed with it,"
        echo "and any Keychain item whose ACL names it, stops matching — the same break"
        echo "a cdhash change causes today, which is the thing this identity exists to"
        echo "avoid, so do this rarely."
        cmd_remove
    fi

    local p12="$TMP_DIR/identity.p12"
    local p12_password=""
    if [ -n "$IMPORT_P12" ]; then
        if [ ! -f "$IMPORT_P12" ]; then
            echo "error: no such file: $IMPORT_P12" >&2
            exit 1
        fi
        cp "$IMPORT_P12" "$p12"
        read -r -s -p "Password for $(basename "$IMPORT_P12"): " p12_password || true
        echo
    else
        echo "Generating a self-signed code-signing certificate for '$IDENTITY'..."
        /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days "$DAYS" -nodes \
            -keyout "$TMP_DIR/key.pem" -out "$TMP_DIR/cert.pem" \
            -subj "/CN=$IDENTITY/OU=$TEAM/O=$ORGANIZATION" \
            -addext "basicConstraints=critical,CA:false" \
            -addext "keyUsage=critical,digitalSignature" \
            -addext "extendedKeyUsage=critical,codeSigning" \
            -addext "subjectKeyIdentifier=hash" \
            2>"$TMP_DIR/openssl.err" ||
            {
                sed 's/^/       /' "$TMP_DIR/openssl.err" >&2
                exit 1
            }
        # `security import` rejects a PKCS#12 with an empty passphrase, so the
        # bundle gets a throwaway one; it never leaves this function.
        p12_password="$(/usr/bin/openssl rand -hex 16)"
        /usr/bin/openssl pkcs12 -export \
            -inkey "$TMP_DIR/key.pem" -in "$TMP_DIR/cert.pem" \
            -name "$IDENTITY" -out "$p12" -passout "pass:$p12_password"
    fi

    # -T names the tools allowed to use the private key. codesign is the one that
    # matters; security and productsign come up when packaging the installer.
    /usr/bin/security import "$p12" -k "$KEYCHAIN" -f pkcs12 -P "$p12_password" \
        -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign -T /usr/bin/productbuild

    /usr/bin/security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" >"$TMP_DIR/imported.pem"

    # Without an explicit trust setting codesign refuses the identity outright: it
    # cannot build a chain to a trusted root, and a self-signed certificate is its
    # own root. This is the per-user trust store, so no sudo — but macOS asks for
    # authorization once.
    echo
    echo "Trusting the certificate for code signing. macOS will ask for your password."
    /usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP_DIR/imported.pem" ||
        /usr/bin/security add-trusted-cert -r trustAsRoot -p codeSign -k "$KEYCHAIN" "$TMP_DIR/imported.pem"

    # A key's partition list is a second gate in front of the ACL above, and an
    # imported key starts with an empty one. Setting it needs the keychain's own
    # password and selects keys by label — and every key `security import` creates
    # is labelled "Imported Private Key", so on the login keychain it would rewrite
    # the partition list of unrelated keys. There it is left alone: the first
    # codesign run shows one dialog, and "Always Allow" sets the same thing for
    # this key only. A dedicated keychain holds nothing but this identity, so
    # there the sweep is safe and worth doing.
    if [ "$KEYCHAIN" != "$LOGIN_KEYCHAIN" ] && [ -t 0 ]; then
        echo
        read -r -s -p "Password for $(basename "$KEYCHAIN") (blank to skip): " keychain_password || true
        echo
        if [ -n "$keychain_password" ]; then
            /usr/bin/security set-key-partition-list \
                -S apple-tool:,apple:,codesign: -s \
                -k "$keychain_password" "$KEYCHAIN" >/dev/null
        fi
    fi

    echo
    echo "'$IDENTITY' is ready (SHA-1 $(require_identity))."
    echo "Signing a test binary — if macOS asks whether codesign may use the key,"
    echo "answer \"Always Allow\" and no build will ask again."
    verify_identity
    cat <<NEXT

A default build signs with it whenever the keychain holds no Apple Development
certificate (//bazel:local_auto). To sign with it even when one does, add this
line to user.bazelrc:

    build --config=local_signed

The app's existing Keychain items were created under its old ad-hoc identity, so
each one prompts once more after the switch: the item's ACL still names the old
cdhash, and "Always Allow" is what adds this certificate to it. From then on the
ACL survives rebuilds.
NEXT
}

case "$COMMAND" in
    ensure) cmd_ensure ;;
    show) cmd_show ;;
    export) cmd_export ;;
    remove) cmd_remove ;;
    *)
        usage >&2
        exit 2
        ;;
esac
