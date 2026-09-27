"""//macapp/package:upload_appstore exports, validates and uploads the Mac App Store build.

The script only runs on a Mac with the signing identities and an App Store Connect API key, so these
tests run it against stand-ins for ditto, plutil, security, xcodebuild, pkgutil and xcrun that log
each call, and check the order, the export options, and where the API key goes.
"""

from __future__ import annotations

import os
import plistlib
import stat
import subprocess
from pathlib import Path

import pytest

from garage_rag.config import repo_root

SCRIPT = repo_root() / "macapp" / "package" / "upload_appstore.sh"

pytestmark = pytest.mark.skipif(not Path("/usr/bin/python3").exists(), reason="the script writes a plist with it")

KEY = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n"

# Each stand-in appends one line per call to $CALLS. A profile file holds "<name>|<uuid>", which
# `security cms -D` passes through and plutil reads back. The keychain item exists unless $NO_KEY
# is set; altool records whether it found the key and answers with $VALIDATE_STATUS.
STUBS = {
    "ditto": r"""#!/bin/bash
echo "ditto $*" >>"$CALLS"
mkdir -p "$2"
touch "$2/Info.plist"
""",
    "plutil": r"""#!/bin/bash
case "$2" in
    ApplicationProperties.CFBundleShortVersionString) echo 1.5 ;;
    ApplicationProperties.CFBundleVersion) echo 380 ;;
    Name) cut -d'|' -f1 "$6" ;;
    UUID) cut -d'|' -f2 "$6" ;;
    *) exit 1 ;;
esac
""",
    "security": r"""#!/bin/bash
echo "security $1" >>"$CALLS"
case "$1" in
    cms) cat "$4" ;;
    find-generic-password)
        [[ -z "${NO_KEY:-}" ]] || exit 44
        # $ITEM picks the stored item: this script's own (default); the `asc` CLI's, found by
        # account, with its IDs in the kind field ("asc") or without them ("bare"), whose secret
        # is hex, as `security -w` prints multi-line data; or a labelled one holding JSON ("json").
        case "${ITEM:-service}" in
            service) [[ "$2 $3" == "-s me.rickmark.garage-rag.asc-api-key" ]] || exit 44 ;;
            asc|bare) [[ "$2 $3" == "-a asc:credential:rickmark-m4" ]] || exit 44 ;;
            json) [[ "$2 $3" == "-l ASC API Key (rickmark-m4)" ]] || exit 44 ;;
        esac
        if [[ "$*" == *" -w"* ]]; then
            case "${ITEM:-service}" in
                service) printf '%s' "$KEY" | base64 | tr -d '\n' ;;
                asc|bare) printf '%s' "$KEY" | od -An -tx1 | tr -d ' \n' ;;
                json) python3 -c 'import json, os
print(json.dumps({"key_id": "KEY123", "issuer_id": "issuer-uuid", "private_key": os.environ["KEY"]}))' ;;
            esac
        else
            echo 'keychain: "/Users/rick/Library/Keychains/login.keychain-db"'
            echo 'attributes:'
            case "${ITEM:-service}" in
                service)
                    echo '    "acct"<blob>="KEY123"'
                    echo '    "icmt"<blob>="issuer-uuid"' ;;
                asc)
                    echo '    "acct"<blob>="asc:credential:rickmark-m4"'
                    echo '    "desc"<blob>="asc:metadata:{"key_id":"KEY123","issuer_id":"issuer-uuid"}"' ;;
                bare) echo '    "acct"<blob>="asc:credential:rickmark-m4"' ;;
                json) echo '    "labl"<blob>="ASC API Key (rickmark-m4)"' ;;
            esac
        fi ;;
    *) exit 1 ;;
esac
""",
    "scutil": r"""#!/bin/bash
echo rickmark-m4
""",
    "xcodebuild": r"""#!/bin/bash
echo "xcodebuild $1" >>"$CALLS"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -exportPath) export_path="$2"; shift 2 ;;
        -exportOptionsPlist) cp "$2" "$(dirname "$CALLS")/ExportOptions.plist"; shift 2 ;;
        *) shift ;;
    esac
done
mkdir -p "$export_path"
echo "exported" >"$export_path/Garage.pkg"
""",
    "pkgutil": r"""#!/bin/bash
echo "pkgutil $1" >>"$CALLS"
""",
    "xcrun": r"""#!/bin/bash
echo "xcrun $*" >>"$CALLS"
key="$API_PRIVATE_KEYS_DIR/AuthKey_KEY123.p8"
if [[ -f "$key" ]] && [[ "$(cat "$key")" == "$(printf '%s' "$KEY")" ]]; then
    echo "key found" >>"$CALLS"
    echo "$API_PRIVATE_KEYS_DIR" >"$(dirname "$CALLS")/keydir"
fi
[[ "$2" == "--validate-app" ]] && exit "${VALIDATE_STATUS:-0}"
exit 0
""",
}

