# Patches for Bazel modules

## `rules_apple_versioned_macos_framework.patch` (draft, not applied)

A draft of an upstream rules_apple change that builds `macos_framework` and
`macos_dynamic_framework` bundles in the versioned layout, which the Mac App Store requires
(ITMS-90291/90292) and which Apple documents in "Anatomy of Framework Bundles". rules_apple
5.1.0 and 5.2.0 build them flat, iOS style. The patch is against rules_apple 5.1.0 and also
applies to `main`. It is the default for every macOS framework, with no opt-in.

The patch changes these files:

- `rule_support.bzl`: `_describe_bundle_locations` gains `bundle_version`. The macOS framework
  descriptor uses `Versions/A` as its contents directory and `Resources` for resources.
- `processor.bzl`: for a versioned bundle, files placed at the bundle root (Headers, Modules)
  go in the version directory. The control file lists the links: `Versions/Current -> A` and
  `<entry> -> Versions/Current/<entry>` for each top-level entry of the version.
- `bundletool.py` and `bundletool_experimental.py`: a `bundle_symlinks` control key, written as
  zip symlink entries or as real links in tree-artifact mode.
- `partials/resources.bzl`: the root Info.plist goes to `Versions/A/Resources`.
- `macos_rules.bzl`: the install name is `@rpath/<Name>.framework/Versions/A/<Name>`, as Xcode
  sets it.

Garage builds PythonXPCService.framework with `macos_versioned_framework`
(`//bazel:macos_framework.bzl`) instead. Applying the patch as well would give the post-processor
an already versioned bundle, and it fails on that. To try the patch, drop the wrapper
(`macos_framework` in `macapp/Sources/PythonXPCService/BUILD.bazel`) and add to `MODULE.bazel`:

```starlark
single_version_override(
    module_name = "rules_apple",
    patch_strip = 1,
    patches = ["//bazel/patches:rules_apple_versioned_macos_framework.patch"],
)
```

Tested that way on 2026-09-27: the store archive validated with App Store Connect
(`VERIFY SUCCEEDED with no errors`), and `codesign --verify --deep --strict` and
`garage version` from the archived app passed. One Garage-side change is needed first:
libpq and libtesseract reach the framework through `structured_resources`
(`//macapp/externals:python_framework_libs`), so with the patch they land in
`Versions/A/Resources/Frameworks`, not beside the binary, and dyld does not find them through
`@loader_path/Frameworks`. The test added `-rpath @loader_path/Resources/Frameworks`. The proper
fix is to bundle them as code rather than as a resource.

Not done yet: rules_apple's own tests (the `test/starlark_tests` bundle-content assertions for
macOS frameworks expect the flat layout and would need updating, plus a new test for the links),
and an upstream pull request.
