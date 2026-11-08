#!/bin/bash
# Runs the rules_xcodeproj installer, then adds the Xcode build settings it has no
# attribute for to the generated project's project-level build settings.
#
# SKIP_EMBEDDED_FRAMEWORKS_VALIDATION: rules_apple's macos_framework produces a
# shallow bundle (Info.plist at the framework's root), which is what
# `aspect build //:macapp` ships. Xcode's Validate step on the app rejects that
# layout ("expected Versions/Current/Resources/Info.plist since the platform does not
# use shallow bundles"), so without this the Garage scheme cannot build in Xcode.
#
# DONT_RUN_SWIFT_STDLIB_TOOL: Xcode's CopySwiftLibs step scans every file under
# Contents/Frameworks for Swift runtime dependencies. Bazel has already built the
# bundle, and the Swift runtime ships with macOS 14, so the step has nothing to copy.
#
# Another repository's project (garage-enterprise's) runs this script too, naming its own project
# and UI test targets: GARAGE_XCODEPROJ (the .xcodeproj, relative to the workspace),
# GARAGE_XCODEPROJ_UITESTS (a regular expression for the UI test targets' names) and
# GARAGE_XCODEPROJ_RUNNER_ENTITLEMENTS (the runners' entitlements, absolute or relative to the
# workspace).
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <rules_xcodeproj installer> [installer args...]" >&2
  exit 1
fi

installer="$1"
shift
"$installer" "$@"

pbxproj="$BUILD_WORKSPACE_DIRECTORY/${GARAGE_XCODEPROJ:-macapp/Garage.xcodeproj}/project.pbxproj"
uitests="${GARAGE_XCODEPROJ_UITESTS:-GarageApp(Model)?UITests}"
runner_entitlements="${GARAGE_XCODEPROJ_RUNNER_ENTITLEMENTS:-macapp/Tests/GarageAppUITests/Runner.entitlements}"
case "$runner_entitlements" in
  /*) ;;
  *) runner_entitlements="$BUILD_WORKSPACE_DIRECTORY/$runner_entitlements" ;;
esac
# The installer leaves the project read-only.
chmod u+w "$pbxproj"

for setting in \
  "SKIP_EMBEDDED_FRAMEWORKS_VALIDATION = YES" \
  "DONT_RUN_SWIFT_STDLIB_TOOL = YES"; do
  name="${setting%% *}"
  grep -q "^[[:space:]]*$name = " "$pbxproj" && continue
  # The project-level configuration is the only build settings block that opens with
  # ALWAYS_SEARCH_USER_PATHS; every target inherits from it.
  /usr/bin/sed -i '' \
    "s/^\([[:space:]]*\)ALWAYS_SEARCH_USER_PATHS = NO;\$/&\\
\1$setting;/" \
    "$pbxproj"
  grep -q "^[[:space:]]*$name = " "$pbxproj" || {
    echo "error: could not add $name to $pbxproj" >&2
    exit 1
  }
done

# The UI test runners (GarageAppUITests-Runner.app and GarageAppModelUITests-Runner.app): Xcode
# signs each from its sandboxed XCTRunner template plus the test target's CODE_SIGN_ENTITLEMENTS,
# which macos_ui_test has no attribute for. A sandboxed runner's temporary folder is in its own
# container, which macOS 27 closes to the app under test, so the tests' data folders live where both
# reach: ~/Library/Caches/GarageUITests (a temporary exception in Runner.entitlements) for the
# unsandboxed builds, and the App Group container for the sandboxed store build. The group needs
# the team that owns it (an ad hoc signature leaves the runner out of it, and setup fails with Cocoa
# error 513). Only these targets' build settings change.
/usr/bin/python3 - "$pbxproj" "$runner_entitlements" "$uitests" <<'PY'
import re
import sys

path, entitlements, uitests = sys.argv[1], sys.argv[2], sys.argv[3]
settings = {
    "CODE_SIGN_ENTITLEMENTS": f'"{entitlements}"',
    "CODE_SIGN_IDENTITY": '"Apple Development"',
    "DEVELOPMENT_TEAM": "DWVXMLB45Y",
}
text = open(path).read()
target = re.compile(rf'BAZEL_LABEL = "[^"]*:(?:{uitests})";|PRODUCT_NAME = (?:{uitests});')
changed = 0


def patch(block):
    global changed
    body = block.group(2)
    if not target.search(body):
        return block.group(0)
    indent = re.search(r"\n(\s+)\S", body).group(1)
    for name, value in settings.items():
        line = f"{indent}{name} = {value};"
        body, n = re.subn(rf"\n\s+{name}(\[[^\]]*\])? = [^\n]*;", "", body)
        body = "\n" + line + body
    changed += 1
    return block.group(1) + body + block.group(3)


text = re.sub(r"(buildSettings = \{)(.*?)(\n\s*\};)", patch, text, flags=re.S)
if changed == 0:
    print(f"warning: found no UI test build settings in {path}; the UI test runners keep "
          "an ad hoc signature and no App Group, so the UI tests cannot write their data folders",
          file=sys.stderr)
else:
    open(path, "w").write(text)
    print(f"UI test runners ({uitests}): App Group entitlements and team signing in {changed} configuration(s)")
PY
