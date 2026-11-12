---
layout: default
title: Parser isolation
description: Read every document in a helper process, behind a validation layer, so a file that crashes or hangs a parser costs that file and nothing else, never the app or its database.
date: 2026-11-12
status: Proposed
status_kind: proposed
---

# Parser isolation

## The problem

On 2026-11-11 one PDF in a Dropbox folder crashed Garage 1.7 build 1228 and 2.0 build 1256 three times in an evening. Each
crash took down more than ingest. The file is an ordinary 160-page book whose tool chained every
page one level below the last, so its page tree nests 161 deep. pdf_oxide walks that tree
recursively at about 3 KB of stack per level, which overflowed the 512 KB of the GCD worker
that ingest runs on.

Beyond ingest, each crash did this:

- The App Store build hosts the ingest service in the app's own process (`GarageInProcessServices`),
  because only the app can read the folders the person granted. So a parser crash ends the app.
- The app's Postgres outlives it. On the next launch the new server refuses the cluster while the
  leftover answers, until the leftover shuts down a minute later and every source fails.
- The next Dropbox pass reaches the same file and crashes again. Nothing remembers that the file
  killed the reader.

The immediate fixes (64 MB parser stack, waiting out a leftover Postgres, NULs stripped before
insert) are in review against main. They make this one file readable, but they don't make
Garage robust against the next file. This plan does that.

## Design

### 1. A parse helper process (macOS: `GarageParseXPCService`)

The Rust readers (`garage-readers`: PDF, Office, mail, text, OCR) move into a new XPC service that
holds **no file access at all**. Ingest keeps running where it runs today and keeps reading the
bytes, since it holds the person's grants. It hands the helper `(name, bytes, settings)` and
gets back the reader's answer.

- `garage-ingest-ffi` already supports this: a host that leaves out `"readers"` and sets
  `GarageIngestHost.read` is asked for each file's text. The Swift host implements `read` by
  reading the file (or taking a cloud download's bytes, `RemoteHost::read_bytes`) and sending it
  to the helper over NSXPC. The helper's entry point is a new FFI function,
  `garage_readers_read_bytes(request) -> reply`, with the same reply shape `read` returns.
- **A crash costs the file.** When the connection is interrupted mid-file, the host answers
  `{"failed": "the reader crashed on this file"}`. The pipeline records the file as FAILED with
  its source hash (`record_extract_failed`). A later run skips a failed file whose bytes haven't
  changed (`ingest_one` step 2), so the same file never crashes a run twice. launchd relaunches
  the helper on the next message.
- **A hang costs the file.** Each read has a deadline, by default 120 s, scaled by size. When it
  passes, the host invalidates the connection, which kills the helper, and records
  `{"failed": "the reader timed out"}`.
- **Memory.** The helper runs with a memory limit, so a decompression bomb is killed as a crash
  and doesn't page the node.
- The app's Postgres and gRPC services never share a process with a parser.

The Developer ID build gets the same helper. The CLI and the Windows and Linux agents get the
same split with a child process (`garage read-worker`) speaking the same JSON over stdin and
stdout. That comes later, after the Mac.

### 2. A validation layer for PDF (and the other containers)

The helper runs a cheap structural pass before handing a file to its parser. It doesn't render
anything, and it refuses what no real document needs:

| Check | Limit (setting) | Why |
| --- | --- | --- |
| Page tree depth, walked iteratively with a visited set | 4,096 levels (`pdf_max_tree_depth`) | well within the parser's 64 MB stack; real files reach 161 |
| Page tree nodes / page count vs `/Count` | 100,000 | trees that lie about their size |
| Indirect object count | 5,000,000 | parser memory |
| Decompressed stream size (per stream, total) | 256 MB / 2 GB | Flate bombs |
| Nesting of arrays and dictionaries | 512 | recursive object parsers |
| Office: zip entries, uncompressed size, ratio | 10,000 / 2 GB / 100:1 | zip bombs |

A file that fails a check is recorded as `failed` with the check's reason, for example "not read,
its page tree nests more than 4096 levels deep". The person sees why, and the reader never runs. The
limits come from GarageService's `extraction.*` settings, like the readers' other settings.

The 64 MB stack stays as a second line. Validation catches what we know about, and the helper
catches what we don't.

### 3. Making it visible

- A file that crashed or timed out a reader shows in the source's failures with that reason, and
  the Status page counts reader crashes. A crash is a bug report, so the reason names the
  reader and its version.
- `garage doctor` reports helper restarts since launch.

## Milestones

1. **Validation layer** in `garage-readers` (`validate.rs`; the PDF page tree is in review with
   the crash fixes, and the stream and Office limits come next), with fixtures that cross each
   limit. This is pure Rust and lands on its own.
2. **`garage_readers_read_bytes`** FFI and the `GarageParseXPCService` target. The app's in-process
   ingest moves to the `read` host hook. Tests: a fixture reader that aborts, one that sleeps
   past the deadline, and a source run that continues past both and records them failed.
3. **Developer ID and CLI**: the same helper in the Developer ID app, and `garage read-worker`
   for the CLI.
4. Windows and Linux agents.

## Open questions

- Batching: one XPC round trip per file costs about 0.1 ms. That's not worth batching for
  documents, but Messages threads may want it.
- Whether OCR (Vision) moves into the helper too. It's the same risk class, so the proposal is yes.
