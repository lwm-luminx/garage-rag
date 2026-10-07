Sign the Sparkle appcast entry for Garage 1.5 beta 1 (build 547) on this Mac (the M3, which holds the Sparkle EdDSA key).

Context: the v1.5-beta.1 GitHub pre-release is published (signed tag at 98845cbe). Its Garage-1.5.zip has sha256 538f60cc61163f0eff59b0d54753556c1609fcbe755aad50fb4cd9caa6ed56fe. PR rickmark/garage-rag#188 (against main) makes publish_appcast accept a v<version>-<suffix> tag and fixes its arm64 check.

Use a clean garage checkout; don't disturb other work in it.

1. `git fetch origin && git checkout --detach v1.5-beta.1`, then confirm `git rev-list --count HEAD` is 547.
2. Apply #188's two edits to macapp/package/publish_appcast.sh locally, without committing:
   - The tag check becomes `[[ "$tag" == "v$short" || "$tag" =~ ^v"$short"-[0-9A-Za-z][0-9A-Za-z.]*$ ]] || die "tag $tag does not match the archive's version $short"`.
   - The lipo line becomes `executable="$(plist_value "$app/Contents/Info.plist" CFBundleExecutable)"` followed by `archs="$(/usr/bin/lipo -archs "$app/Contents/MacOS/$executable")"`.
3. `aspect build //macapp/package:GarageApp --bazel-flag=--config=developer_id`, so bazel-bin holds build 547. The repo's default config signs locally, and the script refuses an archive whose build differs from bazel-bin's.
4. `mkdir -p dist && gh release download v1.5-beta.1 --repo rickmark/garage-rag --pattern Garage-1.5.zip --dir dist --clobber`, then check its sha256 matches the value above.
5. `gh release view v1.5-beta.1 --repo rickmark/garage-rag --json body --jq .body > /tmp/beta1-notes.md`
6. `aspect run //macapp/package:publish_appcast --bazel-flag=--config=developer_id -- v1.5-beta.1 --notes /tmp/beta1-notes.md`. Click Allow on the Keychain prompt.
7. Put only the new docs/appcast.xml on a branch `claude/appcast-v1.5-beta.1` off origin/main. Commit it signed with the message "Add Garage 1.5 beta 1 to the appcast". If git can't read Secretive's .pub, use `git -c user.signingkey="key::$(ssh-add -L | head -1)" commit`. Push, and open a PR to main whose body starts with these two lines:
   <!-- ccr-projects-attribution: {"github_login":"rickmark"} -->
   _Requested by **Rick**_
   Say in the body that #188 must merge first, because test_appcast rejects the v1.5-beta.1 URL without it.
8. Revert the local script edits and report the PR link, or the exact error.

Don't change the GitHub release, and don't publish anything else.
