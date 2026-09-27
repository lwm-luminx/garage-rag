# GarageApp

A macOS menu bar + window app that wraps a private Postgres instance and the
`garage` CLI / `garage-mcp` server for the [garage-rag](../README.md) project.
Fully self-contained: no Homebrew or system Python required at runtime.

## Building

The app is built by Bazel (via the Aspect CLI, see the [repo README](../README.md)
and `CLAUDE.md` for the one-time `direnv allow` / `bazel run //tools:bazel_env`
setup). There is no SwiftPM manifest and no `swift build` / `swift run` path:
every module, the client libraries included, depends on `PythonXPCService`,
which in turn needs PythonKit, the CPython embedding shim and the vendored
Python / Postgres / llama.cpp that only the Bazel build provides. For an IDE
loop, generate the Xcode project (`aspect run //:xcodeproj`), which carries
the app, every XPC service and every test bundle.

```bash
# Ad-hoc signed app bundle (alias of //macapp/Sources/GarageApp:GarageApp)
aspect build //macapp:GarageApp          # or: aspect build //:macapp
aspect run //:macapp                     # builds, then launches it

# The build output is a .zip, not a loose bundle; `aspect run` unpacks and
# launches it for you. To open it by hand:
unzip -q -o bazel-bin/macapp/Sources/GarageApp/GarageApp.zip -d /tmp/garage && open /tmp/garage/Garage.app

# Xcode project for editing/debugging (rules_xcodeproj; includes the XPC services and tests)
aspect run //:xcodeproj
open macapp/Garage.xcodeproj

# Unit tests
aspect test //macapp/Tests/GarageAppUnitTests:GarageAppUnitTests
aspect test //macapp/Tests/LlamaClientTests:LlamaClientTests
aspect test //macapp/Tests/LlamaModelLoaderTests:LlamaModelLoaderTests

# XCUITests (manual: quit Garage first; needs UI automation permission). Each test runs the
# real app on a throwaway --data-directory; see macapp/Tests/GarageAppUITests.
aspect run //:xcodeproj
xcodebuild test -project macapp/Garage.xcodeproj -scheme GarageAppUITests -destination 'platform=macOS'

# XCUITests of the paths that need a model (search results, Embed All, Glean Facts and the Facts
# page, MCP Try It), run the same way. Their host, GarageApp_uitest, is the app with the testonly
# MockLlamaXPCService in place of llama.cpp, so no model is downloaded.
xcodebuild test -project macapp/Garage.xcodeproj -scheme GarageAppModelUITests -destination 'platform=macOS'

# Distribution: thinned + signed apps and .pkg installers (Developer ID),
# or an App Store xcarchive
aspect build //:package                  # //macapp/package:package
aspect build //:installer                # //macapp/package:GarageInstaller (arm64 .pkg, not notarized)
aspect run //:install                    # installs the .pkg locally
aspect run //macapp/package:notarize_all # the release: notarized, stapled zip and .pkg in dist/
aspect build //macapp:xcarchive          # //macapp:GarageStore.xcarchive
aspect run //macapp:xcarchive_open       # copies the archive into Xcode's Archives folder and opens it
aspect run //macapp/package:upload_appstore --bazel-flag=--config=appstore_release  # export, validate, upload to TestFlight

# Smoke test of the embedded Python runtime, exactly as the XPC services start it
aspect run //macapp/Sources/PythonXPCService:python_embed_smoke -- /path/to/Garage.app
```

What ends up in the bundle is declared in `bazel/garage_app.bzl` (`garage_macos_application`,
instantiated as `GarageApp` in `Sources/GarageApp/BUILD.bazel`):

- `Helpers/garage.app` and `Helpers/garage-mcp.app` — the Swift launchers
  (`//macapp/Sources/GarageCLI:garage_app`, `//macapp/Sources/GarageMCPCLI:garage_mcp_app`,
  sharing `Sources/GarageLauncher`; see `bazel/launcher_app.bzl`) that embed the bundled Python and
  run `garage_rag`'s Typer app or the stdio MCP server in-process. Each is a small helper app bundle
  of its own (`LSUIElement`, no Dock icon) with its own bundle identifier
  (`me.rickmark.garage-rag.garage-cli`, `me.rickmark.garage-rag.mcp-server-cli`), entitlements and
  provisioning profile: that is what gives the launcher the application identifier the
  data-protection keychain demands, so it reads the Postgres password from the App Group without
  a prompt (see "The Postgres password" below). `Contents/Helpers` is one of the nested-code
  locations codesign, notarization and App Store validation walk.
