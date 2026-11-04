# GarageApp

A macOS menu bar + window app that wraps a private Postgres instance and the
`garage` CLI / `garage-mcp` server for the [garage-rag](../README.md) project.
Fully self-contained: nothing from Homebrew or the system is required at runtime.

## Building

The app is built by Bazel (via the Aspect CLI, see the [repo README](../README.md)
and `CLAUDE.md` for the one-time `direnv allow` / `bazel run //tools:bazel_env`
setup). There is no SwiftPM manifest and no `swift build` / `swift run` path:
the modules depend on the Rust static libraries (`rust/*-ffi`) and the vendored
Postgres and llama.cpp that only the Bazel build provides. For an IDE
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

# Distribution (Developer ID and App Store) is built from garage-enterprise, which holds the
# signing identities, profiles and release targets; see "Signed builds" below.
```

What ends up in the bundle is declared in `bazel/garage_app.bzl` (`garage_macos_application`,
instantiated as `GarageApp` in `Sources/GarageApp/BUILD.bazel`):

- `Helpers/garage.app` and `Helpers/garage-mcp.app` — the Swift launchers
  (`//macapp/Sources/GarageCLI:garage_app`, `//macapp/Sources/GarageMCPCLI:garage_mcp_app`,
  sharing `Sources/GarageLauncher`; see `bazel/launcher_app.bzl`) that run the Rust command line
  (`rust/garage-cli`, linked statically) or its stdio MCP server in-process. Each is a small helper app bundle
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
  `garage quit` is the other way round: the launcher answers it before the CLI starts, posts
  `GarageAppLaunch.quitNotification` (a distributed notification, which the sandboxed launcher may
  send where an Apple event to the app would be refused or ask for Automation consent), and waits up
  to 30s for every running Garage to exit. The app quits as its Quit menu item does. It never
  starts the app, and says so when Garage is not running.
  `garage-mcp` does not wait for Postgres (only its tool calls use the database, and the MCP
  handshake must not sit behind a cold start) unless the app has never stored a password, and
  never mirrors its stdout (the MCP stream) into the unified log. The launcher finds the app it
  lives in by walking up from its own executable to the outermost `.app`
  (`Launcher.containingAppBundle`), which is where `Resources/schema` and `Resources/models.json` are.
  `//macapp/Sources/GarageApp:bundle_layout_test` checks this layout and runs `garage version`
  through the forwarder.
- `Resources/postgres` — Postgres 18 + pgvector + Apache AGE built from source
  (`//ext/postgres`, `//ext/pgvector`, `//ext/age`, vendored through
  `//macapp/externals:postgres_output`), with `libpq` in `Frameworks/`. AGE's Cypher
  parser is generated with the hermetic `rules_bison`/`rules_flex` toolchains, since the
  Bison 2.3 in macOS is too old for its grammar. `PostgresService` starts the server with
  every bundled module the backends load in `shared_preload_libraries` (`vector`, `pg_trgm`,
  `age`, `plpgsql`, `dict_snowball`), so the postmaster opens each once and backends inherit it
  through fork, and with `ag_catalog` last on `search_path`, so any session can run Cypher and
  `create_graph` without `LOAD 'age'` or a `SET search_path` first.
- `Resources/schema` — the SQL migrations, `Resources/postgresql.conf`, the model
  manifest and the config JSON schema.
- `XPCServices/*.xpc` — the seven helpers listed under `xpc_services`, each built on
  `GarageXPCKit` with no framework of its own. The four Rust services
  (`GarageXPCService`, `GarageIngestXPCService`, `GarageEmbedXPCService`,
  `GarageMCPServerService`) link their library statically (`rust/*-ffi`, through rules_rs),
  with libgit2 and llama.cpp inside it, so nothing is loaded at run time and no process
  needs to know where the app bundle is; the backend speaks to Postgres over its socket
  with tokio-postgres, so no `libpq` ships either. `GarageXPCKit` also holds the types the
  app and the services pass each other (`GarageAppGroup`, `GarageSockets`,
  `GaragePostgresEndpoint`, the folder-access and endpoint stores).

## The Postgres password

`PostgresService` generates the Postgres superuser password on the first launch and keeps it in
the macOS Keychain as a generic-password item (service `com.rickmark.garage.postgres`, account:
the login user). The app and the bundled `garage` / `garage-mcp` launchers read it through one
piece of code, `GaragePostgresEndpoint` in `Sources/GarageXPCKit`, which knows two keychains:

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
  builds are made from garage-enterprise (see "Signed builds").

