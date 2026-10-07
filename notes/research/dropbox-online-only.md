# Reading Dropbox online-only files from the sandboxed App Store build

Research thread, 2026-09-26. Branch v1.5-alpha at e08c162. Nothing here is implemented.

## 1. What Dropbox does on macOS now

- Since macOS 12.5 Dropbox runs as a File Provider extension. The folder lives at
  `~/Library/CloudStorage/Dropbox` (Finder shows it under Locations), and `~/Dropbox` is a
  symlink to it on machines that migrated. Dropbox's own help page says third-party apps that
  linked the old path must be re-linked. Users can opt out and go back to the old kernel-based
  client, so both layouts exist in the wild.
- Under File Provider an online-only file is a **dataless** file: the kernel flag `SF_DATALESS`
  is set, the directory entry reports the **real logical size**, and there is no
  `com.dropbox.placeholder` xattr (that was the old client). `placeholder.py` already catches
  this via signal 2 (`st_flags & SF_DATALESS`), and `pipeline.py:102` handles the nonzero-size
  case, so detection is right. The module docstring's claim that "Dropbox does not set the
  dataless flag" describes the pre-File-Provider client and should be reworded.
- Any `open()`+`read()` of a dataless file makes the kernel ask fileproviderd to fetch it, and
  the read blocks until the bytes arrive. That is what `materialize._force_read` relies on, and
  it still holds under File Provider. Reads that never finish (provider stalled, offline) are why
  the daemon-thread timeout exists.

## 2. The APIs, and which ones matter

| API | Verdict for Garage |
|---|---|
| **Plain read (current approach)** | Works for every provider, needs no extra entitlement, and is the only path the Python side can use unchanged. Keep it. |
| **`setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, …)`** | The missing piece. Process or thread scope; `OFF` makes access to a dataless file fail (EDEADLK/EAGAIN) instead of downloading; children inherit the process policy. `ls` and Spotlight use this. Garage should set OFF at process scope for the walker and extractors, and ON at thread scope inside `_force_read`'s thread only. Then an accidental read anywhere else can never trigger a download, which is the hazard the budget exists for. Callable from Python via ctypes (libc). |
| `FileManager.startDownloadingUbiquitousItem(at:)` / `URLResourceKey.ubiquitousItemDownloadingStatusKey` | Documented for iCloud. Apple routes them through fileproviderd, and they are reported to work for replicated third-party providers on macOS 12.3+, but Apple's page does not promise it for Dropbox. Nice-to-have for an async download with status, not a dependency; verify on the M3 before relying on it. If it works, it lets the app start a download without holding a thread in a blocking read. |
| `NSFileCoordinator` | Coordinated reads also materialize, and let the provider see a reader. It brings nothing over a plain read for a batch indexer, and adds a hop per file. Skip. |
| `NSFileProviderManager` | A provider-side API. Third-party apps cannot address Dropbox's domain (`getUserVisibleURL` and friends need the provider's app group). Not usable. |
| `URLResourceKey.isUbiquitousItemKey`, `.icloud` sidecars | iCloud only. Already covered by `placeholder.py` signals 1 and 3. |
| **Dropbox HTTP API** (`files/download`) | Bypasses the sandbox and File Provider entirely, but costs an OAuth PKCE flow, a refresh token in the Keychain, a Dropbox developer app (production access is capped until Dropbox reviews it), path mapping between the local folder and the account root (personal vs team spaces), and a new allowed origin in `egress.check_destination`. It also pulls bytes the sync client will pull again. Not for 1.5. |

## 3. Sandbox: what the app process needs

With the M3's fix moving Scan, ingest and the config writes into the app process, the Dropbox
question becomes simple, because only one process needs access:

- **Grant on the real path.** The user picks `~/Dropbox` in the open panel, but the folder is
  `~/Library/CloudStorage/Dropbox`. Make the security-scoped bookmark from
  `url.resolvingSymlinksInPath()` (or bookmark both), and hand Python the resolved path; the
  walker then never crosses a symlink into a tree the extension does not cover. The forum
  report of "Sandbox extension creation failed … /Users/x/Library/CloudStorage/…" was exactly a
  CloudStorage URL used without `startAccessingSecurityScopedResource()`, so bracket access as
  the app already does.
- **No extra entitlement.** `com.apple.security.files.user-selected.read-write` plus
  `bookmarks.app-scope`, which the app already has, cover reading dataless files and triggering
  their download; fileproviderd does the fetch in Dropbox's process, not ours.
