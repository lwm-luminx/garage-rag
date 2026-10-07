# Signed launch check of #136 (XPC peer requirement) on the M4

## Result on v1.5-beta as merged (7243401f): every XPC service crashes at launch
I built a Developer ID app (`aspect build //:macapp --bazel-flag=--config=developer_id`).
`codesign --verify --deep --strict` passes, and the app, all six XPC services and both helper
apps are signed "Developer ID Application: Richard Penwell (DWVXMLB45Y)".

On launch, with a scratch `--data-directory`:
- No XPC service process stays up. GarageXPCService, Ingest, Embed, MCPServer, Llama and
  ModelDownload each crash as soon as launchd starts them, and they keep crashing on every retry.
- Status: Index Manager "Failed to launch garage server", MCP server "failed to launch
  garage-mcp", built-in engine "Llama XPC Service unavailable", and every helper row "Can't be
  reached". Each carries "Couldn't communicate with a helper application".
- Every crash report has the same stack:

```
EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x00000000000000f0
Foundation  -[NSXPCListener setConnectionCodeSigningRequirement:]
PythonXPCService  static GarageXPCPeerRequirement.apply(to:serviceName:)
PythonXPCService  GarageXPCServiceBase.run()
<Service>   main
```

The cause is that `NSXPCListener.service()` has no underlying connection until it is resumed,
and setting a code-signing requirement on it dereferences that missing connection.

## Fix, verified on the same build
The requirement moves from the listener to each accepted connection:
`newConnection.setCodeSigningRequirement(_:)` in `listener(_:shouldAcceptNewConnection:)`,
called before the connection is resumed, for both the service and the anonymous listeners. The
requirement string is unchanged: `anchor apple generic and certificate leaf[subject.OU] = "DWVXMLB45Y"`.

Results with the fix, from a Developer ID build on a scratch data folder:
- All six XPC services stay up, and no new crash reports appeared.
- **Status → Test All: every row green.** Index Manager test passed. Helper results:

  | Helper | Passed | Skipped |
  |---|---|---|
  | Ingest | 10 | 2 |
  | Embeddings | 9 | 2 |
  | Built-in Engine | 3 | 1 |
  | Model Downloads | 3 | 0 |
  | MCP Server | 12 | 1 |
  | Garage Backend | 12 | 0 |

  MCP Server's "Llama Loader" test covers a sibling service reaching LlamaXPCService's anonymous
  listener through the brokered endpoint, so the requirement was on and satisfied there.
- **Scan, ingest, search:** I registered `mxbai-embed-xsmall` (llama_xpc) and a folder of the
  test fixture files, then ran Status → Update Everything. It ingested 5 documents (14 chunks),
  embedded them and gleaned 8 facts. The Search page's query "lighthouse keeper" returns 8
  results, with Marrowgate Lighthouse first, matched by both engines.
- **`garage` CLI** (the bundled `Contents/MacOS/garage` helper, pointed at the scratch cluster
  with `GARAGE_DATABASE_URL` and `GARAGE_NO_APP_LAUNCH=1`): `version`, `stats`,
  `register-model`, `add-source`, `list-sources` and `search "orchard survey"` all work. The
  search embedded its query through the app's Llama service on 127.0.0.1:8790 and ranked The
  Ashvale Orchard Survey first.
- `aspect test //...`: 52 of 52 pass.

Not covered:
- The App Store platform build. It can't be launched outside TestFlight or the store, so it
  wasn't run here.
- A deliberate wrong-team peer. A bundled service can't be looked up from outside the app, so
  I had no process of another team to connect with.