PROFILES = {
    "me.rickmark.garage-rag": "GarageMacAppConnect|UUID-APP",
    "me.rickmark.garage-rag.garage-cli": "GarageRAGAppStoreCLI|UUID-CLI",
    "me.rickmark.garage-rag.mcp-server-cli": "GarageRAGAppStoreMCP|UUID-MCP",
}


def _run(tmp_path: Path, *extra: str, **env: str) -> tuple[subprocess.CompletedProcess[str], list[str], Path]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, body in STUBS.items():
        stub = bin_dir / name
        stub.write_text(body)
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    archive = tmp_path / "runfiles" / "GarageStore.xcarchive"
    archive.mkdir(parents=True)
    args = ["--archive", str(archive), "--team", "DWVXMLB45Y"]
    for bundle_id, content in PROFILES.items():
        profile = tmp_path / "runfiles" / f"{content.split('|')[0]}.provisionprofile"
        profile.write_text(content)
        args += ["--profile", f"{bundle_id}={profile}"]
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    home = tmp_path / "home"
    home.mkdir()
    logs = tmp_path / "logs"
    logs.mkdir()
    calls = logs / "calls"
    calls.touch()
    result = subprocess.run(
        ["bash", str(SCRIPT), *args, *extra],
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "BUILD_WORKSPACE_DIRECTORY": str(workspace),
            "HOME": str(home),
            "TMPDIR": str(tmp_path),
            "CALLS": str(calls),
            "KEY": KEY,
            **env,
        },
        capture_output=True,
        text=True,
        check=False,
    )
    return result, calls.read_text().splitlines(), workspace


def _steps(calls: list[str]) -> list[str]:
    return [c for c in calls if c.startswith(("xcodebuild", "pkgutil", "xcrun", "key found"))]


def test_exports_validates_then_uploads(tmp_path: Path) -> None:
    result, calls, workspace = _run(tmp_path)
    assert result.returncode == 0, result.stderr
    assert _steps(calls) == [
        "xcodebuild -exportArchive",
        "pkgutil --check-signature",
        "xcrun altool --validate-app -f dist/Garage-1.5-380-AppStore.pkg -t macos"
        " --apiKey KEY123 --apiIssuer issuer-uuid",
        "key found",
        "xcrun altool --upload-app -f dist/Garage-1.5-380-AppStore.pkg -t macos"
        " --apiKey KEY123 --apiIssuer issuer-uuid",
        "key found",
    ]
    assert (workspace / "dist" / "Garage-1.5-380-AppStore.pkg").read_text() == "exported\n"
    # The key lived only in the script's temporary folder, which is gone.
    assert not Path((tmp_path / "logs" / "keydir").read_text().strip()).exists()


