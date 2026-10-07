# Garage project timeline digest (project chat, 2026-09-24 .. 2026-10-07)

Source: the full top-level project timeline (all pages, has_more=false). Thread internals were not read; only
what surfaced at top level. Rick = the human (author_id user_01ETaRHWGoNRi12vaMJoPrPJ). Times are UTC.
Secrets, keys, codes, UDIDs and personal data are written as [redacted].

## 1. Machines and how Rick uses them

- **M3** (`rickmark-m3`, `~/Developer/garage-rag`; earlier showed as "Mac"). Rick: "our remote M3 where i'm at the keys" (09-25).
  Rule 09-24 19:31: "Feel free to use the M3 for any odds-and-ends work that requires macOS, M4 will be doing full
  test suites on main for the time being." Holds Secretive (SSH signing key, Touch ID per commit). It runs Claude in
  the IntelliJ terminal, so Screen Recording and Accessibility go to IntelliJ IDEA. It is the place for interactive
  checks such as the store build, Validate App and installer smoke tests.
- **M4** (`rickmark-m4`, `~/Developer/garage`): the full test-suite machine (Bazel, UI suites, model tests),
  store/TestFlight builds and uploads. UI tests need Automation Mode: approve the password prompt, or run once
  `sudo automationmodetool enable-automationmode-without-authentication`. The Claude app's computer-use setting must
  allow Garage. The Dock is set to autohide so screenshots come out at 2880x1800.
- **M1 "Phobos"** (`phobos-m1`, `~/Developer/garage-rag`), added 09-28. Rick: "it is a build host only, no user
  interaction". Keys (Developer ID, Distribution, Sparkle and others) were exported from the M3 to it Mac-to-Mac as
  password-protected exports, never through the cloud. Rule 09-29 00:41: "Phobos does not prompt for git signing, so it
  can always be used to sign commits while i'm away", so signed commits and tags go to Phobos when Rick is away.
  Phobos drops offline often; Rick suspects it is from disconnecting the display. Phobos signs the appcast (#220
  `sign_appcast`). It still needed a Developer ID Installer cert (09-29).
- When a Mac's folder is offline, turn on Remote Control in the Claude app or run `claude remote-control` in the repo
  folder on that Mac. A new Mac session is attached with "[Local: use start_rc_session on my computer] ...".
- A relayed message cannot authorize a force-push, a build, or edits to `~/.claude.json`. Rick must type "go" in that
  Mac's own session/thread.
- Rick 09-26: "your Claude app has computer control as well" / "You should be able to do most of this kind of
  clicking now". Preference: drive the UI yourself with computer use instead of asking Rick to click.
- Rick 09-26: "some of those TCC dialogs can't be seen even with accessibility and screen recording". Rule: treat an
  unexplained stall as a hidden permission prompt and ask Rick to answer it.
- Rick 09-26: "The hang was caused by the identity changing, it was a permission prompt and we shouldn't need to go
  back to adhoc". Keep team signing for the UI test runner.