- `MacOS/garage` and `MacOS/garage-mcp` — the stable command-line entry points, which
  `garage mcp-install --stdio` registrations and the docs name: symlinks to
  `Resources/launchers/garage` and `garage-mcp`, `/bin/sh` forwarders that `exec` the helper
  bundle's executable (`Contents/Helpers/garage.app/Contents/MacOS/garage`) by its real path.
  A forwarder copied out of the app (onto the PATH) finds Garage by bundle identifier instead,
  through Launch Services and then Spotlight (`test_launcher_scripts.py`).
  Three constraints pick this shape. Codesign treats every file in `Contents/MacOS` as nested code
  that must carry its own signature, which a script cannot, but it seals a symlink there as a
  symlink (`link_launchers.sh`, the app's `ipa_post_processor`, creates the two links before
  signing, since Bazel cannot ship a symlink as a source file). A symlink straight to the helper's
  Mach-O would leave the helper's `@executable_path` rpaths and its sandbox to be set up from a
  path in `Contents/MacOS` (dyld resolves that on current macOS, but the script does not depend on
  it). And a Mach-O forwarder would, in the App Store build, have to be sandboxed itself, and a
  sandboxed process cannot start a helper that carries its own sandbox; `/bin/sh` is not sandboxed,
  so the helper starts exactly as if run directly, with its own code identity and sandbox.
  When a command needs the database and nothing listens on its socket (or, failing that, port 14824), the launcher opens Garage.app
  hidden (`--background`: services start, no window) and waits for Postgres; it then reads the
  database password from the Keychain and exports `GARAGE_DATABASE_URL` itself. An explicit
  `GARAGE_DATABASE_URL` wins; `GARAGE_NO_APP_LAUNCH=1` fails instead of opening the app.
  `garage quit` is the other way round: the launcher answers it before Python starts, posts
  `GarageAppLaunch.quitNotification` (a distributed notification, which the sandboxed launcher may
  send where an Apple event to the app would be refused or ask for Automation consent), and waits up
  to 30s for every running Garage to exit. The app quits as its Quit menu item does. It never
  starts the app, and says so when Garage is not running.
  `garage-mcp` does not wait for Postgres (only its tool calls use the database, and the MCP
  handshake must not sit behind a cold start) unless the app has never stored a password, and
  never mirrors its stdout (the MCP stream) into the unified log. The launcher finds the app it
  lives in by walking up from its own executable to the outermost `.app`
  (`Launcher.containingAppBundle`), which is where `Frameworks/Python.framework`,
  `Frameworks/PythonXPCService.framework/site-python` and `Resources/models.json` are.
  `//macapp/Sources/GarageApp:bundle_layout_test` checks this layout and runs `garage version`
  through the forwarder.
- `Resources/postgres` — Postgres 18 + pgvector + Apache AGE built from source
  (`//ext/postgres`, `//ext/pgvector`, `//ext/age`, vendored through
  `//macapp/externals:postgres_output`), with `libpq` in `Frameworks/`. AGE's Cypher
  parser is generated with the hermetic `rules_bison`/`rules_flex` toolchains, since the
  Bison 2.3 in macOS is too old for its grammar. `PostgresService` starts the server with
  `shared_preload_libraries=age` and `ag_catalog` last on `search_path`, so any session can
  run Cypher and `create_graph` without `LOAD 'age'` or a `SET search_path` first.
- `Resources/schema` — the SQL migrations, `Resources/postgresql.conf`, the model
  manifest and the config JSON schema.
- `Frameworks/PythonXPCService.framework` — the shared runtime for the six
  `XPCServices/*.xpc` helpers listed under `xpc_services`. Its resources hold
  `site-python` (`//macapp/externals:site-python`): the standard library,
  `lib-dynload` and site-packages, used by the CLI and every XPC service, and
  `tessdata/eng.traineddata`. It lives in the framework because a sandboxed XPC service
  may read inside the frameworks it links but not elsewhere in the app bundle. The
  interpreter itself is the `Python.framework` from `//ext/python`, kept to the bare
  interpreter.
- Next to `site-python` is an empty `openssl.cnf`. `GaragePythonRuntime` exports it as
  `OPENSSL_CONF` before the interpreter starts, so neither the bundled `_ssl` nor
  `cryptography`'s own statically linked OpenSSL reads a configuration from outside the
  bundle (`cryptography`'s compiled-in default is Homebrew's). At start-up it also calls
  `truststore.inject_into_ssl()`, so `ssl`'s default contexts verify against the macOS
  trust store; the bundled OpenSSL ships no CA files.
- The framework also carries `Frameworks/libpq.dylib` and `Frameworks/libtesseract.5.5.dylib`
  (`//macapp/externals:python_framework_libs`) and links them with load commands
  (`@rpath`, through its `@loader_path/Frameworks` rpath). Every process that links the
  framework (the Python XPC services, `garage`, `garage-mcp`) therefore has them mapped
  before the App Sandbox applies, where opening them later by path is denied. Python finds
  them among the process's loaded images (`garage_rag.native`); nothing passes their paths,
  and the services never need to know where the app bundle is.

## The Postgres password

`PostgresService` generates the Postgres superuser password on the first launch and keeps it in
the macOS Keychain as a generic-password item (service `com.rickmark.garage.postgres`, account:
the login user). The app and the bundled `garage` / `garage-mcp` launchers read it through one
piece of code, `GaragePostgresEndpoint` in `Sources/PythonXPCService`, which knows two keychains:

- **The App Group keychain** (the data-protection keychain, access group
  `DWVXMLB45Y.group.me.rickmark.garage-rag`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
  never synchronized). Access there is decided by entitlements, not by a per-application access
  list: every process signed into the group whose `com.apple.application-identifier` a
  provisioning profile backs reads the item without a prompt. That is the Developer ID and App
  Store builds of the app *and of the two launcher helper bundles*, which is the whole reason the
  launchers are bundles with profiles of their own (a bare command-line tool cannot embed one, and
  without one `SecItem` answers `errSecMissingEntitlement`, -34018).
- **The login keychain**, the item every build used before, whose ACL names applications by
  designated requirement and asks "GarageApp wants to access key…" for each new signature. Builds
  with no application identifier (ad-hoc, `--config=local_signed`) still keep the password there:
  `GaragePostgresEndpoint` tries the App Group keychain first and takes -34018 as "not usable by
  this process", so nothing has to know which build it is.

Migration is the app's job: before its first read, `migrateLegacyPassword` copies a
login-keychain item into the App Group keychain (one last access prompt, if the ACL does not
already list this build) off the main thread, so a prompt never freezes the window. The old item
stays, so a build from before 1.5, which reads only the login keychain, still opens the database. Reads fall back to the login keychain until
that has happened, so a launcher started before the updated app never sees "no password". The
result is a line in the Database log (`keychain` source).

The LM Studio API token (`LMStudioTokenStore`) stays in the login keychain: only the app reads it.

## A stable local signing identity

The app keeps two secrets in the macOS Keychain — the Postgres superuser
password (`PostgresService`; in the login keychain only for builds without an application
identifier, see above) and the LM Studio API token (`LMStudioTokenStore`)
— and a login-keychain item's ACL names the application by its *designated
requirement*. For an ad-hoc signature that requirement is

```
identifier "me.rickmark.garage-rag" and cdhash H"<hash of this exact build>"
```

which a rebuild invalidates, because the cdhash is a hash of the build. That is
the "GarageApp wants to access key ..." dialog on every build, and why a build
can find the cluster it initialized yesterday but not the password to it.

Signing with a certificate anchors the requirement to the certificate instead:

```
identifier "me.rickmark.garage-rag" and certificate root = H"<hash of the cert>"
```

which no rebuild changes. `//tools/signing:local_identity` generates a
self-signed certificate for that and nothing else:

```bash
bazel run //tools/signing:local_identity          # create it (asks for your password)
bazel run //tools/signing:local_identity -- show  # what it is, and the requirement it yields
```

Then build against it by putting this in `user.bazelrc` (git-ignored):

```
build --config=local_signed
```

Things worth knowing:

- Answer **Always Allow** the first time macOS asks whether `codesign` may use
  the key. The setup script signs a test binary at the end specifically so that
  question gets asked there rather than mid-build.
- Keychain items the app created under its old ad-hoc identity prompt once more
  after the switch, for the same reason — "Always Allow" adds the certificate to
  the item's ACL, and from then on it holds.
- The identity is per-machine. To have a second machine build the *same*
  application rather than a different one, move the identity rather than
  generating another: `local_identity export ~/id.p12` on the first machine and
  `local_identity ensure --import ~/id.p12` on the second.
- `--config=local_signed` is not a distribution path. A self-signed certificate
  has no Apple-issued chain, so it cannot notarize and cannot carry hardened
  runtime (library validation rejects its Team ID) — `//bazel:codesign.bzl`
  strips `--options=runtime` for it exactly as it does for ad-hoc. Release
  builds still go through `--config=developer_id` / `--config=appstore_release`.

### App Store configuration

`--config=appstore` signs with **Apple Development** (`STORE_IDENTITY` in `bazel/signing.bzl`) and
embeds the development profile `macapp/GarageRAGDevelopmentApp.provisionprofile`, so the sandboxed
store build runs on the Macs that profile lists. An Apple Distribution–signed build with a store
profile cannot launch locally. Uploading re-signs the archive in Xcode (Organizer → Distribute App)
with Apple Distribution and the store profiles: `macapp/GarageMacAppConnect.provisionprofile` for
the app, `macapp/GarageRAGAppStoreCLI.provisionprofile` for `Contents/Helpers/garage.app` and
`macapp/GarageRAGAppStoreMCP.provisionprofile` for `Contents/Helpers/garage-mcp.app` (one per
bundle identifier; see "Provisioning profiles" below for how Organizer picks them). Run
Validate App first so Xcode confirms it re-signs the nested code (Postgres in `Resources/`, the
site-packages extensions, `Python.framework`, the two helper bundles).