### Signed builds

The Developer ID and App Store builds are made from
[garage-enterprise](https://github.com/lwm-luminx/garage-enterprise), which carries this repository as a
submodule. This repository's part is the seam, `bazel/platforms.bzl`: a signed distribution is a platform
that sets rules_apple's `signing_certificate_name`, `//bazel:distribution` (`developer_id` or `store`,
behind `//bazel:is_developer_id` and `//bazel:is_store`, which pick entitlements, hardened runtime and the
store-only resources) and the three provisioning-profile label flags for the app and the two launcher
helper bundles. `//bazel:macos_application.bzl`, `xcarchive.bzl`, `lipo.bzl`, `notarytool.bzl` and
`pkgbuild.bzl` are the generic rules such a repository instantiates; the identities, the profiles, the
notarize, upload and appcast scripts and their tests are not here. A fork builds ad hoc or with the local
identity above without any of them.

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

`//ext/postgres` builds either 18 (the default) or 19beta4 (pinned by
commit): `--//ext:postgres_version` selects the source repository, and each
version's sandbox patches live in `ext/postgres/pg<major>/`, the same two for
each: `appstore.patch` adds a `--enable-appstore` configure/meson option (no
System V IPC: a `flock()` on the data directory as the interlock against
orphaned backends, and process-shared pthread semaphores in the mmap'd
segment); the 19 copy is ported to 19's `PGSemaphoreShmemRequest`/
`ShmemRequestStruct` API, which is also what the upstream series against
master uses. `username.patch` is the local getpwuid() workaround. Select 19
for the whole tree (pgvector, Apache AGE's PG19 release line, the bundled
server, libpq) with:

```bash
aspect build //:macapp --config=pg19   # same as --//ext:postgres_version=19
```

Data directories are not compatible across major versions. Switching an existing
install from 18 to 19 (or back) means dumping and restoring the data folder's
`pgdata`, or running `pg_upgrade`.

## Auto-update (Developer ID only)

