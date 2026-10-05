# Architecture

Three layers, one rule: **the core knows nothing about the world.**

| Path | Language | Role |
|---|---|---|
| [`core/`](../core/src/Krivostr) | Haskell | Protocol algebra. Deterministic, no effects. |
| [`client/`](../client/src/Krivostr) | Haskell | Every effect: SQLite, WebSockets, HTTP, CLI. |
| [`ui/`](../ui/src) | TypeScript | Browser. Mirrors the core's algebra. |

The split is a testability boundary. `core/` can be tested without a socket, a
database, or a clock, because nothing in it can reach one.

## The boundary rule

`core/` contains no `IO`, no exceptions, and no `unsafePerformIO`. **Two
functions are exceptions, both deliberate:**

- `Krivostr.Key.generatePrivateKey` reads 32 bytes from `/dev/urandom`. There
  is no way to get entropy in pure Haskell.
- `Krivostr.Logging.newLogger` is the one `IO` constructor in the logger; the
  rest of `Logging` is a `Writer` that a caller supplies.

`Krivostr.Key` also reads key files with `withBinaryFile` for `importNsecFile`.
Everything else in the core is a value in, a value out.

If a change needs IO, it belongs in `client/`. That is the rule that keeps the
core honest.

## Core

Pure Haskell. No network, no database, no clock — timestamps arrive as
`POSIXTime` arguments.

| Module | Responsibility |
|---|---|
| `Krivostr.Event` | The event record and its accessors. |
| `Krivostr.Filter` | A filter record and `matches`, a predicate over events. |
| `Krivostr.Wire` | `ClientMessage` / `RelayMessage` ADTs, `encodeClient`, `decodeRelay`. |
| `Krivostr.Nip.Nip01` | Canonical serialization, event id, sign, verify. |
| `Krivostr.Nip.Nip44` | ChaCha20-Poly1305 + HKDF (v2, short-ciphertext guard, payload-size guard). |
| `Krivostr.Nip.Nip59` | Gift wrap (rumor → NIP-44 seal → ephemeral key). |
| `Krivostr.Nip.Nip17` | Private DMs (rumor → NIP-44 seal → gift wrap, ±2 day timestamp). |
| `Krivostr.Nip.Nip49` | `ncryptsec` (scrypt + XChaCha20-Poly1305, bech32 `ncryptsec1...`). |
| `Krivostr.Nip.Nip42` | Auth (ephemeral kind 22242, single-challenge queue). |
| `Krivostr.Nip.Nip40` | Expiration tag purge. |
| `Krivostr.Nip.Nip11` | `supported_nips` discovery. |
| `Krivostr.Nip.Nip65` | Kind 10002 relay-list metadata. |
| `Krivostr.Schnorr` | BIP-340 over secp256k1, in `Integer` arithmetic. |
| `Krivostr.Key` | x-only keys, `nsec`/`npub` NIP-19, `ncryptsec` NIP-49. |
| `Krivostr.Logging` | `Writer`-based logger for functions that explain themselves. |

Tested with `hspec` (87 examples). `QuickCheck` is a declared dependency but no
property uses it yet — every core test is example-based.

## Client

Effectful Haskell. Dependencies that matter: `wuss` (WebSocket client and
server), `sqlite-simple` (SQLite), `warp` + `http-types` (the bridge and the
JSON API), `aeson` (JSON).

| Module | Responsibility |
|---|---|
| `Main` (`client/src/Main.hs`) | Entry point. |
| `Cli` | The nine-subcommand parser and rendering. |
| `Cli.Nostr` | Signing, publishing, `nsec` import, relay defaults, NIP-42 auth. |
| `Cli.Api` | The JSON HTTP API on its own port (NIP-42 auth). |
| `Cli.Render` | Terminal output. |
| `Pool` | The relay set, with broadcast and per-relay drain threads. |
| `Relay` | One upstream connection: connect, subscribe, reconnect, NIP-42 auth. |
| `Store` | SQLite, FTS5, NIP-40 purge, NIP-59 storage. |
| `Bridge` | The relay-shaped WebSocket endpoint plus static assets (NIP-42 auth). |
| `Nip44` | ChaCha20-Poly1305 + HKDF (bridge + CLI DMs). |
| `Nip59` | Gift wrap bridge logic. |
| `Nip17` | Private DM CLI commands. |
| `Nip49` | `ncryptsec` key import/export. |
| `Nip42` | Auth challenge/response (bridge + CLI). |
| `Nip40` | Expiration tag enforcement. |
| `Nip11` | Relay capability discovery. |

