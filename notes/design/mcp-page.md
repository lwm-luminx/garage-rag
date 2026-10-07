# Garage MCP Server page: design (branch claude/project-thread-7iel3g)

## What the page is for

People open MCP Server to answer, in order: is the server up and answering? Which of my
assistants (Claude Desktop, Claude Code, Cursor, …) reach Garage through it? And, now and then:
does it actually answer a question the way an assistant would see it?

## Critique of the page on `main`

Five stacked group boxes, built for debugging the server rather than using it.

- **Start, Stop and Restart are always shown**, two of them disabled at any time, above a separate
  orange warning about Postgres.
- **"Testing & Diagnostics" and "Prompt Playground" are two boxes for one job** (call the running
  server): one with a five-entry tool picker labelled "rag_stats (Corpus Statistics)", PASS (200 OK)
  / 3.1 ms / 14 TOOLS badges and a "Registered Server Tools" disclosure; the other with its own mode
  picker, stepper, slider and output box.
- **Assistants are a flat list of ten**, most of them "No config file", each with Config Found /
  Registered badges and a Register button, under four header buttons (Register All Found Configs,
  Add Custom Config File…, Refresh List, Check MCP Status). There was no way to disconnect one, and
  nothing said when an entry pointed at an old port.
- **Endpoint details get a whole box** (host, port, path, transport, database) plus the global Last
  Command Output box.

## The design as built

```
MCP Server

╭ Server ───────────────────────────────────────────────────────────────╮
│ (✓) Running                                   [Test] [Restart] [Stop] │
│     Answering on this Mac only · 14 tools                             │
│     http://127.0.0.1:8787/mcp  ⧉                           Details ›  │
│     (Details: Port [8787] [Random] · Path · Transport · Database ·    │
│      Last check · Tools with descriptions)                            │
╰───────────────────────────────────────────────────────────────────────╯

╭ Connected Assistants ─────────────────────────────────────────────────╮
│ 1 of 3 installed assistants connected · 1 needs updating              │
│                                         [Connect All] (⟳) (⋯)         │
│ ╭───────────────────────────────────────────────────────────────────╮ │
│ │ (💬) Claude Desktop                                            (⋯) │ │
│ │      Connected                                                     │ │
│ │      ~/Library/Application Support/Claude/claude_desktop_config.json│ │
│ │ (>_) Claude Code (user config)                        [Update] (⋯) │ │
│ │      Points at http://127.0.0.1:9000/mcp, not …:8787/mcp           │ │
│ │ (↗) Cursor                                            [Connect] (⋯) │ │
│ │      Installed, not connected                                      │ │
│ ╰───────────────────────────────────────────────────────────────────╯ │
│ › Not found on this Mac  7                                            │
│ ✓ registration result (dismissable, only after an action)             │
│ privacy note (excerpts may go to the assistant's cloud model)         │
╰───────────────────────────────────────────────────────────────────────╯

╭ Try It ───────────────────────────────────────────────────────────────╮
│ [Ask the Corpus | Prompt the Model | Call a Tool]                     │
│ Searches your corpus and answers with citations… Runs on qwen3 via …  │
│ ┌ prompt ───────────────────────────────────────────────────────────┐ │
│ Up to 512 tokens [±]  Temperature ──●── 0.20                 [▶ Run]  │
│ Answer (model via provider)                                   [Copy]  │
│ Sources: numbered citation rows with title, location, snippet, score  │
╰───────────────────────────────────────────────────────────────────────╯

› Server Output  312 lines        (collapsed; remembered per user)
```

### Server row

One headline in words (`MCPServerHeadline`), the same tinted circle as the Models and Sources rows.

| State | Title | Line |
|---|---|---|
| Running, answered | Running | Answering on this Mac only · 14 tools |
| Running, check failed | Running, but not answering (orange) | the error, in red |
| Running, checking | Running | Checking that it answers… |
| Starting | Starting… | Starting the database first… / Starting the server… |
| Stopped | Stopped | 2 connected assistants can't reach Garage until it runs. (+ Starting it also starts the database.) |
| Failed | Couldn't start (red) | the error |

The page checks the server by itself when it opens and whenever the server comes up (initialize +
tools/list, no tool call), so the tool count is there without a click. Actions: Start (Try Again
after a failure) while stopped; Test, Restart and Stop while running.

The stopped line matters because the app registers assistants with the HTTP URL, not stdio: while
the server is stopped, connected assistants can't reach Garage.

### Assistant rows

`MCPClientRowPresentation`: Connected (green), Points at an old address (orange, **Update**), Installed,
not connected (**Connect**), Not found on this Mac (folded away under a disclosure). The service now
reads the URL of the registered entry (`MCPClientConfig.registeredURL`), which is how an entry left
on an old port shows up. The ⋯ menu: Connect Again, Open Config File, Reveal in Finder, Copy Path,
Disconnect (new: `GarageMCPService.unregisterTarget` over the existing `McpUninstall` RPC).

### Try It

One panel with three modes in place of the tester and the playground: Ask the Corpus (`rag_ask`),
Prompt the Model (`rag_generate`), Call a Tool (any tool the server listed; a field for
`rag_search`/`rag_get_document`, nothing for argument-less tools, a JSON object for the rest).
⌘↩ runs it.

### Kept / changed for the UI tests

New identifiers: `mcp.start`, `mcp.stop`, `mcp.restart`, `mcp.test`, `mcp.copyEndpoint`,
`mcp.details.toggle`, `mcp.connectAll`, `mcp.rescan`, `mcp.client.<id>`, `mcp.try.run`, … The
navigation marker for the page is now "Connected Assistants"; `testMCPServerPageShowsStatusAndControls`
checks the new headings and the state-dependent buttons.

### Files

- `macapp/Sources/GarageApp/Views/MCPServerPresentation.swift` (+ `MCPServerPresentationTests.swift`)
- `macapp/Sources/GarageApp/Views/MCPServerView.swift`, `MCPServerView+TryIt.swift`
- `GarageMCPService.swift` (`registeredURL`, `unregisterTarget`), `GarageGRPCService+Operations.swift` (`mcpUninstall`)
