# Garage 1.5 pre-release review: docs and garagerag.app (v6)

**Verdict: ship after 3 small doc fixes.** The page names, buttons, first-run assistant, Update Everything, Indexing, schema, links and Apple Silicon wording all match 1.5. Two things need fixing: the MCP "loopback only" claims contradict `--allow-remote`, and the site's installer download doesn't line up with the release steps. A third fix, the App Store install path, applies only if the store build ships with 1.5.

Reviewed tree: `review-tree` at 0a35384 (#102 head). Read-only; nothing edited.

## Checks that passed

- **Config schema:** `garage_rag.cli config schema --path <scratch>` run against the review tree is byte-identical to `docs/.data/garage.schema.json`.
- **Internal links:** a script over all 13 `docs/**/*.md` files resolved every `relative_url`, `href` and Markdown link, plus every `#anchor`, against file URLs, `permalink` and `redirect_from`. None are broken. The only flags are 4 relative `.md` links (see V6-N6).
- **Apple Silicon only:** there is no Intel, x86_64 or universal wording or download link in `docs/`, `README.md` or `macapp/README.md`. The only "Intel" mention is macapp/README.md:385, which correctly says Intel Macs are never offered an update.
- **UI wording matches `macapp/Sources/GarageApp/Views`:**
  - Sidebar order: Status, then Configuration / Data / Advanced.
  - Status page: Health ("All systems go"), Indexing with the Scan › Ingest › Embed › Distill trail, Index Manager, Helper Services with Test/Restart, Service Output.
  - Update Everything (on both Status and Sources), Automatic Updates, Scan & Ingest / Cancel, Add Folder…, Custom Source….
  - Models tabs Overall / Embedding / Distillation, Providers box with Unload, Glean Facts.
  - MCP Server page: Connect / Update / Disconnect, Try It.
  - Database page: Back Up… / Restore… / Reset Database… / Back Up First…; Skip setup; Setup Assistant…; Report a Bug (⇧⌘B); menu bar Ingest Now.
- **Privacy policy §5 matches the code:**
  - `ModelCatalog.refresh` fetches `https://garagerag.app/.data/models.json` at launch.
  - Model downloads come only from `huggingface.co`.
  - The Sparkle feed URL matches `Sparkle.plist`.
  - There is no telemetry or analytics code. No other hosts appear in `macapp/Sources`.
- **Stale versions:** there is no stale 0.9 or 1.0 where 1.5 is meant. The guide says "Garage 1.5" (guide.md:11) and `short_version_string` is "1.5". macapp/README.md:419 "v1.0 has no update check" is correct history. See V6-N3 for the Python package.
- **CLI commands and MCP tools:** every `garage` command and flag the docs use exists (`add-source --kind sqlite|maildir`, `register-model --dims`, `drop-model --yes`, `backfill --model`, `enrich-facts --stale-only`, `config init --user`, `mcp-install --target/--stdio`). The seven `rag_*` MCP tools in the FAQ and guide match `mcp_server/server.py`.

## Findings (most severe first)

### S1. Should fix: two pages say the MCP server can never serve remote clients, but `--allow-remote` exists
`cli.py:1319` has `--allow-remote`. docs/privacy.md:161, troubleshooting.md:141 and privacy-policy.md:59 all describe it. Two places deny it:
- **docs/support/privacy-policy.md:78** says: "binds exclusively to `127.0.0.1` … preventing web pages and remote networks from accessing your corpus." That contradicts §4 of the same policy (line 59).
  - Proposed: "**Loopback by default**: The HTTP MCP server listens only on `127.0.0.1` unless you start it with `--allow-remote`, and it checks the Host and Origin headers so web pages cannot reach your corpus."
- **docs/support/guide.md:215** says: "strictly binds to `127.0.0.1` … It will refuse remote bindings".
  - Proposed: "The HTTP MCP server binds to `127.0.0.1` with DNS-rebinding protection and host validation. It refuses any other address unless you pass `--allow-remote`; then add `--allow-host` for each name clients use."
- **docs/support/faq.md:258** says "always-on DNS rebinding protection". Troubleshooting.md:141 says the Host check is off under `--allow-remote` with no `--allow-host`.
  - Proposed: "…includes DNS rebinding protection and Host validation (on by default; see Troubleshooting for `--allow-remote`)."

### S2. Should fix: the site's installer download and the release steps don't line up
- **docs/assets/download.js:12** looks for the release asset `GarageInstaller_arm64.pkg`. The `pkgbuild` rule (macapp/package/BUILD.bazel:40, no `out`) produces `GarageInstaller.pkg`.
- **macapp/README.md:358-417** ("Cutting a release") never builds or uploads the `.pkg`. Step 4 uploads only `dist/Garage-<version>.zip`. It also never creates the release: `gh release upload` fails when no release exists yet.
- **Effect:** the "Download for Mac" and "Download installer" buttons fall back to the releases page. The page's promise of a "notarized installer" (index.md:15, :84) depends on someone uploading it by hand under the right name.
- Proposed new step 4 in macapp/README.md:
  ```bash
  aspect build //:installer   # notarize_all (step 2) already notarized it
  cp bazel-bin/macapp/package/GarageInstaller.pkg dist/GarageInstaller_arm64.pkg
  gh release create v1.5 --title "Garage 1.5" --notes-file path/to/notes.md \
    dist/Garage-1.5.zip dist/GarageInstaller_arm64.pkg
  ```
  Also add "Upload the installer as `GarageInstaller_arm64.pkg`; the site's download button looks for that name (docs/assets/download.js)." Alternatively, set `out = "GarageInstaller_arm64.pkg"` on the pkgbuild target.
- `docs/appcast.xml` is consistent with the README: it is an empty channel, and its header comment matches the `publish_appcast` flow and `test_appcast.py`.

### S3. Should fix, only if the App Store build ships with 1.5: the docs cover only the .pkg
Only privacy-policy.md:69 mentions the App Store. The store build is sandboxed (`Garage.entitlements`: app-sandbox) and asks for extra access that the Developer ID build does not:
- first run: "Grant disk access… **Select Root Hard Drive…**" (FirstRunView.swift:469-476);
- Sources page: "**Select Disk…**" (SourcesPresentation.swift:343-345).

The docs never mention either:
- **Install:** index.md:91-97 ("After installing") and guide.md:39-57. Proposed: "Get Garage from the Mac App Store or download the installer below. Both use the same data folder." Add an App Store link once it exists.
- **Permissions:** guide.md:220-232 (§6) and troubleshooting.md:84-97. Proposed addition: "**App Store version:** Garage runs in the macOS sandbox. On the setup assistant's sources page, or from **Select Disk…** at the top of Sources, choose your startup disk (Macintosh HD) once so Garage can read the folders you add. Messages and Mail still need Full Disk Access."
- **Logs:** troubleshooting.md:183 gives the log folder for the Developer ID build only. Add the sandboxed build's location (inside the app's container), or say "the Logs page shows the folder."

