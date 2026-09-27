"""`macos_versioned_framework`: rules_apple's `macos_framework` in the versioned bundle layout.

rules_apple (5.1.0 and 5.2.0) builds every `macos_framework` flat, iOS style: its rule descriptor
for macOS frameworks sets no bundle locations, so the binary, Info.plist and resources all land at
the top of the bundle. dyld, codesign, Developer ID signing and notarization accept that, but the
Mac App Store does not: an app whose Contents/Frameworks holds a flat framework is rejected with
ITMS-90291/90292 ("Malformed Framework"). rules_apple only produces the versioned layout for an
imported framework that already has it (`apple_dynamic_framework_import`).

This macro calls `macos_framework` with //bazel:version_framework.sh as its `ipa_post_processor`,
which moves the assembled bundle into Versions/A (Info.plist and resources in Versions/A/Resources)
and adds Versions/Current and the top-level links before rules_apple signs and zips it. The
framework's own zip and the one the app embeds both go through it, and `zip --symlinks` plus the
app's bundletool keep the links. bazel/patches/README.md describes a draft rules_apple patch that
builds the same layout in rules_apple itself.
"""

load("@rules_apple//apple:macos.bzl", "macos_framework")

def macos_versioned_framework(name, **kwargs):
    """A `macos_framework` whose bundle has the versioned layout the Mac App Store requires.

    Args:
      name: The target name.
      **kwargs: Passed to `macos_framework`, except `ipa_post_processor`, which this macro sets.
    """
    if "ipa_post_processor" in kwargs:
        fail("macos_versioned_framework sets ipa_post_processor itself")
    macos_framework(
        name = name,
        ipa_post_processor = Label("//bazel:version_framework.sh"),
        **kwargs
    )