- `garage quit` (#115) quits any running Garage before UI runs. A leftover Garage process blocks UI tests.

## 2. Rules and preferences Rick stated (chronological)

| Date | Rule / preference (Rick's words where short) |
|---|---|
| 09-24 19:31 | M3 = macOS odds and ends; M4 = full test suites on main. |
| 09-24 22:25 | **Stacked PRs**: "for each set of related tasks, see if there's any other session that is addressing some similar part of the app, if it has a branch or PR, use that instead of main as the basis of new work." Then: "stacked PRs are resolving issues that we are having to address and coordinate here." |
| 09-24 | GitHub ruleset on main: "Commits must have verified signatures". The Secretive key must be registered as a *Signing key*, with a verified commit email. Rick asked "why dont we force push it to main"; Claude advised against it (the ruleset also applies to pushes, and a force-push bypasses CI). Do not force-push main. |
| 09-25 01:33 | Branch cleanup: "Please confirm which you suggest before actually deleting them". Propose first and never delete without his go. |
| 09-25 01:37 | "when a thread feels the work is ready it should make a PR ready for review". Later amended (below). |
| 09-25 15:50 | UI pattern: "I like the new pattern of putting logs at the bottom of the relevant page". |
| 09-25 16:04 | Load the default embedding model at boot (for search). Load the distillation model only while distilling and unload it afterwards (#99). |
| 09-25 16:25 | Sidebar order: Status on top and larger; Configuration (Sources, Models, MCP Server); Data (Documents, Facts, Search); Advanced (Database, Logs) (#100). |
| 09-25 21:18 | "each review uses the same numbers". Give every review finding a unique label instead of reusing S1..Sn across reviews. |
| 09-25 21:12 | S1 security stance: "can never serve remote clients by default, but has a power user feature in case". |
| 09-25 21:15 | Long-term direction: "more gRPC over XPC with code signing auth to prevent the use of network entirely". |
| 09-25 21:21 | App Store: "we will wait on 0.9 feedback and likely jump to 1.5 after. dev id will release in the meantime". |
| 09-25 21:29 | Model licenses: "no need for model licenses, but maybe we need the model to link out so that a user can read them". Done: each model links to its HF card and license, and no license text is bundled. |
| 09-25 21:39 | "cut the store from the alpha and move it to its own branch - its muddying the dev_id release". The alpha became Developer ID only and the store work moved to its own PR (#106). |
| 09-25 21:56 | Ideally one TLS stack (grpcio/cryptography built against `//ext/openssl`): "yep keep this for later" (post-1.5). OpenSSL is kept; BoringSSL and LibreSSL were rejected. |
| 09-26 18:48 | "You might need to cherry pick site updates into main". Site changes must land on main. |
| 09-26 23:34 | Asked for a fresh notarized build from the current head before tagging. Release from head and re-test on the same head. |
| 09-27 03:41 | "i will be fixing a few errors on the bio by hand". Do not overwrite his hand edits to the About/bio page. |
| 09-27 15:34 | models.json: "distillation (LangExtract) and inference models overlap largely. We should probably use "inference_models" in our models.json, and use some set of tags to indicate if its good for inference, distillation, both etc" (#156). |
| 09-27 16:17 | Big features go to a **`next`** branch: "this seems a v1.5.5 plan since its adds substantial features, plan on working this against a new "next" branch for the next feature release". |
| 09-27 18:43 | "move from waiting for CI for you to mark ready, to marking ready when you're good with the PR, and then use github rulesets to enforce a subset of the checks as process rather then convention". Rulesets went live 09-27 (main-next.json, release-lines.json). |
| 09-27 19:40 | "As a general rule, open PRs early as draft if there are follow ups". |
| 09-28 18:23 | Fact embeddings and clustering dedup: "(this will actually be 1.5.5)". "let's merge beta to main, then cut this work off main". |
| 09-28 20:27 | "until 1.5 final, beta is also the main channel as well". |
| 09-29 06:00 | Separate embedding tables per model for chunks and for facts: "Reduces query time as they have separate indexes and fks" (#208). |
| 09-29 06:07 | Metadata facts (email sender, subject) "should be fixed centroids for their cluster ... As they are "ground truth"". Vertices and edges are expressed in LangExtract config so the schema is extensible (#210). |
| 09-29 05:58 | Clustering: HDBSCAN is likely for images/faces. "look for native libraries that avoid large upticks in dependency"; "Perhaps this even can be done in database or a specialized non-python process"; "There is a rust version in ClusterKit". |
| 09-29 03:34 | Tip jar: "more inline with the costs of Claude and ChatGPT ... one time purchases and they are less then monthly costs of those services". Tiers went from $4.99/$9.99/$19.99 to 5 tips including Max and Ultra. |
| 09-29 20:13 | "reduce the amount of dyld based loading and binding ... inherit brittleness". Also: "calling tools via fork/exec is also brittle and should be avoided when better alternatives exist". Also: "this is why we glob most of our dependencies into PythonXPCService (... prevents duplication)". |
| 09-29 05:39 | Multi-corpus (v2): "we use command line param for stdio and a url path for determining what corpus". |
| 09-28 00:18 | Authors: a Messages conversation's participants are its authors. A group text is the "self" author plus 1..* others. This is "generic to all documents ... documents may have multiple authors". |
| 09-30 02:17 | **"next is caught up with main, prs should now target `next` unless they are a bugfix"**. Bugfixes go to main. |
| 10-05 20:21 | "We now have a garage-enterprise repo for non-FOSS features". Non-FOSS work goes to `lwm-luminx/garage-enterprise` and OSS stays in `lwm-luminx/garage-rag` (formerly rickmark/garage-rag). |
| 10-05 21:22 | Enterprise: a cluster/API endpoint (web servers plus sharded / read-only replica Postgres) and agents that run embedding and distillation on enterprise machines. It must respect AuthZ so documents are never exposed to users without rights, and it fans work out "seti@home"/"folding@home" style. "It should have more then one node do a task so that it can be verified that no-one is poisoning" (PR #5 architecture.md). |
| 10-06 01:07 | Enterprise stack: "K2 (Kotlin) ... because KMP may allow for client agents to be shared code". API server plus Windows/Linux/macOS agents on a shared Kotlin library; llama.cpp wrapped in a Kotlin interop layer; mTLS and gRPC between agents and API; PWA/TypeScript client; auth via OIDC and SCIM2; see architecture.md. The server is Ktor embedded plus grpc-java (PR #8), and can also run as a WAR (#10). The app-server briefing is PR #9. |
| ongoing | Use **Fable** for design and research threads ("Use fable to imagine a better implementation", "fork off a fable thread ..."). Opus and Sonnet were used for some implementation threads. |

Unresolved convention: on 09-27 Claude proposed **merge commits by default** (always for main->beta and beta->next
syncs, squash only for leaf PRs, "Allow rebase merging" turned off). Rick never answered in the timeline. He did use
"Create a merge commit" for #143, because GitHub's rebase-merge fails on merge-commit PRs. CLAUDE.md does not record
it; confirm with Rick.

## 3. Branch and release model (as it evolved)

- `main`. Then `v1.5-alpha` (09-25, coordinator thread: comprehensive UI tests, docs, full test pass; Developer ID
  only). Then `v1.5-beta` (by 09-27). Then `next` (09-27, feature release v1.5.5; cut from the v1.5-beta tip). Forward
  merges are PRs: alpha into beta (#162, #169), beta into next (#170, #171), main into beta (#143), beta into main
  (#218), main into next (#228). Merge these with "Create a merge commit".
- Releases so far: v1.5-alpha.1 (09-27, build 370, notarized and stapled, GitHub pre-release), alpha.2 (09-27),
  1.5 beta 1 (09-28, appcast takes pre-release tags #188), **v1.5** (tag and GitHub release by about 09-30/10-01, from
  the "App Review risks" thread). The App Store had 1.0 (0.9 build 66) in review; TestFlight builds were 465, 547, 570
  (lacks the compliance code, do not attach), 572 and 582 (5 tips).
- Final-cut procedure (agent, 09-28): merge v1.5-beta forward into main, run one full M4 pass, build the final, tag
  `v1.5` after it is verified, then the Developer ID release, the appcast entry (signed on Phobos), and the store
  submission.

## 4. Recurring procedures

- **Status reports**. Rick asks this many times a day ("all up", "status report", "what's blocked", "what's next",
  "need anything from me?"). Format that worked: Needs you / In progress / Done / Waiting, with thread links. Say when
  a report comes from thread notes rather than a fresh GitHub check. Stale lists were caught twice (#132, #145 already
  merged), so check PR state live.
- **Landed-to-main audits**. "Review all of todays work / requests and ensure they are all landed to main",
  "look for work not landed to main", and "Find me unmerged work and rebase that on main for clean PRs". These came
  up on 09-24 (several times) and 09-25.
- **Rebase/re-sign requests**. Rebase #80, #81, #82, #143, #176, #178, #179, #204, and "rebase next on main". Signed
  rebases happen on the M3 (Touch ID per commit) or Phobos. If an earlier verify was cached, the "Unverified" badge
  clears once the key is added as a signing key, with no re-push needed.
- **Test cycles**. "I've merged several PRs, time for a new test cycle". The M4 runs the full UI suite plus the model
  tests; the M3 (later Phobos) runs build, unit tests, the bundle check and `garage quit`. Pass counts seen: UI 53/53,
  later 58/58; model 3/3; unit 50/50. "if it comes back clean, do a store validation as well" means a validate-only
  check with no upload. Rick asks for "another run after with the recent changes".
- **Notarized Developer ID build** (runbook; `notarize_all` from #131): build, notarize and staple the app, build the
  .pkg from the stapled app, notarize and staple the pkg, write the build report, Rick smoke-tests the installer, sign
  the tag (Secretive on the M3, or Phobos), then GitHub (pre-)release and the appcast. It needs a notarytool keychain
  profile: `xcrun notarytool store-credentials Primary`. Do not run notarytool with the sandbox off without asking.
- **App Store upload** without the Xcode Organizer (#165; versioned framework wrapper #168; upstream rules_apple
  #3084). Then add the build to a TestFlight group and write "What to Test" notes
  (`/mnt/project-files/release/1.5-testflight-what-to-test-572.md`). Screenshots come from a UI test (#104, #189,
  window-only, sample data).
- **Export compliance**: description text drafted (local-only, standard HTTPS/TLS only). The French (ANSSI)
  declaration docs were produced, and FR approval arrived 09-29. The compliance code [redacted] is in Info.plist via
  #211 (#166 had kept ITSAppUsesNonExemptEncryption out until approval).
- **Catch-up threads**: "I'd like to continue the work from session session_... here" (about 12 times).
- **Routines** (09-27): weekly Apache AGE release / new-PG-major check against the pins ("post a short note if an
  update is available. Do not change code."); watch for Postgres 19 final and Python 3.15 final; a free-threaded
  Python blocker check (failed 10-05 because `/mnt/project-files` was missing; Rick said "fix the routine").

## 5. Product and engineering decisions (non-rule)

- Apple Silicon only; x86_64 fully removed (#76). `disable-library-validation` removed from all store entitlements
  (#78); everything is re-signed with the distribution identity.
- Postgres password: moved to the App Group data-protection keychain with helper-app launchers (#64, #69). The
  owner-only-file approach (#67) was closed.
- AGE is bundled and preloaded (#49, #57). Rick: "If AGE is on main, then the app has been starting the DB successfully".
- HEIC is read through macOS ImageIO, chosen with licenses in mind (#84). Messages chat.db: one conversation per
  document and one message per chunk (#79); contact names (#179, #199). Mail indexing (#82).
- Source queue and cancel: removing a source while busy cancels and then removes it; cancel-all clears the queue
  (#85, #91).
- Backlog note from Rick: rename the "Chunk Embedding" status to "Indexing", with one progress bar covering
  chunking, embedding and distillation.
- Free-threaded Python is not for 1.5 (grpcio and lxml re-enable the GIL). 3.14 ships with the GIL (#137); 3.15 was
  evaluated.
- Test corpus: a contrived fixture folder, plus `undefined-ui/second-brain-os` "assuming license permitting" (#128),
  which found chunker bugs (#130). Python runtime manifest from Rick's import-tracking snippet (#138).
- Cloud placeholders plan (v1.5.5, `next`): track placeholders, the Dropbox content-hash algorithm plus a general
  content hash, revert to placeholders after indexing, time/size heuristics, the Dropbox API, and OneDrive.
- Graph and facts: LangExtract into AGE vertices and edges with People/Places/Events prompts; entity graph phase 0
  (#157); fact vector tables (#208); metadata anchors (#209); graph schema in prompt config (#210); Graph page
  (#230, #233).
- Upstream: the Postgres App Store sandbox fix as an `--enable-appstore` option (#164; ported to 19 beta 4 in
  #180/#183); a v1 patch series and email drafted for pgsql-hackers. **Rick has to send it.**
- Site (garagerag.app, GitHub Pages): alpha CTA above the fold, About/"available to hire" (#154), bio (#127/#135),
  Google Analytics (#133, with download events in #264), SEO (#223), root MIT license (#224), TestFlight page
  (#163/#226), homepage diagram as an image (#202), app icon and logo (#167), design system on the site (#262).
  Copyright "Rick Mark-Penwell" (#126).
- PyPI publishing of the Python package was prepared "off of main" (09-29). libgit2 is `//ext/libgit2` (#216,
  targeting next). dlopen survey (#234: preload every bundled Postgres module).

## 6. Open / unresolved at end of timeline (10-07) and who it waits on

Waiting on **Rick**:
- Answer the merge-commit-by-default convention (proposed 09-27, never answered).
- Send the Postgres `--enable-appstore` patch email to pgsql-hackers.
- Set up the Dropbox and Entra (OneDrive) app registrations for the v1.5.5 placeholder work.
- Pick where the security design starts. This was asked repeatedly; much of it later landed (Unix sockets, XPC
  peer requirement #136/#153, gRPC token #144, MCP HTTP opt-in #159), so confirm whether anything remains.
- Old items never confirmed closed: remove the Intel downloads from the v1.0 GitHub release; the 8 stale `claude/*`
  branches (delete command is in its thread); optional garagerag.app DNS records; Sustained Execution in the developer
  portal (#103 dropped it from the profiles).
- App Store Connect: was the 1.5 version created, 1.0 pulled, 572/582 attached, and tip IAPs live? Not confirmed in
  the timeline after the "5 tips for a new submission" thread resolved 10-05.

Waiting on **threads / Claude** (threads still unresolved at the end):
- M4 testing (145 replies), M3 testing, Phobos build host, Beta tip test pass (63), and UI tests for the corpus and
  fact graph (#231/#232): long-running test and build threads.
- Upstream sandboxed Postgres fix (55 replies).
- Multiple corpora for v2 design (design.md, separate-libraries.md).
- Enterprise: architecture (PR #5), Kotlin build-out (PR #8/#10), Spring Boot briefing (PR #6), app-server briefing
  (PR #9 resolved).
- Google Analytics configuration (#264), "organize the project library", and republishing the Garage Design System
  artifact into the project library (it was published outside the project).
- "Review #227", the Loom demo script, "M3 store build upload" (the RC start failed), the Windows coordinator thread
  (shared with another Claude user; the private project can't add members), and fixing the free-threaded-blocker
  routine.
- 10-07 22:27: Rick asked to compact state ("Work through the entire history of this project and begin to export it
  to memory, skills, claude.md, and copy artifacts and data out from the project into repos"). This digest is part of
  that.

## 7. Rick's asks that never got a dedicated thread (handled inline, backlogged, or dropped)

- "Chunk Embedding" becomes "Indexing", with unified progress (09-25 02:36). Saved to memory as backlog; Claude
  offered a thread and none was started.
- A single TLS stack, building grpcio and cryptography against `//ext/openssl` (09-25 21:56). "keep this for later";
  backlog only.
- The merge vs squash vs rebase policy question (09-27 17:34). Answered by Claude; Rick never ratified it.
- "Scan and include session_01Jq7..." and "link this to the M3/M4 sessions" (09-24). Saved to memory only.
- "Is there iconography ... instead of add" (#109) and "add source cards equal height" (#108). These did get threads.
- Model licenses link-out. Folded into the checklist thread (#104).
- "Maybe we need a small folder with a contrived set of examples to work as a corpus" (09-25). Routed to the alpha
  thread; it was realized later via #128 and #231.
- "Add the Garage Design System to project library" (10-05). Done inline but did not appear; routed to the design
  system thread for a republish.

## 8. Reference links

- Release checklist artifact: https://claude.ai/code/artifact/01bcaab4-a4e5-41df-b0c7-955d6ffb0247
  (also referenced as https://claude.ai/artifact/1DSYWSziaTAY1DZo7g6qmQ)
- Garage Design System: https://claude.ai/artifact/YAi54vyk54KAm8pmiYVGWW ; "Garage":
  https://claude.ai/code/artifact/fc664d81-9d62-46e1-89bc-344b42c2f73b ; "Garage Enterprise":
  https://claude.ai/code/artifact/30c2ef74-4184-43f6-8536-dc0e2c4f03bc
- Project files mentioned: /mnt/project-files/release-review/openssl-audit.md,
  /mnt/project-files/release/1.5-testflight-what-to-test-572.md, app-store-listing/draft.md (release notes, App Review
  notes, backlog.md, findings.md, plan.md files are attached to their threads).