### Notes

- **N1. Setup assistant gives the old data path.** FirstRunView.swift:342 says "Garage keeps its database in ~/Library/Application Support/GarageApp." The docs (guide.md:55, privacy-policy.md:46, troubleshooting.md:55) give the App Group container. That path is only a symlink on Developer ID builds and doesn't exist for the store build. This is app wording, not docs. Suggest: "Garage keeps its database on this Mac, in its data folder."
- **N2. Help menu item name.** "Garage Support Guide" (GarageApp.swift:32) opens `troubleshooting.html` (BugReport.swift:11), not `support/guide.html`. Either rename the item to "Garage Troubleshooting" or point it at the guide.
- **N3. The Python package still reports 0.1.0.** `garage_rag/__init__.py:8` has `__version__ = "0.1.0"`, and pyproject.toml:3 has `version = "0.1.0"`. So `garage version` prints "garage v0.1.0" in the 1.5 app, and `service/server.py:141` returns it too. contact.md:34 asks reporters for "Garage version". Bump to 1.5.0 or have `garage version` print the app version, so bug reports aren't confusing.
- **N4. "Alpha" labels left over from the pre-release.**
  - README.md:18 says "The current version is 1.5, in alpha."
  - docs/plans/v1.5.md:9 ("Status (1.5 alpha). None of the milestones below has landed") is published on the site at `/plans/v1.5.html`, as is `/plans/v1.5-research.html`.
  - Either drop "in alpha" and add `plans` to `exclude:` in docs/_config.yml, or retitle the status line "Status at 1.5 release".
- **N5. The Facts page is only named in passing.** guide.md:71 says only "Documents, Facts and Search browse and query". The Facts page (FactsView.swift) has Source/Kind/Class filters and a detail pane with Open Document, Facts from This Document and Reveal. Proposed addition at the end of guide.md:180: "Browse the results on the **Facts** page: filter by source, kind or class, and select a fact to see the passage it came from, open its document, or list every fact from that document."
- **N6. Relative `.md` links.**
  - architecture.md:107 and :115, plans/v1.5.md:1118 and plans/v1.5-research.md:9 link to `*.md`.
  - They work on Pages, because `actions/jekyll-build-pages` uses the github-pages gem with jekyll-relative-links. They would 404 under the Jekyll 4.4 `docs/Gemfile`, which doesn't list that plugin.
  - Use `{{ '/attribution.html' | relative_url }}` like the other pages, or add `jekyll-relative-links` to the Gemfile.
- **N7. Logs page tab missing from the docs.** The Logs page's first tab, "Unified Log" (LogsView.swift:10), is missing from troubleshooting.md:181 and guide.md:74. Proposed: "…shows every log live: the Unified Log, Postgres, App, …".
- **N8. Privacy policy §5: two small gaps.**
  - Model downloads start at `huggingface.co` but are served from Hugging Face's CDN. Say "from Hugging Face (`huggingface.co` and its download servers)".
  - Report a Bug can open a pre-filled GitHub issue in your browser. That happens only when you choose to, and you see it first. It could get a bullet: "**Bug reports.** Only when you choose to, Report a Bug opens a pre-filled GitHub issue in your browser; nothing is sent until you submit it there."
- **N9. Website privacy.** The site's download.js (docs/assets/download.js:11) calls `api.github.com` from the visitor's browser. The privacy policy covers the app, not the site. Optionally add under §5: "The download page asks GitHub's API for the latest release when you visit it."
- **N10. Screenshots.** The site has none: `docs/assets` holds only the logo, favicon, css and js. So there are no out-of-date screenshots, but also nothing that shows the 1.5 UI.
- **N11. README dedication.** README.md:193-207 ("Dedication") is a personal statement addressed to an unnamed person. It is not on the site, but every site page links to the repo (nav "GitHub ↗"). This is the owner's call; I'm flagging it only because release visitors will reach it from the download page.
