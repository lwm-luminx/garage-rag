# One corpus across several Macs: corpus-side notes (Garage v2)

Status: exploration, no code. Revised 2026-09-29.

**The design is `../postgres-sync/peer-sync-design.md`.** Rick's goal: index several Macs and have
the corpus answer equally well from any of them, as a v2 feature, opt-in, with Postgres hidden
behind Garage's own peer protocol (gRPC, Bonjour, gossip). That document covers ownership (every
document has one owner Mac, others hold replicas), content-addressed document bundles, digest
gossip over `GaragePeerService`, pairing and TLS, per-source sharing (off by default for
communications), and one index and one query on every Mac.

This file does not repeat any of that. It lists corpus-side points the peer-sync design should
carry. Earlier drafts here are superseded: the first read the ask as separate work/personal
libraries (kept as `separate-libraries.md`), the second proposed a shared-folder transport, now
dropped in favor of the peer protocol.

## Additions for the peer-sync design

1. **Local-only operations must be scoped to the owner.** Today declared sources in `garage.json`
   are re-applied on every run and `Reconcile` removes documents no longer found on disk. Once
   replicas share the tables, every such path (sync sources, reconcile, remove source, reset,
   `ingest_outcomes` cleanup) must touch only rows whose `origin_node` is this Mac, or the iMac
   "reconciles away" the MacBook's documents. This is the most likely bug class and needs its own
   tests.
2. **Source slugs are unique per owner, not globally.** Two Macs can each have `notes`, so
   `sources.slug UNIQUE` becomes `UNIQUE (origin_node, slug)`, and every API that takes a
   `source_slug` (`PersistDocument`, the MCP `rag_search` source filter, the Sources page, the
   CLI) needs the owner too.
3. **Version skew between Macs.** Paired Macs will run different Garage versions. Bundles carry a
   format version; a Mac that can't apply one keeps it queued and the Status page says "MacBook is
   on a newer Garage; update this Mac to see its latest documents" rather than failing silently.
4. **Model gaps must be visible.** After a model is registered, owners backfill their own documents
   at different times. Until then, search on that model has holes; search and Status should say
   "MacBook not yet embedded with bge-m3" instead of silently ranking those documents lower.
5. **Connection budget.** The bundled cluster is set up with `max_connections=5`
   (`PostgresService.swift:419`, at `initdb`). A bundle-apply worker adds a pool beside the
   backend, ingest, embed and MCP processes. Raise it at server start (not only at `initdb`, so
   existing clusters get it) before sync lands; worth checking now whether one database already
   comes close.
6. **Storage.** Every Mac holds every owner's documents, chunks and vectors for every registered
   model, so disk grows with the number of Macs. A per-Mac "don't keep replicas from X" and a thin
   mode that uses the design's optional live federation instead of a replica are the valves.