`aspect run //macapp/package:upload_appstore --bazel-flag=--config=appstore_release` does the same
without Organizer: it exports the archive with `xcodebuild -exportArchive` (manual signing, Apple
Distribution, the three store profiles, which it installs into Xcode's profile folder first), then
runs `xcrun altool --validate-app` and `--upload-app`, and leaves the uploaded
`dist/Garage-<version>-<build>-AppStore.pkg`. `-- --validate-only` stops after validation and
`-- --export-only` after the export, which needs no credentials. It authenticates with an App Store
Connect API key (Users and Access → Integrations → Team Keys, role Developer or App Manager), kept
in the login keychain. It uses the item the `asc` App Store Connect CLI saves for this Mac (account
`asc:credential:<LocalHostName>`, with the key and issuer IDs in its kind field as
`asc:metadata:{"key_id":…,"issuer_id":…}`), or one labelled `ASC API Key (<LocalHostName>)`;
`GARAGE_ASC_KEYCHAIN_ACCOUNT` or `GARAGE_ASC_KEYCHAIN_LABEL` names another. Without one, store it once:

```bash
security add-generic-password -U -s me.rickmark.garage-rag.asc-api-key \
    -a <KEY ID> -j <ISSUER ID> -w "$(base64 < AuthKey_<KEY ID>.p8)"
```

`GARAGE_ASC_KEY_ID`, `GARAGE_ASC_ISSUER_ID` and `GARAGE_ASC_KEY_PATH` (the `.p8`) override the item.
The export signs with the Apple Distribution and Mac Installer Distribution keys, so the keychain may
ask once to let `codesign` and `productbuild` use them: answer **Always Allow**. To run a store build on
another Mac, add that Mac to the development profiles in the developer portal and replace the files.

`--config=appstore` is a fastbuild, so it shares the `//ext` builds (Postgres, ICU, Python,
llama.cpp, …) with the ad-hoc and Developer ID configs; only the codesign steps differ. Build the
archive you upload with `--config=appstore_release`, which is the same config plus
`--compilation_mode=opt` and therefore rebuilds everything optimized.

The store and Developer ID builds share the Postgres password through the App Group keychain (see
"The Postgres password"), so neither prompts for it. The one remaining prompt is the migration of an
item an older build left in the login keychain: answer **Always Allow** once, and the item moves.

### Provisioning profiles

The signed configurations embed a provisioning profile in the app and in each launcher helper
bundle; the profile is what backs the `com.apple.application-identifier` entitlement, and that
identifier is what the data-protection (App Group) keychain requires. The files live in `macapp/`
(`exports_files(glob(["*"]))` in `macapp/BUILD.bazel` exports them) and are selected per
configuration in `Sources/GarageApp/BUILD.bazel` and `bazel/launcher_app.bzl`:

| Bundle | App ID | `--config=developer_id` (Developer ID Application) | `--config=appstore` (macOS App Development) | Upload (Mac App Store, chosen in Xcode) |
|---|---|---|---|---|
| `Garage.app` | `me.rickmark.garage-rag` | `GarageRAGDeveloperID.provisionprofile` | `GarageRAGDevelopmentApp.provisionprofile` | `GarageMacAppConnect.provisionprofile` |
| `Contents/Helpers/garage.app` | `me.rickmark.garage-rag.garage-cli` | `GarageRAGDevIDCLI.provisionprofile` | `GarageRAGDevelopmentCLI.provisionprofile` | `GarageRAGAppStoreCLI.provisionprofile` |
| `Contents/Helpers/garage-mcp.app` | `me.rickmark.garage-rag.mcp-server-cli` | `GarageRAGDevIDMCP.provisionprofile` | `GarageRAGDevelopmentMCP.provisionprofile` | `GarageRAGAppStoreMCP.provisionprofile` |

Every profile is checked in. The upload column is not part of any Bazel configuration: Xcode
Organizer re-signs the archive with Apple Distribution and those profiles (see "App Store
configuration" above), and the three App Store files in `macapp/` are kept for that step only.
`provisioning_profile_slot` in `macapp/BUILD.bazel` stands in for a missing
file with a `manual` genrule that fails the configuration embedding it, with a message naming the
file to add; the default configuration never selects one, so a fork without the profiles still
builds. Drop the downloaded file in under that name and the slot gives way to the file.

At upload, Organizer walks the nested code and needs a Mac App Store profile per bundle
identifier: `me.rickmark.garage-rag`, `.garage-cli` and `.mcp-server-cli`. With automatic
signing it matches them by bundle identifier from the team's profiles (the App IDs must exist in
the portal with App Groups enabled); with manual signing the Distribute App sheet lists the app
and each helper and asks for a profile for each: `GarageMacAppConnect` for `Garage.app`,
`GarageRAGAppStoreCLI` for `garage.app`, `GarageRAGAppStoreMCP` for `garage-mcp.app`.
`//macapp/package:upload_appstore` writes its `ExportOptions.plist` with the same three in its
`provisioningProfiles` map, by each file's `UUID` rather than its name, since an older profile of
the same name for a previous distribution certificate may still be installed; a new helper bundle
needs a `--profile` there too.

Each helper App ID (developer portal → Identifiers → App IDs, platform macOS) needs the **App
Groups** capability with `group.me.rickmark.garage-rag` assigned; the portal writes the
team-prefixed form, `DWVXMLB45Y.group.me.rickmark.garage-rag`, into the profile, which is the
value the entitlements use for both `com.apple.security.application-groups` and
`keychain-access-groups`. Every profile then needs: for Developer ID, type *Developer ID
Application* with the Developer ID certificate; for `--config=appstore`, type *macOS App
Development* with the Apple Development certificate and this Mac's provisioning UDID (the same list
`GarageRAGDevelopmentApp` carries); for upload, type *Mac App Store Connect* with the Apple
Distribution certificate. In Xcode Organizer's Distribute App flow, manual signing asks for a
profile per bundle, the two helpers included; automatic signing finds them by App ID.

