# Notes

Design notes, research, release records and history from the Claude project that built Garage 1.5
("Garage / Garage Enterprise"), moved here from the project's shared folder and artifacts on 2026-10-07 so they
live with the code. They are records as written: a note whose subject has since landed or changed is not
updated, so check the code before relying on one. Engineering plans meant for the site stay in `docs/plans/`;
Enterprise designs live in `lwm-luminx/garage-enterprise` (`docs/`).

| Folder | What |
| --- | --- |
| `design/` | Page redesign notes (Status, Sources, Models, MCP, Database, menu bar), the IPC hardening brief and the cloud placeholder plan for 1.5.5. |
| `research/` | Write-ups: Dropbox online-only files, the dlopen survey, fact dedup clustering, LangExtract into an AGE graph, the OpenSSL audit, Python 3.14 / 3.15 / free-threaded 3.14t (with the blocker-check script the weekly routine runs). |
| `v2/` | Garage v2: several corpora on one Mac, and peer sync across a person's Macs. |
| `postgres-upstream/` | The plan and email draft for upstreaming `--enable-appstore`; the patch series itself is in `tools/postgres-upstream/`. |
| `release-1.5/` | Build reports, notarization runbook, release and TestFlight notes, App Review notes, the beta backlog, validation reports and the nine 1.5 reviews (`reviews/`). |
| `app-store/` | Listing copy draft and the French (ANSSI) encryption declaration package (`compliance/`). |
| `site/` | Launch post drafts, the demo video script and the homepage diagram generator. |
| `repo/` | GitHub ruleset JSON as applied, the branch survey, and two patches kept for reference. |
| `testing/` | Mac test-pass results and the UI test coverage gaps. |
| `windows.md` | Windows port onboarding and status. |
| `history/` | Thread-by-thread digest of the project (decisions, procedures, gotchas), and the project chat's rules timeline. |
| `artifacts/` | Source of the project's published artifacts (below). |

## Artifacts

The HTML here is a copy; the live pages are linked. The release checklist saves Rick's ticks into the page, so the
live page is newer than the copy.

| File | Live page |
| --- | --- |
| `artifacts/release-1.5-checklist.html` | [Garage 1.5 Release Checklist](https://claude.ai/artifact/1DSYWSziaTAY1DZo7g6qmQ) |
| `artifacts/bazel-rules-audit.html` | [Garage Bazel Rules Audit](https://claude.ai/artifact/6FZt9qDFmaau6hjvwMjLYC) |
| `artifacts/icon-directions.html` | [Garage Icon Directions](https://claude.ai/artifact/RFkh9pFsd9UPkNVdcG4zgm) (Rick chose the flat purple tile, 2026-09-27) |
| `artifacts/stage-icons.html` | [Garage Stage Icons](https://claude.ai/artifact/SmPBa5MaoNVWMvyF2wSGPQ) (not shipped) |
| `artifacts/garage-design-system/` | [Garage design system](https://claude.ai/artifact/YAi54vyk54KAm8pmiYVGWW): brand book, tokens and components. Its Plex fonts and logo images are not copied (the site carries the fonts; the logos are the app icon). |

## Left in the project, not copied

- Screenshots and images: App Store screenshot sets (1.5 alpha and beta, about 11 MB), tip jar review shots,
  icon scene renders, site hero and download-button captures, homepage diagram renders, and pictures pasted
  into threads.
- `about-rick/` (personal profile notes), provisioning profiles pasted into threads, and a `sample` trace.
- `app-store/compliance/annexe-technique-garage-1.5.pdf` (the HTML beside it is its source).
- UI hierarchy dumps from test failures (`test-results/ui-hierarchies/`).
- `enterprise/architecture.md` was a mirror of garage-enterprise's `docs/architecture.md`, which is newer.