def test_export_options_name_every_bundles_store_profile(tmp_path: Path) -> None:
    result, _, _ = _run(tmp_path, "--export-only")
    assert result.returncode == 0, result.stderr
    with (tmp_path / "logs" / "ExportOptions.plist").open("rb") as f:
        options = plistlib.load(f)
    assert options["method"] == "app-store-connect"
    assert options["signingStyle"] == "manual"
    assert options["signingCertificate"] == "Apple Distribution"
    assert options["teamID"] == "DWVXMLB45Y"
    assert options["provisioningProfiles"] == {
        "me.rickmark.garage-rag": "GarageMacAppConnect",
        "me.rickmark.garage-rag.garage-cli": "GarageRAGAppStoreCLI",
        "me.rickmark.garage-rag.mcp-server-cli": "GarageRAGAppStoreMCP",
    }
    installed = tmp_path / "home" / "Library" / "Developer" / "Xcode" / "UserData" / "Provisioning Profiles"
    assert sorted(p.name for p in installed.iterdir()) == [
        "UUID-APP.provisionprofile",
        "UUID-CLI.provisionprofile",
        "UUID-MCP.provisionprofile",
    ]


def test_export_only_needs_no_key_and_contacts_nothing(tmp_path: Path) -> None:
    result, calls, workspace = _run(tmp_path, "--export-only", NO_KEY="1")
    assert result.returncode == 0, result.stderr
    assert not [c for c in calls if c.startswith(("xcrun", "security find"))]
    assert (workspace / "dist" / "Garage-1.5-380-AppStore.pkg").exists()


def test_validate_only_does_not_upload(tmp_path: Path) -> None:
    result, calls, _ = _run(tmp_path, "--validate-only")
    assert result.returncode == 0, result.stderr
    assert any("--validate-app" in c for c in calls)
    assert not any("--upload-app" in c for c in calls)


def test_missing_key_fails_before_the_export(tmp_path: Path) -> None:
    result, calls, _ = _run(tmp_path, NO_KEY="1")
    assert result.returncode != 0
    assert "security add-generic-password -U -s me.rickmark.garage-rag.asc-api-key" in result.stderr
    assert not _steps(calls)


def test_rejected_validation_stops_the_upload(tmp_path: Path) -> None:
    result, calls, _ = _run(tmp_path, VALIDATE_STATUS="1")
    assert result.returncode != 0
    assert "rejected" in result.stderr
    assert not any("--upload-app" in c for c in calls)


def test_needs_bazel_run(tmp_path: Path) -> None:
    result = subprocess.run(
        ["bash", str(SCRIPT)],
        env={k: v for k, v in os.environ.items() if k != "BUILD_WORKSPACE_DIRECTORY"},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert "aspect run //macapp/package:upload_appstore" in result.stderr


def test_reads_a_json_item_labelled_for_this_mac(tmp_path: Path) -> None:
    result, calls, _ = _run(tmp_path, "--validate-only", ITEM="json")
    assert result.returncode == 0, result.stderr
    assert "key found" in calls
    assert any("--apiKey KEY123 --apiIssuer issuer-uuid" in c for c in calls)


def test_reads_the_asc_clis_item_and_its_metadata(tmp_path: Path) -> None:
    result, calls, _ = _run(tmp_path, "--validate-only", ITEM="asc")
    assert result.returncode == 0, result.stderr
    assert "key found" in calls
    assert any("--apiKey KEY123 --apiIssuer issuer-uuid" in c for c in calls)


def test_an_item_without_ids_takes_them_from_the_environment(tmp_path: Path) -> None:
    result, calls, _ = _run(tmp_path, "--validate-only", ITEM="bare")
    assert result.returncode != 0
    assert "GARAGE_ASC_KEY_ID and GARAGE_ASC_ISSUER_ID" in result.stderr
    assert not _steps(calls)

    (tmp_path / "again").mkdir()
    result, calls, _ = _run(
        tmp_path / "again",
        "--validate-only",
        ITEM="bare",
        GARAGE_ASC_KEY_ID="KEY123",
        GARAGE_ASC_ISSUER_ID="issuer-uuid",
    )
    assert result.returncode == 0, result.stderr
    assert "key found" in calls
