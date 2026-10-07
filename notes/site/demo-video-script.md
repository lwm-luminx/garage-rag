# Garage demo video: script and shot list

Target: about 2 minutes, recorded in Loom (screen plus optional camera bubble), narrated by Rick.
Purpose: the launch/SEO push for v1.5 (site hero, Show HN first comment, Product Hunt media, directory listings).
Nothing here gets posted or shared until Rick OKs the final cut.

## The one idea the video has to land

"Claude just answered from files on my Mac, and nothing was uploaded."

The demo library is invented on purpose (Idra Voss, the Marrowgate lighthouse, the Brindlecombe lantern
festival). No model could know these facts, so every correct answer on screen is visibly coming from
the files, not from training data. Say so once, out loud.

## Demo data (never Rick's real files, mail or messages)

- **Library:** the six-file fixture corpus in `macapp/Tests/Fixtures/corpus` (the same one behind the
  App Store screenshots): a `.txt`, a `.md`, a `.pdf`, a `.docx`, an `.eml` and a Rust file. Copy it to
  `~/Garage Samples` (or `/Users/Shared/Garage Samples`) in the demo account. Mixed formats show off
  extraction without saying "extraction".
- **Optional Messages-style data:** `python garage_python/tests/fake_messages.py ~/FakeMessages --seed 7`
  writes a Faker `chat.db`. Only use it if we want a "communications stay local" beat; it adds setup and
  isn't needed for 2 minutes.
- **Where to record:** a separate macOS user account ("Garage Demo") on the M4, so first-run is genuinely
  fresh, Claude Desktop has no history, no real notifications, contacts or menu-bar clutter show up, and
  Rick's real corpus is untouched. (The app's `--data-directory` test flag gives a fresh database too, but
  the MCP launcher that Claude Desktop spawns would still look for the real app's sockets, so the
  Claude Desktop beat is not reliable that way.)

## Shot list

| # | Time | On screen | Narration (rough, Rick's own words are better) |
|---|------|-----------|--------------------------|
| 1 | 0:00 to 0:10 | garagerag.app hero, cursor on "Download for Mac" | "This is Garage. It turns the files on your Mac into a private library your AI assistant can search, and it uploads nothing." |
| 2 | 0:10 to 0:20 | Finder: the `.pkg` installs, Garage opens to the Setup Assistant | "It's a free, open-source Mac app. Install it and a setup assistant walks you through three choices." |
| 3 | 0:20 to 0:35 | Setup step 2, "Select your data": add the `Garage Samples` folder. Pause on the line "Garage keeps its index on this Mac and never sends it to the cloud." | "First, what to index. Folders, git repos, PDFs, Office files, scans, and if you want, Mail and Messages." |
| 4 | 0:35 to 0:45 | Step 3, "Select your models": the default local embedding model and the distillation model, downloads starting | "Second, models. Embeddings and the answer model run right here on your Mac with llama.cpp." |
| 5 | 0:45 to 0:55 | Step 4, "Set up your assistant": tick Claude Desktop, Finish | "Third, which assistants can use it. One click writes the MCP config for Claude Desktop, Claude Code, Cursor or LM Studio." |
| 6 | 0:55 to 1:10 | Status page ingesting, then Documents page listing the six files with their types | "Garage builds its own Postgres and pgvector index. Here's the library: text, a PDF, a Word doc, an email, even code." |
| 7 | 1:10 to 1:25 | Search page: `who kept the lighthouse during the storm`, top hit highlighted | "Search is hybrid: meaning and keywords together. I never typed 'Idra Voss', but it found her." |
| 8 | 1:25 to 1:50 | **Centerpiece.** Claude Desktop, new chat: "Using Garage, when does the Brindlecombe lantern festival parade leave, and who told me about it?" Show the tool call expanding, then the answer citing Oren Pask's email. | "Now the point of it all. Claude Desktop asks Garage, gets back just these excerpts, and answers. Everything in this library is made up, so there's no way Claude knew this already. That answer came from my files." |
| 9 | 1:50 to 2:00 | Menu bar: Ask Garage with "Who kept the Marrowgate lighthouse, and for how long?", answered locally | "And if you'd rather keep the model on your Mac too, Ask Garage answers from the menu bar." |
| 10 | 2:00 to 2:10 | Back to garagerag.app, URL on screen | "Garage is free and open source. Get it at garagerag.app." |

Cuttable if long: shot 4's download wait (trim in Loom), shot 9.

## Recording checklist

1. Demo account: Display at a resolution where a 1440 × 900 window fits; Dock auto-hide on; Do Not Disturb on;
   light appearance (or record twice, light and dark).
2. Pre-download the models once in the demo account and then reset (Database page, Reset Database) so shot 4
   doesn't wait on a 1.7 GB download, or trim the wait in Loom's editor.
3. Install Claude Desktop in the demo account and sign in (Rick's Claude account is fine; the chat history is
   new in that account). Do a dry run of shot 8 so the first real take isn't the first tool-approval prompt,
   then delete that chat.
4. Loom desktop app signed in to Rick's Loom account; "Screen + Camera" or "Screen only"; 1080p or higher.
5. Nothing else running a screen-driving job on the M4 (no XCUITest runs, no Chrome automation).
6. Record in two or three takes (setup; search + Claude; wrap) and trim in Loom rather than one perfect take.

## Afterwards (each needs Rick's OK)

- Loom share link privacy (start as "only people with the link").
- Embedding on garagerag.app (a Loom embed or a downloaded MP4 on the site) and use in the Show HN,
  Product Hunt and Reddit drafts in `/mnt/project-files/seo/launch-drafts.md`.