`krivostr serve` runs the bridge, which owns the pool and the store. Every
other subcommand opens the store directly and exits (except `feed --follow`
and `watch`, which stream).

`krivostr serve` binds to the interface specified by `--host` (default
`127.0.0.1`, env `KRIVOSTR_BRIDGE_HOST`). The JSON API binds to `--host`
(default `127.0.0.1`, env `KRIVOSTR_API_HOST`).

## UI

Lit 3 + TypeScript, no framework and no runtime dependency beyond `lit`,
`@lit/context`, `@lit/task`, `@noble/curves` and `@noble/hashes`.

The browser mirrors the core's vocabulary: `Maybe`, `Result`, `IO` in
[`ui/src/fp/`](../ui/src/fp), and a `Rule`/`Predicate` algebra in
`algebra.ts`.

**One honest caveat.** `algebra.ts` implements `and`, `or`, `not`, `allOf` and
`anyOf`, but nothing in the app uses them — the only importer is the algebra's
own test. Filter matching in [`nostr/filter.ts`](../ui/src/nostr/filter.ts) is
a hand-rolled predicate, not a `Rule`. Treat the combinators as scaffolding
until either the filter path adopts them or they go.

The UI talks to the bridge over WebSocket and speaks the Nostr wire protocol
directly, so the bridge is a drop-in stand-in for a direct relay connection.

## Data flow

**Publishing.** The user types in `<nostr-compose>`, which bubbles a
`publish-request` (content, kind, tags) to `<krivostr-app>`. The app calls
the selected `Signer`, then sends `["EVENT", …]` to the bridge. The bridge
inserts it into SQLite, broadcasts it to the upstream pool, delivers it to
other connected clients, and answers `OK`. The UI caches it in IndexedDB.
Reply, react, and repost buttons on each note dispatch the same event with
prebuilt tags, so one signer path serves every social action.

**Subscribing.** The bridge answers a `REQ` from its own store first: it
queries SQLite, replays the matching events, sends `EOSE`, and only then
broadcasts the `REQ` upstream. So a client gets history immediately and live
events afterwards, and the `EOSE` marks the seam between them. A `search`
filter is answered from the FTS5 index on the same path — the bridge's
instant search is this replay with a MATCH clause.

**Counting.** A `COUNT` never leaves the bridge: it is answered from SQLite
(one indexed `COUNT(*)`, FTS subquery for search) and overlapping filters
union by id. Upstream relays answer for themselves when asked directly.

**Deleting and muting.** A kind 5 removes the author's own rows from SQLite
and publishes upstream; other clients hide cited targets by the same
authorship rule. Mute lists (kind 10000) are retention-exempt user state;
the UI filters on its own list locally, so muting needs no relay support.

**Opening and zapping.** A clicked `nostr:` mention resolves to an event
reader (one-shot fetch by id, newest version by address) or an author view
(feed swap), never a page load. A zap signs a kind 9734 and sends it to the
LNURL callback — it is never published — and the wallet pays out of band;
kind-9735 receipts render as claims with invoice-decoded amounts.

**NIP-42 auth on the CLI.** The relay pool answers a challenge with a kind
22242 event signed by the loaded key, so `feed --follow` and `dm` work against
`auth-required` relays. The bridge itself does not yet require browser clients
to authenticate.

**NIP-59 gift wrap and NIP-17 private DMs.** Both are implemented in `core`
(`Krivostr.Nip.Nip59`, `Krivostr.Nip.Nip17`) and in the browser
(`ui/src/nostr/nip59.ts`, `ui/src/nostr/nip17.ts`), each covered by tests —
the TypeScript side opens the spec's published seal to the published rumor.
Neither is wired into a send path yet: `dm` still sends NIP-04 kind 4, and
the compose box publishes plaintext notes.

**NIP-49 `ncryptsec`.** The core `Krivostr.Nip.Nip49` module encrypts private
keys with scrypt + XChaCha20-Poly1305. The UI does not use it yet — IndexedDB
holds keys in the clear.

## The two sides mirror each other

A protocol change usually needs a change on both sides. Filters are predicates
on both, failures are `Either`/`Result`, optionality is `Maybe`, and both
implement BIP-340 and NIP-19 independently — there is no cross-language FFI, so
each side can be wrong on its own. That is why
[`protocol.md`](protocol.md) documents the wire types once and expects both
implementations to match it.