Entitlements must stay within what the profile authorizes, or codesign rejects the build (rules_apple
validates them against the profile first). `security cms -D -i <profile> | plutil -extract
Entitlements xml1 -o - -` shows what a profile allows.

## Why Postgres is built from source

Homebrew's `postgresql@18` bakes absolute `/opt/homebrew/...` paths for its
share/lib directories directly into the binary. Postgres 18's new
`extension_control_path` GUC looks like it should let you override that at
runtime — it doesn't, in practice: `CREATE EXTENSION vector` still only finds
control files at the compiled-in Homebrew path, confirmed by testing.

A from-source build with no custom `--libdir`/`--sharedir` keeps `bin/`,
`lib/`, `lib/postgresql/`, and `share/postgresql/` as plain siblings, which
Postgres resolves relative to `argv[0]` at runtime. That's genuinely
relocatable — verified by building it, copying the tree to an unrelated path,
and running `CREATE EXTENSION vector` there with zero path overrides. The Bazel
build (`//ext/postgres`, a `rules_foreign_cc` `configure_make`) configures with
`--with-icu --with-libedit-preferred --with-zlib --with-template=darwin --disable-rpath`
as an arm64 binary. ICU and zlib are built as dylibs under `//ext` and shipped
in `postgres/lib`, with `//ext/postgres:postgres_rpath` pointing the binaries at
them via `@executable_path/../lib`. Line editing for psql comes from the macOS
SDK's libedit (`/usr/lib/libedit.3.dylib`), not GPL-3.0 GNU Readline. The
standalone `libpq.dylib` in `Contents/Frameworks` gets its own install name
fixed up separately (`//ext/postgres:libpq_dylib`, signed by
`//macapp/externals:libpq`).

One more non-obvious thing found along the way: this build of `postgres`
fails to start with `FATAL: postmaster became multithreaded during startup`
unless `LC_ALL=C` is set in its environment (`PostgresService.swift` does
this). Locale initialization on this platform spins up threads before
postgres's fork-safety check runs.

## Building against Postgres 19 (beta)

The Bazel build carries two Postgres externals: `//ext/postgres` (18, the
default) and `//ext/postgres19` (19beta4, pinned by commit). Both share one
build definition (`ext/postgres/postgres.bzl`); each has its own copy of the
sandbox patch, since 19 replaced the semaphore/shmem sizing API the patch hooks
into. Select 19 for the whole tree (pgvector, Apache AGE's PG19 release line, the bundled
server, libpq) with:

```bash
aspect build //:macapp --config=pg19   # same as --//ext:postgres_version=19
```

Data directories are not compatible across major versions. Switching an existing
install from 18 to 19 (or back) means dumping and restoring the data folder's
`pgdata`, or running `pg_upgrade`.

## Auto-update (Developer ID only)

