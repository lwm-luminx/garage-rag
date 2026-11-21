# Garage plugin for Claude and Codex

This plugin connects Claude Code (and Claude Cowork sessions on your computer) or Codex to the Garage on this
computer, and teaches the assistant how to use it: a `search-garage` skill for searching with the right filters,
reading whole documents and naming its sources, plus two commands in Claude Code, `/garage:search` and
`/garage:whats-in`. Garage runs the search on your computer; the assistant gets only the excerpts it retrieves.

To reach your Garage from claude.ai, ChatGPT or a phone, use Garage Door instead: its account page builds the same
plugin with your own Door URL inside.

## Install

You need Garage installed: the Mac app (`/Applications/Garage.app` or `~/Applications/Garage.app`), or the
`garage-mcp` command on your `PATH` on Linux and Windows. Set `GARAGE_MCP` to its path to use another one.

```bash
# Claude Code
claude plugin marketplace add lwm-luminx/garage-rag
claude plugin install garage@garage

# Codex
codex plugin marketplace add lwm-luminx/garage-rag
codex plugin add garage@garage
```

To try a checkout without installing: `claude --plugin-dir plugins/garage`.

## Layout

One folder serves both:

| File | Read by |
| --- | --- |
| `.claude-plugin/plugin.json`, `.mcp.json`, `commands/` | Claude Code and Cowork |
| `plugin.json`, `mcp.json` | Codex (the Agent Plugins 1.0 layout, with OpenAI's `interface` under `extensions`) |
| `skills/search-garage/SKILL.md`, `assets/` | both |
| `scripts/garage-mcp` | both: finds the Mac app's launcher, then `garage-mcp` on `PATH` |

The marketplaces that list it are `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json` at the
root of the repository. Check a change with `claude plugin validate plugins/garage`.

The launcher is a shell script, so on Windows add `garage-mcp.exe` as an MCP server by hand
(`garage mcp-install`) and copy the skill.