7. **Opening a hit from another Mac.** Show the stored text, label it with its owner ("on Mac
   mini"), offer Reveal in Finder only on the owner, and never materialize a cloud placeholder for
   a replica.

## Pairing and trust

Rick (2026-09-29): each Mac keeps every paired Mac's public key / certificate in the catalog
(`garage_catalog`, see `separate-libraries.md`), and that is what permits mTLS for sync. How a
certificate gets there is a **pairing policy**, with a secure way to pair behind each choice.

**Keys.** Each Mac generates its own key pair and self-signed certificate once. The private key
never leaves the Mac: a non-synchronizable item in the data-protection Keychain, ideally in the
Secure Enclave (P-256, usable as a TLS client identity through Network.framework's
`sec_identity`; to verify). The certificate's fingerprint is the Mac's node identity.

**Trust is countersigned (Rick, 2026-09-29).** A stored certificate alone does not make a peer
trusted. When this Mac accepts a pairing, under any policy, it signs a trust record with its own
machine private key and stores the signature beside the peer's certificate in the catalog. The
record holds:

- the peer's certificate fingerprint;
- the peer's node id;
- this Mac's node id;
- the pairing time and the anchor used (code or iCloud Keychain).

At every mTLS handshake, this Mac accepts the client certificate only if a catalog row matches it
**and** that row's countersignature verifies against this Mac's own public key. What this buys:

- Writing to the catalog isn't enough to add a peer. Anything that can reach Postgres with the
  database password, a tampered or restored backup, or a bug that inserts a row, can't make a
  Mac trusted without the private key, which lives in the Keychain or Secure Enclave and can't be
  exported.
- A catalog restored on a different Mac trusts nobody there, because the countersignatures belong
  to the old machine key. The peers have to be paired again, which is the right outcome.
- A countersignature by itself speaks only for the Mac that made it: B trusting C does not make A
  trust C. Vouching (below) is how trust passes along on purpose.
- Revocation deletes the row and its signature. Rotating this Mac's key invalidates every
  countersignature at once, so rotation is also a way to revoke everyone.

With the Secure Enclave, signing needs no user prompt but works only on that Mac. Verification
uses the public key cached in the catalog's own `nodes` row for this Mac, which is itself checked
against the Keychain identity at start-up.

**Countersign or countersign and vouch (Rick, 2026-09-29).** When a Mac is included, the person
pairing chooses one of two options:

- **Trust on this Mac** (countersign only): as above. Only this Mac trusts the new peer.
- **Trust and vouch for it**: this Mac countersigns and also issues a **vouch**. The vouch is a
  statement signed with its machine key: "B vouches for certificate C (fingerprint, node id, name),
  at time t". It travels to B's other paired Macs over the peer protocol, as a small record in the
  gossip digest.

**What a vouch means (Rick, 2026-09-29): everyone who trusts the vouching Mac ought to trust the
new peer.** So when A trusts B and receives B's vouch for C, A trusts C automatically. There is no
prompt and no per-pairing flag. A records its own countersignature for C with the anchor
"vouched by B", so the handshake rule is unchanged: a peer gets in only on this Mac's own
countersignature. A shows a notice ("Mac mini joined, vouched for by MacBook Pro") and lists C
under Paired Macs with its anchor.

What follows from the rule:

- **Chains.** A trusts C because of B's vouch. If C later vouches for D, A trusts D too, since A
  trusts C. The choice to vouch is made on the Mac that includes the new peer. A Mac that
  countersigns only (no vouch) adds a peer for itself alone.
- **Trust is derived, so revocation recomputes it.** Each Mac keeps its direct anchors (code,
  iCloud Keychain) and the vouches it has received. Trust is whatever is reachable from the direct
  anchors through vouches. When B withdraws its vouch for C (a signed revocation that gossips like
  the vouch), or A unpairs B, A recomputes. C, and anything trusted only through C, drops out,
  unless another path still reaches it (for example A also paired C by code). The recomputation
  also makes cycles harmless.
- **A vouch is only as good as the voucher.** A compromised Mac that trusts others and vouches can
  add peers to every Mac that trusts it. The defenses are unpairing it, which cascades as above,
  and key rotation. The Paired Macs list shows each peer's anchor path, so a surprise is visible.
- **Trust, not sharing.** A vouched Mac, like any new peer, receives nothing until a corpus is
  shared with it. Vouching could offer "also share the corpora I share with you" as a separate,
  explicit checkbox.
- The iCloud Keychain anchor already acts as a vouch by the Apple account. Vouching is how Macs
  pair across accounts, or without iCloud, after a single code exchange.

**Ways to pair (trust anchors):**

| Anchor | How it works | Assessment |
|---|---|---|
| **Code on screen** (default) | Mac A shows a short code or QR; Mac B enters or scans it. A PAKE (SPAKE2 or CPace) over the Bonjour connection turns the code into a shared secret that authenticates the certificate exchange, so an attacker on the LAN can't slip in its own. Both Macs then show "Paired with MacBook Pro". | Works for any two Macs, with no Apple account dependency. One deliberate act per pair. |
| **iCloud Keychain** (automatic for my Macs) | Each Mac publishes its certificate fingerprint and name as a **synchronizable** Keychain item in the team's access group. A Mac that finds a fingerprint there trusts it without a code. | iCloud Keychain is end-to-end encrypted even without Advanced Data Protection, so neither Apple nor anyone with just the account password can inject a fingerprint. The App Store and Developer ID builds share the team, so they see the same items. The fingerprint must be published from the Mac itself, so trust follows the user's own devices. **Recommended as the opt-in automatic mode.** |
| iCloud key-value store (`NSUbiquitousKeyValueStore`) | Same idea as above, through iCloud KV. | Not end-to-end encrypted without ADP, so its integrity rests on Apple's servers. Fingerprints are public, but the trust decision needs integrity, so it's weaker than the Keychain for the same work. Not recommended as a trust anchor. At most it could serve as a discovery hint ("your Mac mini exists") that still needs a code. |
| Managed configuration (MDM profile listing fingerprints) | For a team or a fleet. | Later, if Garage is ever deployed by an organization. |

**Pairing policy** (a Mac-wide setting in the catalog's `app_settings`):

- **Off** (default while sync is off): nothing listens or advertises.
- **Ask with a code**: pairing only through the code flow.
- **Automatic for my Macs**: trust anything published in iCloud Keychain, and still allow codes.

Two rules hold under every policy. Pairing is only trust. What each peer *receives* is decided
per corpus and per source (`corpus_peers`, with communications opted out by default). New pairings
share nothing until a corpus is shared with them.

**Revocation.** Unpairing deletes the peer's catalog row and, under the automatic policy, its
Keychain item. That stops its future connections, and the peer drops its replicas of this Mac's
corpora on its next contact. Rotating a Mac's key (Settings, or after a suspected compromise)
re-publishes the certificate and needs re-pairing under the code policy.

## Multiple corpora

Multiple corpora on one Mac are still wanted and are separate from syncing Macs:
`separate-libraries.md` has that design (a database per corpus). Rick decided how MCP picks one
(2026-09-29): **a command-line parameter for stdio (`garage-mcp --corpus work`) and a URL path for
HTTP (`/mcp/work`)**, one corpus per connection, with the bare forms meaning the default corpus.
A **catalog database** (`garage_catalog`, Rick 2026-09-29) tracks the corpora, their settings,
MCP registrations and, for sync, paired Macs and which corpora each one shares; see
`separate-libraries.md`, "The catalog database". The two features compose: each corpus syncs across paired Macs on its own, so peer bundles and
digests need the corpus slug alongside `origin_node`.
