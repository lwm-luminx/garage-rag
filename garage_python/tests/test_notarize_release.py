"""//macapp/package:notarize_all notarizes and staples the Developer ID release.

Gatekeeper needs the app stapled before the installer is built from it, so the order is: notarize
the app, staple it, build the .pkg from the stapled app, notarize the .pkg, staple the .pkg. The
script only runs on a Mac with the signing identities, so these tests run it against stand-ins for
xcrun, ditto, pkgbuild and plutil that log each call, and check the order and what it hands on.
"""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

import pytest

from garage_rag.config import repo_root

SCRIPT = repo_root() / "macapp" / "package" / "notarize_release.sh"

pytestmark = pytest.mark.skipif(not Path("/usr/bin/python3").exists(), reason="the script reads JSON with it")

# Each stand-in appends one line per call to $CALLS. ditto -x unpacks a Garage.app; notarytool
# answers with $NOTARY_STATUS; stapler marks the file it staples so later steps can see it.
STUBS = {
    "xcrun": r"""#!/bin/bash
echo "xcrun $*" >>"$CALLS"
case "$1 $2" in
    "notarytool submit")
        echo "notarized $(basename "$3")" >>"$CALLS"
        n=$(grep -c "^xcrun notarytool submit" "$CALLS")
        echo "{\"id\": \"sub-$n\", \"status\": \"$NOTARY_STATUS\", \"message\": \"done\"}" ;;
    "notarytool log") echo "log for $3" ;;
    "stapler staple") if [[ -d "$3" ]]; then touch "$3/stapled"; else touch "$3.stapled"; fi ;;
    "stapler validate") [[ -e "$3/stapled" || -e "$3.stapled" ]] ;;
    *) exit 1 ;;
esac
""",
    "ditto": r"""#!/bin/bash
echo "ditto $*" >>"$CALLS"
if [[ "$1" == "-x" ]]; then
    mkdir -p "$4/Garage.app/Contents"
    touch "$4/Garage.app/Contents/Info.plist"
else
    stapled=no; [[ -e "${@: -2:1}/stapled" ]] && stapled=yes
    echo "zipped app-stapled=$stapled" >>"$CALLS"
    touch "${@: -1}"
fi
""",
    "pkgbuild": r"""#!/bin/bash
echo "pkgbuild $*" >>"$CALLS"
if [[ "$1" == "--analyze" ]]; then
    touch "${@: -1}"
else
    stapled=no; [[ -e "$2/Garage.app/stapled" ]] && stapled=yes
    echo "packaged app-stapled=$stapled" >>"$CALLS"
    touch "${@: -1}"
fi
""",
    "plutil": r"""#!/bin/bash
echo "plutil $*" >>"$CALLS"
case "$2" in
    CFBundleShortVersionString) echo 1.5 ;;
    CFBundleVersion) echo 371 ;;
esac
""",
}


def _run(tmp_path: Path, status: str = "Accepted") -> tuple[subprocess.CompletedProcess[str], list[str], Path]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, body in STUBS.items():
        stub = bin_dir / name
        stub.write_text(body)
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    checkout = tmp_path / "checkout"
    checkout.mkdir()
    archive = tmp_path / "GarageApp.zip"
    archive.write_bytes(b"zip")
    calls = tmp_path / "calls.log"
    calls.touch()
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "BUILD_WORKSPACE_DIRECTORY": str(checkout),
        "CALLS": str(calls),
        "NOTARY_STATUS": status,
        "TMPDIR": str(tmp_path),
    }
    args = [
        "--archive",
        str(archive),
        "--keychain-profile",
        "Primary",
        "--installer-identity",
        "Developer ID Installer: Test (TEAM)",
        "--identifier",
        "me.rickmark.garage-rag.pkg",
    ]
    result = subprocess.run(["bash", str(SCRIPT), *args], env=env, capture_output=True, text=True, check=False)
    return result, calls.read_text().splitlines(), checkout


def _index(calls: list[str], prefix: str) -> int:
    matches = [i for i, line in enumerate(calls) if line.startswith(prefix)]
    assert len(matches) == 1, f"expected one call starting {prefix!r}, got {matches} in {calls}"
    return matches[0]


def test_staples_the_app_before_building_the_installer(tmp_path: Path) -> None:
    result, calls, checkout = _run(tmp_path)
    assert result.returncode == 0, result.stderr

    notarize_app = _index(calls, "notarized GarageApp.zip")
    staple_app = _index(calls, "xcrun stapler staple " + str(tmp_path))
    build_pkg = _index(calls, "packaged ")
    notarize_pkg = _index(calls, "notarized GarageInstaller_arm64.pkg")
    staple_pkg = _index(calls, "xcrun stapler staple dist/GarageInstaller_arm64.pkg")
    assert notarize_app < staple_app < build_pkg < notarize_pkg < staple_pkg

    assert calls[build_pkg] == "packaged app-stapled=yes"
    assert _index(calls, "zipped app-stapled=yes") < build_pkg
    assert (checkout / "dist" / "Garage-1.5.zip").exists()
    assert (checkout / "dist" / "GarageInstaller_arm64.pkg.stapled").exists()
    assert "sub-1" in result.stdout
    assert "sub-2" in result.stdout


def test_installer_is_not_relocatable_and_is_signed(tmp_path: Path) -> None:
    result, calls, _ = _run(tmp_path)
    assert result.returncode == 0, result.stderr

    assert "plutil -replace 0.BundleIsRelocatable -bool NO" in "\n".join(calls)
    build = next(line for line in calls if line.startswith("pkgbuild --root"))
    assert "--install-location /Applications" in build
    assert "--sign Developer ID Installer: Test (TEAM) --timestamp" in build
    assert "--version 1.5" in build


def test_a_rejected_app_stops_before_the_installer(tmp_path: Path) -> None:
    result, calls, checkout = _run(tmp_path, status="Invalid")
    assert result.returncode != 0
    assert "not accepted (Invalid)" in result.stderr
    assert "log for sub-1" in result.stderr
    assert not any(line.startswith(("pkgbuild", "xcrun stapler")) for line in calls)
    assert not (checkout / "dist" / "GarageInstaller_arm64.pkg").exists()
