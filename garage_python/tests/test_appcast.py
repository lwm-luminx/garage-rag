"""docs/appcast.xml is the Sparkle feed Developer ID builds update from.

//macapp/package:publish_appcast writes its entries on a Mac, where the signing key is; these
tests hold the committed feed to what that script checks, so a hand edit or a feed generated
some other way cannot ship an entry the app would reject, or offer an arm64-only build to an
Intel Mac, or point at a download that is not where releases are uploaded.
"""

from __future__ import annotations

import base64
import plistlib
import re
import xml.etree.ElementTree as ET

import pytest

from garage_rag.config import repo_root

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
DOWNLOADS = "https://github.com/rickmark/garage-rag/releases/download"
FEED = repo_root() / "docs" / "appcast.xml"
CNAME = repo_root() / "docs" / "CNAME"
SPARKLE_PLIST = repo_root() / "macapp" / "Sources" / "GarageApp" / "Sparkle.plist"


def _version(item: ET.Element) -> str:
    enclosure = item.find("enclosure")
    version = item.findtext(SPARKLE + "version")
    if version is None and enclosure is not None:
        version = enclosure.get(SPARKLE + "version")
    return (version or "").strip()


def _short_version(item: ET.Element) -> str:
    enclosure = item.find("enclosure")
    short = item.findtext(SPARKLE + "shortVersionString")
    if short is None and enclosure is not None:
        short = enclosure.get(SPARKLE + "shortVersionString")
    return (short or "").strip()


def feed_problems(xml: str) -> list[str]:
    """Everything wrong with a feed's entries; empty when every entry is publishable."""
    root = ET.fromstring(xml)
    if root.tag != "rss" or root.find("channel") is None:
        return ["not an RSS feed with a channel"]
    problems: list[str] = []
    seen: set[str] = set()
    for item in root.iter("item"):
        version, short = _version(item), _short_version(item)
        label = f"entry {short or '?'} ({version or '?'})"
        if not version.isdigit():
            problems.append(f"{label}: sparkle:version must be the CFBundleVersion build number")
        elif version in seen:
            problems.append(f"{label}: build {version} appears twice")
        seen.add(version)
        if not short:
            problems.append(f"{label}: no sparkle:shortVersionString")
        if "arm64" not in (item.findtext(SPARKLE + "hardwareRequirements") or "").split(","):
            problems.append(f"{label}: no sparkle:hardwareRequirements arm64, so Intel Macs would be offered it")
        if not item.findtext(SPARKLE + "minimumSystemVersion"):
            problems.append(f"{label}: no sparkle:minimumSystemVersion")
        enclosure = item.find("enclosure")
        if enclosure is None:
            problems.append(f"{label}: no enclosure")
            continue
        # The release's tag is v<short>, or that with a pre-release suffix such as -beta.1.
        tag = rf"v{re.escape(short)}(-[0-9A-Za-z][0-9A-Za-z.]*)?"
        if not re.fullmatch(
            rf"{re.escape(DOWNLOADS)}/{tag}/Garage-{re.escape(short)}\.zip", enclosure.get("url") or ""
        ):
            expected = f"{DOWNLOADS}/v{short}[-suffix]/Garage-{short}.zip"
            problems.append(f"{label}: enclosure url {enclosure.get('url')!r} is not {expected}")
        if not (enclosure.get("length") or "").isdigit() or int(enclosure.get("length", "0")) <= 0:
            problems.append(f"{label}: enclosure has no length")
        try:
            signature = base64.b64decode(enclosure.get(SPARKLE + "edSignature") or "", validate=True)
        except ValueError:
            signature = b""
        if len(signature) != 64:
            problems.append(f"{label}: enclosure has no EdDSA signature")
    return problems


def _item(**overrides: str | None) -> str:
    fields = {
        "version": "412",
        "short": "1.5",
        "hardware": "arm64",
        "url": f"{DOWNLOADS}/v1.5/Garage-1.5.zip",
        "signature": base64.b64encode(bytes(64)).decode(),
        "length": "123456789",
    }
    fields.update(overrides)
    tag = "sparkle:hardwareRequirements"
    hardware = "" if fields["hardware"] is None else f"<{tag}>{fields['hardware']}</{tag}>"
    signature = "" if fields["signature"] is None else f'sparkle:edSignature="{fields["signature"]}"'
    return f"""
    <item>
      <title>{fields["short"]}</title>
      <sparkle:version>{fields["version"]}</sparkle:version>
      <sparkle:shortVersionString>{fields["short"]}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      {hardware}
      <enclosure url="{fields["url"]}" length="{fields["length"]}" type="application/octet-stream" {signature}/>
    </item>"""


def _feed(*items: str) -> str:
    return (
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
        f"<channel><title>Garage</title>{''.join(items)}</channel></rss>"
    )


class TestTheCommittedFeed:
    def test_every_entry_is_publishable(self) -> None:
        assert feed_problems(FEED.read_text(encoding="utf-8")) == []

    def test_the_app_fetches_it_from_where_the_site_serves_it(self) -> None:
        feed_url = plistlib.loads(SPARKLE_PLIST.read_bytes())["SUFeedURL"]
        assert feed_url == f"https://{CNAME.read_text().strip()}/appcast.xml"

    def test_the_app_carries_a_real_public_key(self) -> None:
        key = plistlib.loads(SPARKLE_PLIST.read_bytes())["SUPublicEDKey"]
        assert len(base64.b64decode(key, validate=True)) == 32


class TestTheChecks:
    def test_a_generated_entry_passes(self) -> None:
        assert feed_problems(_feed(_item())) == []

    def test_a_pre_release_tag_passes(self) -> None:
        assert feed_problems(_feed(_item(url=f"{DOWNLOADS}/v1.5-beta.1/Garage-1.5.zip"))) == []

    def test_an_empty_feed_passes(self) -> None:
        assert feed_problems(_feed()) == []

    @pytest.mark.parametrize(
        ("overrides", "problem"),
        [
            ({"hardware": None}, "hardwareRequirements"),
            ({"signature": None}, "EdDSA signature"),
            ({"signature": "not base64!"}, "EdDSA signature"),
            ({"url": "Garage-1.5.zip"}, "enclosure url"),
            ({"url": f"{DOWNLOADS}/v1.4/Garage-1.5.zip"}, "enclosure url"),
            ({"url": f"{DOWNLOADS}/v1.4-beta.1/Garage-1.5.zip"}, "enclosure url"),
            ({"url": f"{DOWNLOADS}/v1.5-/Garage-1.5.zip"}, "enclosure url"),
            ({"version": "1.5"}, "build number"),
            ({"length": "0"}, "length"),
        ],
    )
    def test_a_broken_entry_fails(self, overrides: dict[str, str | None], problem: str) -> None:
        problems = feed_problems(_feed(_item(**overrides)))
        assert any(problem in p for p in problems), problems

    def test_a_build_published_twice_fails(self) -> None:
        assert any("appears twice" in p for p in feed_problems(_feed(_item(), _item())))
