# Garage 1.5 security and privacy review (RC 0a35384, against v1.0)

**Verdict: no Blockers. Ship after the two Should-fix log leaks (V1-S1, V1-S2) are fixed. The other Should-fix items can land in 1.5 or 1.5.1.**

Paths are relative to the review tree. The Python suite was run from the review tree with
`PYTHONPATH=src` (the venv's editable install otherwise imports the main checkout):
1201 passed, 52 skipped. The Postgres tests skipped because no server was set.
test_egress_block + test_embed_egress: 98 passed. The first run wrote gitignored `__pycache__`
directories into the review tree. Removing them was refused, so they are still there. They have no effect on git.

## Findings

**V1-S1 Should fix: the ingest XPC service writes the Postgres password to the unified log.**
`macapp/Sources/GarageIngestXPCService/main.swift:294` logs the full `GARAGE_DATABASE_URL`
(`postgresql+psycopg://user:<keychain password>@localhost:14824/...`) at `.info` with
`privacy: .public`. The value comes from `PostgresService.connectionURL()` (`IngestService.swift:332-334`).
The same line was in v1.0, so this is not new. Info messages stay in memory by default (inferred), but
`.public` means `log stream`, `log collect` and any sysdiagnose record the password in plain text. Fix: log
`redact_url`-style (drop the password) or use `privacy: .private`.

**V1-S2 Should fix: the ingest XPC service logs the LM Studio bearer token and the DB password in its options JSON.**
`GarageIngestXPCService/main.swift:396` logs `optionsJson` as `.public`. That JSON is `IngestOptions`
(`IngestClient/IngestModels.swift:111-112, 140-141`) and carries `database_url` and `lmstudio_api_token`,
which `IngestService.swift:332-338, 402-410` always fills. This line was also in v1.0. Fix: log only
slug, include_code, limit and force.

**V1-S3 Should fix: the bug-report redactor misses common secret shapes.**
`macapp/Sources/GarageApp/Services/BugReport.swift:106`. The pattern was tested with Python `re`. ICU
treats `\b` and `_` the same way, but that part is inferred.
- `Authorization: Bearer sk-abc` becomes `Authorization=<redacted> sk-abc`, so the token survives.
- `PGPASSWORD=x`, `GARAGE_LMSTUDIO_API_KEY=x` and `lmstudio_token=x` are not matched. `\b` fails after `_` or a letter.
- `{"password": "x"}` is not matched, because of the quote before the `:`.
- The URL rule at `:104` misses a JSON-encoded URL (`postgresql+psycopg:\/\/...`, since JSONEncoder escapes `/`).

Log attachment is opt-in (`includeLogs=false`, `:158`), and the app's Logs view reads only this process's
OSLogStore (`OSLogStreamService.swift:32,86`). So V1-S1 and V1-S2 probably do not reach a report (inferred).
Fix: drop the leading `\b`, allow an optional quote around the key, and add a rule for `Bearer\s+\S+`.

**V1-S4 Should fix: the unauthenticated loopback gRPC service now changes configuration too.**
`garage_python/src/garage_rag/service/server.py:1395-1417` serves `add_insecure_port`. It has no
credentials or interceptor, and the socket is reachable by every local process and every local user.
- v1.0 already exposed Search and GetDocument this way, communications included.
- 1.5 adds `SetSetting` (`proto/garage.proto:58`, `server.py:1039-1044`; it is absent from v1.0's proto). It
  takes a caller-chosen `path` and can set `embedding.ollama_host` to an off-box host. Backfill would then
  post non-communication chunks there, which the egress allowlist approves by design.
- `McpInstall` (`:1051`) also writes to a caller-chosen `path`.
- The Developer ID XPC services are unsandboxed (`macapp/externals/GarageAppGroup.entitlements` has no app-sandbox
  key), so the path is unconfined.
- MCP HTTP on 8787 is likewise unauthenticated, but read-only. It has DNS-rebinding and Origin guards
  (`mcp_server/server.py:692-730`).

Fix: a per-launch bearer token in gRPC metadata passed through the XPC configuration, or a 0600 Unix socket.

**V1-S5 Should fix: a model file name from the remote catalog is not confined to the models folder.**
The app fetches `https://garagerag.app/.data/models.json` at launch (`AppState.swift:289`,
`ModelCatalog.swift:15-49`), and the fetched file wins over the bundled one. `download_file` becomes both
the URL tail (`GarageConfigLoader.swift:153-154`, always huggingface.co) and the local file name
(`ModelDownloaderEngine.swift:69-94`). The engine only strips leading `/`, so `../` goes through and
`destinationFile` can land outside `models/`. An attacker needs control of the site or its repository,
and the user has to press Download (inferred). `sha256` is optional per entry. Fix: reject `..` components
and require the standardized path to stay under `targetDir`.

**V1-S6 Should fix: the repository's `PRIVACY.md` is a stale second policy.**
`PRIVACY.md` (effective Sep 12) has no network-requests section: no catalog fetch, Hugging Face or Sparkle.
The published policy `docs/support/privacy-policy.md:63-71` (Sep 24) has them. Readers of the repo see a
policy that omits the catalog fetch. Fix: replace it with a pointer to the site page, or sync it.

**V1-N1 Note: CALLERS is valid but incomplete.** Every entry in `tests/test_egress_block.py:145-158`
exists and passes. `embed/xpc.py:38` and `ingest/gateway.py:1020` build `GarageClient(`, the same pattern
that listed `xpc/host.py`, but neither is listed. They are covered in practice by
`service/client.py:136` (`loopback_only=True`). The test checks only the listed modules and does not check
completeness.

**V1-N2 Note: `--data-directory` works in release builds.** `PythonXPCService/GarageAppGroup.swift:72-82`
and `GaragePostgresEndpoint.swift:289` have no `#if DEBUG`. It refuses the real data folders, and anything
that can pass launch arguments already runs as the user, so it grants nothing new. Its comment says the XPC
services never see the flag, so they keep the real `logs`/`models` paths while the app uses the test
folder. That is a test-isolation gap, not a security one (inferred). `GARAGE_UITEST_STORE_APP` exists only in
`macapp/Tests/GarageAppUITests/StoreMailMessagesUITests.swift`. `--appearance` does not exist.
`--after-database-reset <pid>` only waits and migrates (`AppState.swift:244-260, 604-620`) and deletes
nothing. The env knobs `GARAGE_LLAMA_HTTP_PORT` (loopback kept), `GARAGE_MODEL_MANIFEST`,
`GARAGE_NO_APP_LAUNCH` and `GARAGE_DEBUG` are same-user only.

**V1-N3 Note: the initdb password file is chmod'ed after it is written.** `PostgresService.swift:385-389`
does an `.atomic` write and then sets 0600. For a moment the file has umask permissions, inside the user's
0700 `~/Library` (inferred to be low risk). Better to create it with 0600.

**V1-N4 Note: `git` runs in indexed repositories without hardening.** `attribute/git.py:62` (`git log`) and
`ingest/scanner.py:271` (`git ls-files`) run git in user-chosen roots. A hostile `.git/config` in a
same-owner repo (`core.fsmonitor`) could run code (inferred). Fix: add `-c core.fsmonitor=false`.

**V1-N5 Note: Llama test prompts go into the App log.** `LlamaService.swift:282,309` logs the prompt and
tokenize text in full. Only the user's own test input lands there, and it enters bug reports only when
logs are attached.

## Checks that passed

- **One egress choke point.** Only `net/egress.py:41,46` imports `httpx` or `urllib.request`. `grpc`,
  `uvicorn` and `psycopg` appear only in the files `INBOUND_OR_LOCAL` lists. The only subprocesses are
  local `git` calls. `test_egress_block.py` passes against the RC.
- **Communications stay on loopback.**
  - Backfill: `embed/ollama.py:96-171` withholds communication chunks for a provider that is not local
    (`embed/factory.py:19-35`). The gRPC batch path applies the same filter (`service/server.py:1322-1340`).
  - Facts: `enrich/facts.py:350-366` passes `corpus_class` to the guard and to `InferenceClient`.
  - rag_ask: `mcp_server/server.py:613-615` checks each hit's class.
  - rag_generate (`:629-645`) retrieves nothing and sends only the client's own prompt.
  - `check_destination` (`net/egress.py:116-142`) checks the content rule first.
- **The catalog fetch is disclosed.** `docs/support/privacy-policy.md:67` covers it, and so do
  `docs/privacy.md:114-117` and the overview (`:19`).
- **Loopback binds.**
  - gRPC: `create_grpc_server` and `serve_grpc` default to `127.0.0.1` (`server.py:1396,1431`), as does
    `garage serve` (`cli.py:1603`). The app passes `GarageGRPCService.host = "127.0.0.1"` (`:50`, never
    reassigned), and the XPC side defaults the same (`GarageXPCServiceBase.swift:223`).
  - MCP: the app sends the constant `let host = "127.0.0.1"` (`GarageMCPService.swift:136`). A
    non-loopback bind from the CLI needs `--allow-remote` (`cli.py:1343`).
  - Llama: `LlamaHTTPServer` sets `requiredLocalEndpoint` to 127.0.0.1 (`LlamaHTTPServer.swift:36,60`).
    `LlamaXPCService/main.swift:76` does not pass a host.
- **Postgres 14824.** It runs with `listen_addresses=localhost` and no Unix socket (`PostgresService.swift:460-462`),
  and initdb uses `--auth=scram-sha-256` with the Keychain password (`:382-397`).
- **Configuration files hold no secrets.**
  - garage.json: the LM Studio token is read from a file or the environment, never from the config
    (`config/__init__.py:317-321,462-478`).
  - MCP registrations: `ops/mcp.py:107-110` leaves out the database URL when the app launcher is present,
    and the app sets `GARAGE_MCP_EXECUTABLE` for the gRPC service (`GarageGRPCService.swift:97`).
  - Python logs: they pass the database URL through `redact_url` (`mcp_server/server.py:676`, `cli.py:323`).
- **Bug-report diagnostics** hold versions, counts and ports only (`BugReportDiagnostics.swift:32-90`).
  Every field and all user text go through the redactor. The reporter never posts anything itself.