- **Materialization in-process is fine for the sandbox** but means the app process hosts blocking
  reads of up to `timeout_seconds` each, with `MAX_STALLED_READS` daemon threads that may never
  return. That is acceptable for the alpha; the iopolicy switch above makes it safe.

## 4. How this fits the three fixes

| Fix | Folder grant reaches Python? | Dropbox online-only | Store risk |
|---|---|---|---|
| **In-app** (chosen) | Yes, the app holds the grant itself. | Plain read works; add the iopolicy guard. Blocking reads live in the app process. | None new. |
| **Spawn with `com.apple.security.inherit`** | Yes, children share the app's sandbox. Note `inherit` is for `Process`/posix_spawn children, not launchd XPC services, and the child may carry only `app-sandbox` + `inherit` (the vendored Postgres already does this), so it cannot read the App Group keychain itself; the app must pass the DB URL. | Same as in-app, plus children inherit the parent's iopolicy for free. Best long-term home for blocking downloads. | None new. |
| **Home-folder temporary exception** | Yes. | Same. | App Review usually rejects `temporary-exception.files.home-relative-path`; not worth it. |

## 5. Recommendation

1. Go with in-app for the alpha, as decided. Bookmark and pass the symlink-resolved path.
2. Add the iopolicy guard to `materialize.py`: OFF at process scope when the pipeline starts,
   ON at thread scope inside `_read_with_timeout`'s thread. Treat EDEADLK/EAGAIN on any other
   read as "still a placeholder" (`PlaceholderFile`). This is a small, testable Python change and
   protects every caller, including the CLI and MCP server.
3. Reword the `placeholder.py` docstring for File Provider Dropbox; keep the three signals.
4. Later (Beta), when workers move out of the app again, prefer `inherit` children over XPC for
   the ingest worker; the grant and the iopolicy both come along.
5. Try `startDownloadingUbiquitousItem` on the M3 against a CloudStorage Dropbox file once. If it
   works, the app can prefetch a budgeted batch asynchronously instead of blocking threads.

Sources: setiopolicy_np(3) man page (https://keith.github.io/xcode-man-pages/setiopolicy_np.3.html);
Dropbox on File Provider (https://help.dropbox.com/installs/macos-support-for-expected-changes);
Apple: startDownloadingUbiquitousItem (https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:));
Apple forums, CloudStorage sandbox extension (https://developer.apple.com/forums/thread/681690);
iopolicy discussion (https://github.com/bherila/restic-station/issues/156).

## 6. Hashes without downloading (Rick's question, 2026-09-27)

- **Locally: no.** macOS exposes no content hash for a dataless file. What stat gives is the
  real logical size and the modification time Dropbox sets from the server's `client_modified`.
  Garage already skips unchanged files on stat (`CheckDocumentStat`), and under File Provider the
  size is real, so size+mtime works as the "same content" test with no materialization. It is a
  heuristic, not a hash. `URLResourceKey.generationIdentifierKey` is meant to change with content
  and may track remote updates on placeholders; unverified, try on the M3.
- **Dropbox API: yes, for free.** `files/get_metadata` and `files/list_folder` return a
  `content_hash` for every file, plus `rev` and `server_modified`, with no download.
  `list_folder/continue` with a cursor returns only what changed. The hash is Dropbox's own
  scheme: SHA-256 of each 4 MiB block, concatenated, SHA-256 again
  (https://www.dropbox.com/developers/reference/content-hash). Garage could compute it for local
  files and compare, or store it beside `source_sha256`. This needs the OAuth app, token storage
  and egress origin from section 2; metadata-only calls send paths and names, never content.
- **File Provider `contentVersion`** exists on every item but is visible only to the provider
  (Dropbox), not to other apps.

## 7. Hashing and indexing without keeping the bytes on disk (Rick, 2026-09-27)

- **Materialize, hash and extract, then evict.** `FileManager.evictUbiquitousItem(at:)` asks
  fileproviderd to drop the local copy, which is what Finder's "Remove Download" does. Like the
  download API it is documented for iCloud and routed through fileproviderd for replicated
  providers; verify once on the M3 with a CloudStorage Dropbox file. Peak disk use is then one
  file (or one budget slice) at a time, and a file Garage found dataless goes back to dataless, so
  the user's own offline choices are untouched. Evict only files that were placeholders before
  Garage read them.
- **Stream from the Dropbox API instead.** `files/download` can be hashed and extracted in memory
  with nothing written to disk, and for the hash alone `content_hash` needs no download at all.
  Same OAuth and egress cost as before, and it spends bandwidth the sync client would spend again.
- **No partial reads.** A read through the dataless fault materializes the whole file; there is no
  consumer-side way to stream a placeholder without it landing on disk.
