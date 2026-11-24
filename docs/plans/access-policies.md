---
layout: default
title: Access policies in Rego
description: Garage decides what each caller may read with Open Policy Agent's language. A Rego policy, evaluated in-process by regorus on every read, turns stored rules and defaults into one SQL filter; the Mac app's Access page edits policies as text and tries them out against any caller before they are saved.
date: 2026-11-24
status: Active (moved from garage-enterprise on 2026-11-24; the engine, the access calls, garage access and the Access page's text editor are in review)
status_kind: active
---

# Access policies in Rego

Rick (2026-11-24), asked whether Rego, OPA and its editors were in the open-source app: "Text editor for
oss. Visual for enterprise." So the policy engine, the calls that edit it and a text editor for Rego
move here from garage-enterprise, where they were built (its `docs/plans/opa-access-policies.md`, P1
and P2), and garage-enterprise keeps only a visual editor on top of them.

This supersedes [Access hooks](access-hooks.md)'s "Garage itself ships no policy": a plain build now
holds every read to this policy. With nothing stored it restricts nothing, and a read skips the engine
altogether, so a library with no rules reads as it did before.

## What decides

Every read names its caller (the [access hooks](access-hooks.md)): the app, `garage` on a terminal, an
MCP client by the registration its token proves, or a gRPC caller the server cannot vouch for. The
caller goes by one or more **target names**, outermost first:

| Caller | Targets |
|---|---|
| The app | `app` |
| `garage` | `cli` |
| An MCP client with no (or an unknown) registration | `mcp:unregistered` |
| An MCP client with a registration | `mcp:<registration id>` |
| A Garage Door connector, and a grant Door names on it | `door:<id>`, then `door:<id>/<grant>` |
| An unverified gRPC caller | `unverified` |

Once per read, regorus evaluates `data.garage.access.decision` with the caller as `input` and the stored
rules and defaults as `data.garage`. The decision is a list of **boundaries**, and a document is visible
when it passes every one:

```json
{"boundaries": [
  {"target": "mcp:r1", "default": "allow",
   "deny":  [{"rule": "no-keys"}, {"corpus_class": "communication"}],
   "allow": []}
]}
```

A boundary hides what any `deny` condition matches and, under a `deny` default, everything no `allow`
condition matches. A condition is a stored rule by name or an inline metadata matcher (`source`,
`corpus_class`, `trust_tier`, `author`, `path`). Content matchers (`regex`, `term`) read the corpus, so
they are stored rules, evaluated ahead of the read a batch at a time into `access_evaluations`; a
document a DENY has not looked at yet stays hidden from that DENY's targets. The decision becomes one
`SqlFilter` (`garage-access-rego`'s `filter`), so a search stays one filtered query and fills its limit.

**The built-in policy** (`rust/garage-access-rego/policy/rules.rego`, package `garage.access.rules`)
applies the stored rules and defaults: one boundary per target, the target's default (an exact name,
then the longest prefix pattern, then `*`; none is allow), and every enabled rule naming the target.
With no stored module declaring `package garage.access`, its decision is the decision. A module of your
own can build on it (`data.garage.access.rules.decision`) or ignore it:

```rego
package garage.access

decision := {"boundaries": array.concat(data.garage.access.rules.decision.boundaries, extra)}

extra := [{"default": "allow", "deny": [{"corpus_class": "communication"}]}] if {
	input.caller.kind == "mcp"
} else := []
```

**It fails closed.** A module that does not compile is refused when it is saved. At read time, an
evaluation that errs, runs past 250 ms, leaves the decision undefined or answers outside the
vocabulary fails the read ("the access policy could not decide; nothing was read"), and the reason goes
only to the log.

regorus (Microsoft, MIT, pure Rust) runs in GarageService's process with only the built-ins a policy
over a caller needs: no `http.send`, no `opa.runtime()`. There is no OPA server and no sidecar, so no
new listener. 0.12 is the newest that builds on the workspace's Rust 1.92.

## Where it lives

- **`rust/garage-access-rego`**: `RulesPolicy` (garage-access's `AccessPolicy`), the rules and their
  matchers (`rules`), the Rego engine (`policy`), the decision to SQL (`filter`) and the tables
  (`store`). GarageService installs it unless the build's access extension
  (`//rust/garage-access:extension`) registers a policy of its own.
- **`data/sql/027_access_policies.sql`**: `access_rules`, `access_defaults`, `access_evaluations` and
  `access_policies`. The policy also applies it once per process before its first read, so a database
  migrated before it existed still answers.
- **GarageService's access calls** (`access_ops.rs`): `ListAccessPolicies` (with the built-in module and
  the callers to test as), `PutAccessPolicy` (`check_only` compiles and saves nothing),
  `RemoveAccessPolicy`, `ListAccessRules`/`PutAccessRule`/`RemoveAccessRule`,
  `ListAccessDefaults`/`SetAccessDefault`, and `TestAccess`: what a caller's reads would be held to,
  optionally with an unsaved module in place of the stored one of its name. The writes are
  config-changing (`auth.rs`): only the per-launch token or the Unix socket may make them.
- **`garage access`**: `policies list|show|put|check|remove|builtin`, `rules list|put|remove`,
  `defaults list|set` and `test --as CALLER [--draft NAME=FILE]`, over the same calls.
- **The Mac app's Access page** (Configuration, after MCP Server): the stored policies beside the
  built-in one (read-only), each edited as text with Check, Save, Revert and Delete, and a Test panel
  that runs `TestAccess` as any caller with the editor's text as it stands.

## The editor seam

`GarageAppExtensionKit` gains `GarageAccessBackend` (the access calls as plain values) and
`GarageAccessEditor`: an editor a build's extension adds as a tab beside the Rego editor, through
`GarageAppExtensionSet.accessEditors`. garage-enterprise's visual rule editor is one; it needs nothing
of the app but that protocol, and edits the same rows the text editor and `garage access` do.

## Not yet

- The Windows app has no Access page (its sidebar has no Chat page either).
- Importing `.rego` files from a folder, and a bundle of policies per library.
- Hooks on the reads still marked `NotYet` in `READ_PATHS` (facts, the graph, `ListSources`, `GetStats`).
- The MCP server's tool policy in Rego (enterprise's P4) and the cluster (P5).
