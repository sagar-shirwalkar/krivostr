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
| `Krivostr.Nip.Nip65` | Kind 10002 relay-list metadata. |
| `Krivostr.Schnorr` | BIP-340 over secp256k1, in `Integer` arithmetic. |
| `Krivostr.Key` | x-only public keys, `nsec`/`npub` NIP-19 encoding. |
| `Krivostr.Logging` | `Writer`-based logger for functions that explain themselves. |

Tested with `hspec` (87 examples). `QuickCheck` is a declared dependency but no
property uses it yet — every core test is example-based.

## Client

Effectful Haskell. Dependencies that matter: `wuss` (WebSocket client and
server), `sqlite-simple` (SQLite), `warp` + `http-types` (the bridge and the
JSON API), `aeson` (JSON).

| Module | Responsibility |
|---|---|
| `Main` (`client/app/Main.hs`) | Entry point. It lives in `app/` rather than `src/` so the test suite, which compiles `src/` directly, never sees a second `Main`. |
| `Cli` | The nine-subcommand parser and rendering. |
| `Cli.Nostr` | Signing, publishing, `nsec` import, relay defaults. |
| `Cli.Api` | The JSON HTTP API on its own port. |
| `Cli.Render` | Terminal output. |
| `Pool` | The relay set, with broadcast and per-relay drain threads. |
| `Relay` | One upstream connection: connect, subscribe, reconnect. |
| `Store` | SQLite, FTS5, retention. |
| `Bridge` | The relay-shaped WebSocket endpoint plus static assets. |

`krivostr serve` runs the bridge, which owns the pool and the store. `api` runs
its own Warp server against the store. The rest — `feed`, `search`, `dm`,
`export`, `watch`, `reindex`, `keygen` — open the store directly, and most exit
when done; `feed --follow` and `watch` stay up until interrupted.

## UI

Lit 3 + TypeScript, no framework and no runtime dependency beyond `lit`,
`@lit/context`, `@lit/task`, `@noble/curves` and `@noble/hashes`.

The browser mirrors the core's vocabulary: `Maybe`, `Result`, `IO` in
[`ui/src/fp/`](../ui/src/fp), and a `Rule`/`Predicate` algebra in `algebra.ts`.

**One honest caveat.** `algebra.ts` implements `and`, `or`, `not`, `allOf` and
`anyOf`, but nothing in the app uses them — the only importer is the algebra's
own test. Filter matching in [`nostr/filter.ts`](../ui/src/nostr/filter.ts) is a
hand-rolled predicate, not a `Rule`. Treat the combinators as scaffolding until
either the filter path adopts them or they go.

The UI talks to the bridge over WebSocket and speaks the Nostr wire protocol
directly, so the bridge is a drop-in stand-in for a direct relay connection.

## Data flow

**Publishing.** The user types in `<nostr-compose>`, which bubbles a
`publish-request` to `<krivostr-app>`. The app calls the selected `Signer`,
then sends `["EVENT", …]` to the bridge. The bridge inserts it into SQLite,
broadcasts it to the upstream pool, delivers it to other connected clients, and
answers `OK`. The UI caches it in IndexedDB.

**Subscribing.** The bridge answers a `REQ` from its own store first: it
queries SQLite, replays the matching events, sends `EOSE`, and only then
broadcasts the `REQ` upstream. So a client gets history immediately and live
events afterwards, and the `EOSE` marks the seam between them.

## The two sides mirror each other

A protocol change usually needs a change on both sides. Filters are predicates
on both, failures are `Either`/`Result`, optionality is `Maybe`, and both
implement BIP-340 and NIP-19 independently — there is no cross-language FFI, so
each side can be wrong on its own. That is why
[`protocol.md`](protocol.md) documents the wire types once and expects both
implementations to match it.