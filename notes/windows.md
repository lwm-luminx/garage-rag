# Garage on Windows: onboarding and status

Surveyed 2026-09-27 against `main` at 97acce7. Coordination happens in the project thread
"Windows coordination"; ask questions there.

## TL;DR

There is **no Windows app yet** (no `winapp/` tree). What exists is a CI proof that the native
pieces the Mac app bundles (Postgres 18 + pgvector + ICU + zlib, and CPython 3.13) build from the
same pinned sources with MSVC, and that `garage_rag` passes `test_postgres.py` on that interpreter
against that server. Everything above the database (the app shell, IPC, credential storage,
launchers, installer) is unstarted.

## Repo conventions you need

- Repo: https://github.com/rickmark/garage-rag. Read `CLAUDE.md` first; it is the real architecture doc.
- **Feature work targets `next`**; fixes to the shipping line target `v1.5-beta`. Windows work is feature work, so `next`.
- **PRs open early as drafts**, marked ready once the change is complete and local checks pass.
- **Commits are signed.** Rick signs with Secretive on his Macs; a cloud session that cannot sign leaves an unsigned commit or a patch in `/mnt/project-files` for Rick to sign.
- **Stacked PRs:** if another branch already touches the same area, base on it rather than `next`.
- Required merge checks (GitHub rulesets): python, swiftcheck, format, gazelle, buildifier, lint. The Windows workflow is **not** required (it is path-filtered).
- Privacy is load-bearing: all outbound network goes through `garage_python/src/garage_rag/net/egress.py`, communications never leave the machine, no cloud AI SDKs. Any Windows code must keep this (see `docs/privacy.md`, `tests/test_egress_block.py`).

## What exists

### CI: `.github/workflows/windows.yaml` (added in #50)