Developer ID builds update themselves through [Sparkle](https://sparkle-project.org),
vendored as a prebuilt framework in `//ext/sparkle`. App Store builds embed no
Sparkle at all — Apple rejects apps that update themselves — so the whole thing
is behind `select()`s on `//bazel:is_store`:

- `//macapp/Sources/GarageUpdater` compiles `SparkleUpdaterBackend.swift` for
  Developer ID (and local ad-hoc) builds and the inert `AppStoreUpdaterBackend.swift`
  for the store, which is also what keeps `@sparkle` out of that dependency graph.
- `Sparkle.plist` (SUFeedURL, SUPublicEDKey, SUScheduledCheckInterval) is merged
  into the app's `Info.plist` for the same configurations.

The app never shows a disabled "Check for Updates…"; when the running build
can't update itself the item is simply absent. Whether to check automatically is
Sparkle's own question, asked on the second launch.

### The signing key

Sparkle verifies every downloaded update against an EdDSA public key baked into
the app. The pair already exists: the public half is `SUPublicEDKey` in
`macapp/Sources/GarageApp/Sparkle.plist`, and the private half is in the login
Keychain of the machine that ran

```bash
aspect run //ext/sparkle:generate_keys
```

Back that Keychain item up. It is the only thing that can sign an update the
shipped app will accept, and it is never committed — losing it means minting a
new pair and persuading users of the old one to install a new build by hand.

A fork or a fresh checkout that regenerates the pair has to paste the new public
key into `Sparkle.plist`. Left as `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY`, the app
reports "This build was made without a Sparkle signing key" rather than fetching
a feed it could not verify.

### Cutting a release

Build from an up-to-date `main`. Sparkle decides what is newer by `CFBundleVersion`, which
`bazel/workspace_status.sh` stamps with the commit count of `HEAD`, so a release built from a
branch or a stale checkout can come out older than one already in the feed (the publish step
refuses that). The marketing version is `short_version_string` in
`macapp/Sources/GarageApp/BUILD.bazel`, and the release tag is `v` plus that version.

1. `aspect build //macapp/package:GarageApp` stages and signs the app, producing
   `bazel-bin/macapp/package/GarageApp.zip`: a zip of `Garage.app`, which is exactly the
   shape Sparkle wants to download. This is also the step that re-signs Sparkle's nested
   code (see below).
2. `aspect run //macapp/package:notarize_all` notarizes and staples, in the order Gatekeeper
   needs: it notarizes that archive, staples the ticket to `Garage.app`, builds and signs the
   installer from the stapled app, then notarizes and staples the installer. It writes the
   release's two files, `dist/Garage-<version>.zip` (the stapled app) and
   `dist/GarageInstaller_arm64.pkg` (a stapled installer carrying the stapled app, which
   always installs to `/Applications`). The installer is built by this script rather than by
   a build action because stapling needs the ticket, so it has to come after notarization;
   `//macapp/package:GarageInstaller` is an unnotarized installer for local installs only.
3. Add the release to the feed:

   ```bash
   aspect run //macapp/package:publish_appcast -- v1.5 --notes path/to/notes.md
   ```

   `--notes` is optional; an `.md`, `.html` or `.txt` file is embedded in the entry and shown
   in Sparkle's update window. It reads the stapled `dist/Garage-<version>.zip` from step 2,
   and refuses one whose build is not the one in `bazel-bin`. Before signing anything the
   script checks that the archive's version matches the tag, that it is notarized and
   stapled, arm64 only and newer than every entry
   already in `docs/appcast.xml`, and that the EdDSA key in the login Keychain is the one
   `SUPublicEDKey` names. It then runs `//ext/sparkle:generate_appcast` with the
   `--download-url-prefix` of that tag's GitHub release, which reads the version and
   architectures from the app, signs the entry with the Keychain key (macOS asks to allow
   access), and adds `sparkle:hardwareRequirements` `arm64` so Intel Macs are never offered
   it. The script verifies that entry against the archive and leaves `docs/appcast.xml`
   updated.
4. Publish in this order, so the feed never names a download that is not there yet. The
   site's download buttons (`docs/assets/download.js`) look for an asset named exactly
   `GarageInstaller_arm64.pkg`, the name step 2 gives the installer:

   ```bash
   gh release create v1.5 --verify-tag --title "Garage 1.5" --notes-file path/to/notes.md \
     dist/Garage-1.5.zip dist/GarageInstaller_arm64.pkg
   git add docs/appcast.xml && git commit -S -m "Add Garage 1.5 to the appcast" && git push
   ```

   `--verify-tag` makes `gh` refuse to create the release unless the signed `v1.5` tag is
   already pushed.

   Upload `dist/Garage-<version>.zip` under exactly that name: the entry's signature and
   length are of that file, and its URL is
   `https://github.com/rickmark/garage-rag/releases/download/<tag>/Garage-<version>.zip`.
   GitHub Pages serves the feed at `https://garagerag.app/appcast.xml`, the SUFeedURL.
5. Once Pages has deployed, check what users will fetch:

   ```bash
   aspect run //macapp/package:publish_appcast -- --check-live
   ```

   It downloads the feed from the SUFeedURL and fails on any enclosure that does not resolve.

`garage_python/tests/test_appcast.py` holds the committed feed to the same rules in CI, so a
hand edit that drops a signature, the arm64 requirement or the release URL fails the build.
Do not hand-edit entries: generate_appcast also signs the feed as a whole, and an edited
entry needs re-running it. `//ext/sparkle:sign_update` signs a single archive if you need to
patch an entry by hand.

Each run publishes one release, because `--download-url-prefix` applies to every archive in
the directory generate_appcast reads. That also means it builds no delta updates (they need
the previous release's archive beside the new one), so every user downloads the whole app.
`//ext/sparkle:binary_delta` is there for when that becomes worth doing.

Sparkle arrives with 1.5 (#34); the feed stays empty until the first Developer ID release is
published. v1.0 has no update check at all, so its users will have to download 1.5 themselves;
from 1.5 on, every release reaches them through the feed.

### Why the framework is re-signed

The hardened runtime turns on library validation, so a `Sparkle` dylib still
carrying the Sparkle Project's Team ID would refuse to load into Garage.
rules_apple's imported-framework processor re-signs `Sparkle.framework/Versions/B`
with the embedding app's identity when it bundles it, and `macos_lipo_app`
re-signs the nested `Updater.app`, the launcher helper bundles in `Contents/Helpers`
(with the entitlements each carries) and `XPCServices/*.xpc` on the way to
notarization.

## First-run setup assistant

On a fresh install (no `garage.firstRun.completed` default) the main window opens straight into a
four-page assistant instead of the sidebar UI:

1. **Setting things up** — starts the bundled Postgres, applies pending migrations, and brings up the
   gRPC and MCP daemons, showing each as a checklist row. It advances by itself once the database,
   schema and gRPC bridge are ready (MCP is optional here so a port clash can't trap the user).
   An install that already has sources in `~/.garage.json` or models in the database skips the rest.
2. **Select your data** — template sources (Documents, Desktop, Downloads, iCloud Drive, Dropbox,
   `~/Developer`, Messages, Mail) with unavailable ones greyed out, plus a custom folder chooser.
   "Next" sends an `AddSource` RPC for each pick; "I'll decide later" moves on without adding any.
3. **Select your models** — an optional fact-distillation preset, then text embedding presets (featured
   first; the first pick becomes the default) from `models.json`; distillation comes first so the
   second section is not missed below a long embedding list. "Next" sends `RegisterModel` for each
   embedding model, sets `facts.model`/`facts.provider` for the distillation pick, and, if enabled,
   queues GGUF downloads through the model download XPC service.
4. **Set up your assistant** — MCP server status/port and the detected client configs (Claude Desktop,
   Claude Code, Cursor, …); "Connect selected agents" registers Garage in each selected config.

The flow lives in `Services/FirstRunCoordinator.swift` (state + the commands each page runs) and
`Views/FirstRunView.swift` (the pages). It can be re-run any time from **Garage ▸ Setup Assistant…**
and skipped from any page.

**Reset Database…** relaunches into the assistant too, whether or not it was completed before. There
page 1 also creates the new, empty database and registers the sources in `~/.garage.json` again
(`AppState.finishDatabaseReset`) before offering the rest. Skipping before page 1 gets that far
finishes the reset in the background, so the main window comes up on the new database, unconfigured,
with the Status page listing the missing sources and model under Health.

## App architecture

- `PostgresService` — owns a private cluster in `~/Library/Group Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/Library/Application Support/GarageApp/pgdata`, database `garage-rag`, listening only on the socket `.s.PGSQL.14824` in the owner-only folder `s/` at the root of the group container (`GarageSockets`; loopback port 14824 only when that path would be too long). On first initialization it generates a random Postgres superuser password, stores it in the macOS Keychain, and creates the cluster with SCRAM authentication.
- `OperationRunner` — runs the app's operations (scan, add-source, register-model, sync, …) as calls on the Python `GarageService` over gRPC, logging what each reports. Dedicated runners and log streams exist for the long-running `backfill` and `enrich-facts` streams so they never block ordinary operations; cancelling one stops the work server-side.
- `IngestService` — runs ingestion through `GarageIngestXPCService` (an XPC helper that embeds Python and calls `garage_rag.ingest` directly), receiving live progress and log callbacks over the connection. Ingest does not go through the CLI.
- `GarageMCPService` — owns the loopback HTTP `garage-mcp` server at `http://127.0.0.1:8787/mcp`, hosted inside the `GarageMCPServerService` XPC helper; started after Postgres and stopped before it.
- `GarageGRPCService` — owns the `GarageService` gRPC backend hosted inside the `GarageXPCService` helper, on the socket `s/grpc` in the group container (port 50051 only when that path would be too long); the Search and Documents views talk to it over gRPC-Swift, and the launchers find it through `GARAGE_GRPC_SOCKET`.
- `LlamaService` / `ModelDownloadService` — drive the `LlamaXPCService` and `ModelDownloadXPCService` helpers through the `LlamaClient` / `ModelDownloadClient` modules.
- `LlamaXPCService` runs llama.cpp in-process (`Sources/LlamaEngine`, linked from `//ext/llama_cpp` with Metal and Accelerate). Its XPC interface carries the same llama-server routes (`handleServerRequest`), which the Python embedded in the other XPC services calls directly (`LlamaInferenceBridge`). For Python outside them (the launchers), it also serves the routes (`/health`, `/props`, `/v1/models`, `/v1/embeddings`, `/v1/chat/completions`, `/completion`, `/tokenize`, `/detokenize`, `/v1/rerank`) over HTTP on the socket `s/llama` in the group container, which the launchers export as `GARAGE_LLAMA_SOCKET`. `GARAGE_LLAMA_HTTP_PORT` in the helper's environment moves it to that loopback port instead; the Python side then reads `embedding.llama_host` from `garage.json`. Both front ends (the NSXPC delegate and the HTTP listener) are `Sources/LlamaServiceHost`, which takes any `LlamaInferenceEngine`: the model UI tests' host app (`GarageApp_uitest`) embeds `Tests/MockLlamaXPCService` instead, the same front end on the testonly `DeterministicLlamaEngine`, under the same bundle identifier.
- `XPCServiceManager` — pings all six helpers, streams their logs into the app, runs their in-service self tests and can restart or terminate them.
- `AppDelegate` — keeps the app running in the menu bar after the window closes, and signals Postgres and every helper to stop on every quit path (Cmd+Q, Dock quit, menu item).
- `AppState+LlamaModels` — decides which models `LlamaXPCService` holds: the default `llama_xpc`
  embedding model from the moment Postgres is up (and again when the default changes), so a search
  embeds its query at once, and the facts model only while a distillation run lasts (unloaded
  afterwards unless it is also the search model). Anything else loads on demand and stays until the
  Models page unloads it.
- `LlamaEndpointBroker` (owned by `XPCServiceManager`) — the on-demand loads happen inside
  `GarageXPCService`, `GarageEmbedXPCService` and `GarageMCPServerService`, and an XPC service can't
  look up its sibling `LlamaXPCService` by name (only the app can). So the broker asks
  `LlamaXPCService` for its anonymous listener's endpoint and hands it to those three, and does it again
  whenever one of the connections is interrupted or invalidated (a restart or a crash). Their "Llama
  Loader" self test is skipped until the endpoint arrives and re-runs when it does.
- Views, in sidebar order (`AppSection` / `SidebarGroup` in `Views/ContentView.swift`): **Status** on
  a row of its own, then **Configuration** (Sources, Models, MCP Server), **Data** (Documents, Facts,
  Search) and **Advanced** (Database, Logs).
  - **Status** — Health (one "All systems go" row, or one row per problem with the button that
    fixes it and the page it belongs to), Library (one bar over reading, indexing and
    gleaning, Update Everything or Stop, the running stage's own progress and the
    Scan › Read › Index › Glean trail, then the corpus figures), Index Manager (the gRPC
    backend's state and job), Helper Services (one row per XPC helper with Test, Restart and a
    chevron to its status report, self tests, errors and crash report) and the helpers' log folded
    at the bottom as Service Output. The wording lives in `Views/StatusPagePresentation.swift` as
    plain values, tested in `StatusPagePresentationTests`.
  - **Sources** — an Attention module while something cannot be read (with the button that fixes it),
    an Activity module while the pipeline runs (with one Stop), then one row per source with Scan &
    Ingest (Cancel while queued or running) and a ⋯ menu. **Update Everything** runs scan, read,
    index and glean facts as one run; **Scan & Ingest All** only scans and ingests, leaving embedding to the next
    automatic update. Sources are added from
    location cards (the setup assistant's eight locations), **Add Folder…**, or **Custom Source…**,
    whose Name fills itself in from the folder. Automatic Updates is an optional persisted schedule
    that scans, ingests every source and backfills every registered model, optionally also at launch.
  - **Models** — three tabs. **Overall** has one card each for search (embedding) and distillation,
    with a headline, its one action (Embed All, Glean Facts) and Manage…. **Embedding** lists one row
    per model (state, actions, details with SHA-256 Verify), unregistered presets from the model
    catalog (`docs/.data/models.json`, refreshed at launch from
    `https://garagerag.app/.data/models.json`) with Add, a Custom model… form, and Test an Embedding.
    **Distillation** holds the facts-model presets and the fact prompts editor. The Providers box lists
    each model Llama XPC holds, with Unload, and keeps the LM Studio API token in the login Keychain,
    passed as `GARAGE_LMSTUDIO_API_TOKEN` to the gRPC server.
  - **MCP Server** — the server's state and tool count, Connected Assistants (Connect, Update,
    Disconnect per client config) and Try It (tool tester and prompt playground).
  - **Database** — Postgres status (Start, Restart, Stop), the connection URL, schema updates,
    Contents (corpus counts, size on disk), Backups (**Back Up…**, **Restore…**), **Reset
    Database…** under Start Over, and Postgres's own output folded at the bottom.

The app-managed HTTP MCP server has its own lifecycle and logs. Claude
Desktop/Code can instead spawn the bundled `garage-mcp` over stdio when
registered with `garage mcp-install --stdio`; this allows both connection modes.
The app hands the authenticated database URL to its XPC helpers as
`GARAGE_DATABASE_URL`. A stdio registration names the bundled `garage-mcp`,
which starts the app if needed and reads the password from the Keychain, so the
client's config carries no database URL or password. Signed builds read it from
the App Group keychain without a prompt; a locally signed or ad-hoc build may
show a login-keychain prompt on the first connection from a launcher (choose
Always Allow).

The Database page provides the backup, restore and reset controls. Backups are
PostgreSQL custom-format dumps; restore replaces the private Garage database,
while reset recreates it empty.
