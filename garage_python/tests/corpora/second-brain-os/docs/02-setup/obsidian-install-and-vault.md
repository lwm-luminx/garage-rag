# Obsidian and your first vault

Obsidian is the storage half of the system. It is free, it keeps everything as
plain text files on your own machine, and it renders the links between notes as
a graph. Nothing here is stored in a company's cloud, and the files stay
readable in any text editor if you ever walk away from the app.

## Install

Download from [obsidian.md](https://obsidian.md) and install it.

If you ran the Quickstart from the [README](../../README.md), you already have
a `~/brain` folder with the starter structure in it. On the welcome screen,
click **Open folder as vault** and pick it.

If you are starting from nothing, click **Create new vault** instead. Name it
something short you will type often, `brain` works. Pick a folder on your
machine and click **Create**, then copy the contents of
[`vault-template/`](../../vault-template/) into it.

Either way, that folder is now your second brain. Everything the agent writes
lands there as markdown files.

## Make one note by hand

Do this once before automating anything, so the mechanic is not abstract.

Click the new-note icon, type a sentence, then type `[[goals]]`. The bracketed
word becomes a link to a page called `goals`, whether or not that page exists
yet. Click it and Obsidian creates the page.

That is the entire data model: notes pointing at notes. Everything the agent
does later is this, at volume, without you doing it.

## Where to put the vault

Somewhere with a stable path you can type from a terminal. Avoid a folder your
cloud sync client rewrites aggressively, because an agent writing files while a
sync client rewrites them produces conflict copies that are genuinely painful
to untangle. See [git and sync](git-and-sync.md) for the options that work.

Avoid spaces in the folder name. You will be pasting this path into commands.

## Settings worth changing now

- **Files and links → New link format:** relative path or shortest path,
  consistently. Mixed link formats are the most common cause of broken links
  after a rename.
- **Files and links → Automatically update internal links:** on.
- **Editor → Show frontmatter:** on. You want to see the metadata the agent
  writes, at least for the first weeks.

## Next

[Claude Code in the vault](claude-code-setup.md)