Runs on push to `main`, on PRs touching `ext/postgres|pgvector|libicu|libzlib|python`, `data/sql`,
`garage_python`, `tools/windows`, and by hand (workflow_dispatch). Green on recent PRs (#143, #149, #155, #160).

| Job | What it does |
|---|---|
| `postgres` | ICU via `allinone.sln` (cached), zlib via CMake, Postgres via **meson** (`-Dssl=none -Dicu=enabled -Dzlib=enabled`, everything else disabled), pgvector via `Makefile.win`. Smoke test: ICU `initdb`, apply `data/sql` twice, check vector / `binary_quantize` / trgm / ICU collation. Uploads `postgres-windows-x64`. |
| `python` | CPython from the pinned source with `PCbuild\build.bat` (no tkinter; PCbuild fetches its own OpenSSL/zlib/sqlite/xz/bzip2/libffi, not //ext's). Runs a few stdlib tests, lays out an install. Uploads `python-windows-x64`. |
| `garage` | Installs `garage_rag` with uv on the built interpreter, starts the built Postgres, runs `tests/test_postgres.py`. |

### `tools/windows/fetch_ext.py`

Stdlib-only script that reads url/sha256 (or git commit) and `strip_prefix` from
`ext/<name>/<name>.MODULE.bazel` and fetches into `DEST/<name>`. One set of pins for both OSes.
It deliberately does **not** apply patches: the Postgres `appstore.patch` / `sysv_shmem.patch` are
for the macOS App Sandbox.

### Bazel

Nothing Windows-specific. `//ext/postgres`, `//ext/python` etc. are Darwin-only (darwin configure
template, Python.framework, `install_name_tool`, `dsymutil`). `tools/windows` is excluded from
gazelle. `bazel/preset.bazelrc` has Aspect's generic `--enable_platform_specific_config`, nothing more.

## Build it yourself (mirrors CI)

On Windows 11 x64 with Visual Studio 2022 (or 2026) C++ workload, Python 3.13, CMake, and in an
"x64 Native Tools" PowerShell:

```powershell
python -m pip install meson ninja pkgconf
choco install winflexbison3 -y
python tools/windows/fetch_ext.py --dest C:\src postgres libicu libzlib pgvector python
# then follow the steps of the postgres / python / garage jobs in .github/workflows/windows.yaml
```

Simplest path for a first look: run the workflow by hand from the Actions tab and download the
`postgres-windows-x64` and `python-windows-x64` artifacts.

## Python package portability (what will break on Windows)

Only `test_postgres.py` runs on Windows today; the rest of the suite has never run there. Known spots:

| Area | File | Issue |
|---|---|---|
| gRPC socket | `service/server.py` (~1455-1510) | Binds `unix:` socket, `chmod 0o600`, `fcntl.flock` recovery lock, `AF_UNIX` stale probe, `SIGTERM` handler. `fcntl` does not exist on Windows. Needs a named pipe or AF_UNIX-on-Windows plus `msvcrt.locking`/`LockFileEx`, and ACLs instead of mode bits. |
| Inference over socket | `net/egress.py` (`uds=` requires a path starting with `/`), `inference/transport.py` | Rejects Windows paths; httpx `uds` transport is Unix-only. |
| MCP client registration | `mcp_server/install.py` | Claude Desktop config path is `~/Library/Application Support/...`; Windows is `%APPDATA%\Claude\claude_desktop_config.json`. |
| Default excludes | `config/__init__.py`, `attribute/pathrules.py`, `ingest/scanner.py` | macOS-shaped (`Library/`, `launchctl*`, `~/Library/Messages`). Need Windows equivalents (`AppData/`, `ntuser.dat*`, etc.). |
| Cloud placeholders | `extract/placeholder.py` | Detection is macOS xattrs only. Windows cloud files (OneDrive, Dropbox) show `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS` / `OFFLINE`; reading them triggers download. Walker must check attributes without opening. |
| OCR | `extract/tesseract.py` | `ctypes.util.find_library("tesseract")` rarely finds anything on Windows; needs a bundled `tesseract*.dll` path. `//ext/tesseract` + `//ext/leptonica` are not in the Windows build. |
| Native lookup | `native/__init__.py` | Darwin-only (dyld), returns None elsewhere, which is fine. |
| Images | `extract/imageio.py` | ImageIO path is macOS-only; Pillow fallback applies. |
| Walker | `ingest/walker.py` | Untested with drive letters, junctions/reparse points, long paths, case-insensitive exclude matching. |
| Git attribution | `attribute/git.py` | Needs `git.exe` on PATH; path separators in `git log --name-only` output vs `Path` on Windows. |

## Gaps (unstarted)

1. **App shell.** No Windows UI. Options: WinUI 3 / .NET, a tray app, or Python-only (CLI + MCP) first.
2. **IPC and isolation.** Mac uses XPC with code-signing peer checks and Unix sockets in the App Group folder. Windows needs an equivalent (named pipes with ACLs to the user SID, verifying the peer's Authenticode signature). Memory records the policy: IPC with code-signing checks, no new network listeners.
3. **Credential storage.** Mac keeps the Postgres password in the Keychain. Windows: Credential Manager / DPAPI.
4. **Data folder.** Mac: App Group container. Windows: `%LOCALAPPDATA%\Garage` (pgdata, models, logs, garage.json).
5. **Postgres lifecycle.** Start/stop (`pg_ctl` fast shutdown), port/pipe choice; Postgres on Windows leaves `unix_socket_directories` empty by default, so it listens on loopback TCP, which other local accounts can reach. Needs `scram-sha-256` at minimum; PG 13+ supports AF_UNIX sockets on Windows 10+, which would match the Mac's owner-only socket folder.
6. **Local inference.** `LlamaXPCService` hosts llama.cpp on Mac (Metal). Windows needs llama.cpp (CUDA/Vulkan/CPU) or relies on LM Studio / Ollama, which `inference/` already supports.
7. **Packaging and signing.** MSIX vs MSI, Authenticode certificate, updater (Sparkle is Mac-only; WinSparkle or Store updates), Microsoft Store listing.
8. **Bazel.** Windows builds are outside Bazel. Decide whether that stays (simplest) or `//ext` rules gain Windows variants.
9. **Tests.** The full Python suite on the Windows runner.
10. **arm64.** CI is x64 only. Windows on Arm (Snapdragon X) is plausible given the Mac is Apple-Silicon-only.

## Open questions (for Rick)

- Scope of a first Windows release: CLI + MCP server only (headless, reuses the Python package), or a full tray app?
- UI technology if an app: WinUI 3 (C#), or something shared with the Mac (none is today: the Mac UI is SwiftUI).
- Distribution: Microsoft Store (MSIX, sandboxed like the App Store build), direct download, or both? Who owns the code-signing certificate?
- Targets: x64 only, or x64 + arm64?
- Keep Windows native builds outside Bazel?
- Local inference: bundle llama.cpp, or require LM Studio / Ollama at first?

## Proposed first tasks

1. **Run the whole Python suite on Windows** in `windows.yaml` (new job or step in `garage`), recording failures; mark known-failing ones as expected so the job goes green, then fix. Cheap, and it turns the table above into facts.
2. **Portable gRPC/inference endpoints**: abstract the socket bind/lock/probe in `service/server.py` and the `uds` check in `net/egress.py` so Windows gets a named pipe or TCP-loopback-with-token path, keeping the egress tests passing.
3. **Windows paths**: `%APPDATA%` Claude Desktop config in `mcp_server/install.py`, Windows default excludes, and a Windows cloud-placeholder check via file attributes.
4. **Headless install proof**: a zip or MSI with the built Postgres + Python + `garage_rag`, a `garage` launcher that starts Postgres from `%LOCALAPPDATA%\Garage` with a DPAPI-stored password, and `garage mcp-install` for Claude Desktop. That gives a usable Windows Garage over MCP before any UI decision.
