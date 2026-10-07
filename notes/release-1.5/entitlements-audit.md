# Entitlements and portal capabilities audit (v1.5)

Checked 2026-09-24 against `main` at a3e7081. Sources: every `*.entitlements` under `macapp/`, the
`entitlements`/`provisioning_profile` selects in each `BUILD.bazel`, and the three
`macapp/*.provisionprofile` files decoded with `openssl smime`. Nothing was built or run on a Mac.

## Portal: what App ID `me.rickmark.garage-rag` needs

| Capability | Needed? | Why |
|---|---|---|
| App Groups | Yes, keep | Both profiles already carry `group.me.rickmark.garage-rag` and `DWVXMLB45Y.*`. The code uses the team-prefixed `DWVXMLB45Y.group.me.rickmark.garage-rag`, which macOS allows without the profile, so this is belt and braces rather than load-bearing. |
| Sustained Execution | Not used | Both profiles carry `com.apple.developer.sustained-execution`, but no entitlements file claims it and no Swift code references it. Harmless to leave; turn it off or adopt it deliberately. |
| Keychain Sharing | Not a portal switch on macOS | The profiles already grant `keychain-access-groups: DWVXMLB45Y.*`. The Keychain problem is in code (below), not the portal. |
| Enhanced Security (hardened-process) | No, not for 1.5 | Opt-in memory hardening (hardened heap, checked allocations). CPython with ctypes, llama.cpp and Postgres are the likeliest things to break under it; worth a trial after release, not before. |
| Background Inference, iCloud, Push, Associated Domains, Sign in with Apple, everything else | No | Nothing in the app uses them. |

No other App IDs are needed. The XPC services and launchers use only unrestricted entitlements
(sandbox, network, team-prefixed app group, library validation), so they sign without profiles.
That changes only if you pick the Keychain option below that gives each XPC service its own App ID.

## Per component (App Store build; Developer ID gets `GarageAppGroup.entitlements`, group only)

| Component | Has now | Needs | Change |
|---|---|---|---|
| GarageApp | sandbox, network client+server, user-selected rw+ro, bookmarks.app-scope, disable-library-validation, app group, application-identifier, team-identifier | All of it. network.server is for the Postgres child it starts (inherits the sandbox). | Drop `user-selected.read-only` (redundant beside read-write). |
| GarageXPCService (Python gRPC) | sandbox, net client+server, user-selected, bookmarks, DLV, group | sandbox, net client+server (gRPC listener), DLV (Python extension modules), group | user-selected/bookmarks look unused (no bookmark code in it); remove only after a store run confirms scans still work. |
| GarageIngestXPCService | sandbox, net client, user-selected, bookmarks, DLV, group | All of it; it resolves the source bookmarks (`setSourceBookmark`). | None. Unverified: that an app-scoped bookmark made by GarageApp resolves inside the XPC service. |
| GarageEmbedXPCService | sandbox, net client, user-selected, bookmarks, DLV, group | sandbox, net client, DLV, group | user-selected/bookmarks look unused. |
| GarageMCPServerService | sandbox, net client+server, user-selected, bookmarks, DLV, group | sandbox, net client+server (HTTP on 8787), DLV, group | user-selected/bookmarks look unused. |
| LlamaXPCService | sandbox, net client+server, user-selected, bookmarks, DLV, group | sandbox, net server (8790), group; DLV only if it loads the Python framework | user-selected/bookmarks look unused. No JIT entitlement needed (Metal, no JIT). |
| ModelDownloadXPCService | sandbox, net client, user-selected, bookmarks, DLV, group | sandbox, net client, group | user-selected/bookmarks look unused. |
| garage / garage-mcp launchers | `GarageLauncher.entitlements` (PR #62, now on main): sandbox, net client, group, DLV | Same | None for the portal. Keychain read is the open problem. |
| Postgres binaries | `GarageServer.entitlements`: sandbox + inherit | Same | None. |
| `macapp/externals/Garage.entitlements` | nothing references it | – | Dead file; delete. |

Developer ID: hardened runtime with only the app group. Library validation passes because
everything is signed by the same team; no JIT or unsigned-executable-memory entitlement should be
needed (libffi on arm64 macOS uses static trampolines). Inferred, not tested; M3 can confirm with a
Developer ID launch.

## The Keychain problem is code, not capabilities

`PostgresService.save` and `GaragePostgresEndpoint.readPassword` use the legacy file keychain (no
`kSecUseDataProtectionKeychain`, no `kSecAttrAccessGroup`). Legacy items carry a per-binary ACL, so
every other binary (XPC services, launchers, the other build flavor) gets a prompt. No portal
switch fixes that. Options:

1. **Password file in the app group container, mode 0600** (recommended). Every component already
   has the group; `isolatedPasswordFile` already does exactly this for test folders. Works for the
   launchers, which as bare Mach-O tools cannot embed a provisioning profile.
2. Data protection keychain with `kSecAttrAccessGroup = DWVXMLB45Y.group.me.rickmark.garage-rag`.
   Needs `application-identifier` in each reader, which on macOS is a restricted entitlement: a
   new App ID and profile per XPC service, and the launchers would have to become bundled apps.

## To verify on M3

`codesign -d --entitlements - --xml` on each Mach-O in a store archive, to confirm the table above
matches what actually ships.