Developer ID builds update themselves through [Sparkle](https://sparkle-project.org),
vendored as a prebuilt framework in `//ext/sparkle` (its release tools, `generate_keys`,
`sign_update` and `generate_appcast`, are there too; garage-enterprise's appcast step runs them).
App Store builds embed no Sparkle at all — Apple rejects apps that update themselves — so the
whole thing is behind `select()`s on `//bazel:is_store`:

- `//macapp/Sources/GarageUpdater` compiles `SparkleUpdaterBackend.swift` for
  Developer ID (and local ad-hoc) builds and the inert `AppStoreUpdaterBackend.swift`
  for the store, which is also what keeps `@sparkle` out of that dependency graph.
- `Sparkle.plist` (SUFeedURL, SUPublicEDKey, SUScheduledCheckInterval) is merged
  into the app's `Info.plist` for the same configurations.

The app never shows a disabled "Check for Updates…"; when the running build
can't update itself the item is simply absent, along with "Receive Beta Updates"
below it. Whether to check automatically is Sparkle's own question, asked on the
second launch.

### Beta channel

The feed has one Sparkle channel, `beta`. An entry with no `sparkle:channel` is offered to
every install; one tagged `beta` only to installs with "Receive Beta Updates" on (the
`garage.updates.beta` default, which `SparkleChannelDelegate` answers Sparkle's
`allowedChannels(for:)` from). Sparkle still takes the highest `CFBundleVersion` it is allowed
to see, so a tester is offered a stable release once it is newer than their beta, and turning
betas off never downgrades anyone.

`publish_appcast --channel beta` tags an entry; without it the entry is on both tracks, as
1.5 beta 1 is. `test_appcast.py` rejects any other channel, since no build asks for one.

## Tip jar (App Store only)

The App Store build offers tips as in-app purchases on the splash (`Services/TipJar.swift`,
`Views/TipJarView.swift`), where the Developer ID build shows the Patreon link instead: a link to an
outside payment breaks App Review guideline 3.1.1. A tip unlocks nothing. The Developer ID build
never loads StoreKit products.

The products are Consumable in-app purchases in App Store Connect:

| Product ID | Reference name | Price (USD) |
|---|---|---|
| `me.rickmark.garage_rag.tip.small` | Small Tip | 4.99 |
| `me.rickmark.garage_rag.tip.medium` | Medium Tip | 9.99 |
| `me.rickmark.garage_rag.tip.large` | Large Tip | 19.99 |
| `me.rickmark.garage_rag.tip.max` | Max Tip | 49.99 |
| `me.rickmark.garage_rag.tip.ultra` | Ultra Tip | 99.99 |

Buttons show the App Store's localized price, so other storefronts follow App Store Connect's
equalized prices. When the store returns no products (not yet made, or not yet approved), the
splash shows no tip buttons.

`Sources/GarageApp/GarageTips.storekit` mirrors the products for local testing. In Xcode, choose it
under the Garage scheme's Run > Options > StoreKit Configuration and run the App Store configuration
to buy a tip against it; `TipJarTests` checks it lists the same products. A purchase is not unit
tested: an `SKTestSession` needs a host app, and the unhosted unit tests get `SKInternalErrorDomain`
3. Change both when a product changes.

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
- `OperationRunner` — runs the app's operations (scan, add-source, register-model, sync, …) as calls on `GarageService` (the Rust backend in `GarageXPCService`) over gRPC, logging what each reports. Dedicated runners and log streams exist for the long-running `backfill` and `enrich-facts` streams so they never block ordinary operations; cancelling one stops the work server-side.
- Backfill (`AppState.runBackfill`) — runs in `GarageEmbedXPCService` through `EmbedClient`: the Rust embed worker (`rust/garage-embed`, linked statically, with `Sources/GarageEmbedWorker` as its host) reaches the database through the backend's GarageService and the model servers through the host. The sandboxed app hosts it in its own process, since an image model reads the image files of granted folders.
- `IngestService` — runs ingestion through `GarageIngestXPCService` (the Rust ingest loop and readers, `rust/garage-ingest-ffi`, linked statically), receiving live progress and log callbacks over the connection. Ingest does not go through the CLI.
- `GarageMCPService` — owns the loopback HTTP `garage-mcp` server at `http://127.0.0.1:8787/mcp`, hosted inside the `GarageMCPServerService` XPC helper; started after Postgres and stopped before it.
- `GarageGRPCService` — owns the `GarageService` gRPC backend hosted inside the `GarageXPCService` helper, on the socket `s/grpc` in the group container (port 50051 only when that path would be too long); the Search and Documents views talk to it over gRPC-Swift, and the launchers find it through `GARAGE_GRPC_SOCKET`.
- `LlamaService` / `ModelDownloadService` — drive the `LlamaXPCService` and `ModelDownloadXPCService` helpers through the `LlamaClient` / `ModelDownloadClient` modules.
- `LlamaXPCService` runs llama.cpp in-process (`Sources/LlamaEngine`, linked from `//ext/llama_cpp` with Metal and Accelerate). Its XPC interface carries the same llama-server routes (`handleServerRequest`), which the other XPC services' embed-worker hosts call directly. For processes outside them (the launchers), it also serves the routes (`/health`, `/props`, `/v1/models`, `/v1/embeddings`, `/v1/chat/completions`, `/completion`, `/tokenize`, `/detokenize`, `/v1/rerank`) over HTTP on the socket `s/llama` in the group container, which the launchers export as `GARAGE_LLAMA_SOCKET`. `GARAGE_LLAMA_HTTP_PORT` in the helper's environment moves it to that loopback port instead; the worker then reads `embedding.llama_host` from `garage.json`. Both front ends (the NSXPC delegate and the HTTP listener) are `Sources/LlamaServiceHost`, which takes any `LlamaInferenceEngine`: the model UI tests' host app (`GarageApp_uitest`) embeds `Tests/MockLlamaXPCService` instead, the same front end on the testonly `DeterministicLlamaEngine`, under the same bundle identifier.
- `GarageImageEmbedXPCService` (`Sources/GarageImageEmbedXPCService`, on `Sources/ImageEmbedEngine`) runs CLIP-style image embedding models as Core ML packages (`image_embedding` entries of models.json, downloaded file by file into `models/<slug>/`): an image tower fed decoded pixels and a text tower fed a Gemma-style BPE tokenizer's ids, both L2-normalized into one space. It has no network listener; the app reaches it through `ImageEmbedClient`, and the embed-worker hosts in `GarageEmbedXPCService`, `GarageXPCService` and `GarageMCPServerService` through `Sources/ImageEmbedBridge`, which calls the service over NSXPC through the endpoint a second `LlamaEndpointBroker` hands over (`setImageEmbedEndpoint`).
- `XPCServiceManager` — pings all seven helpers, streams their logs into the app, runs their in-service self tests and can restart or terminate them.
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
    catalog (`data/models/models.json`, refreshed at launch from
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
