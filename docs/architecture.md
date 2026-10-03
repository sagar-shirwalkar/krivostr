# Architecture

krivostr has three layers and one rule: **the core is pure and knows nothing
about the world.**

## Core

Pure Haskell. No `IO` outside of cryptography and entropy.

- `Event` — an immutable record.
- `Nip.Nip01` — canonical serialization and Schnorr signing.
- `Nip.Nip65` — relay list metadata (kind 10002).
- `Filter` — a predicate over events.
- `Wire` — client/relay message ADTs.
- `Logging` — a `Writer`-based pure logger for functions that need to
  explain themselves.

The core is fully testable with `hspec` and `QuickCheck`. It has no
network, no database, and no clock beyond `POSIXTime` passed in as a value.

## Client

Effectful Haskell. Uses `wuss` for WebSocket, `sqlite-simple` for storage,
and `warp` for the bridge.

- `Relay` — a single upstream relay connection.
- `Pool` — a set of relays, with broadcast and subscription multiplexing.
- `Store` — SQLite persistence with a retention policy.
- `Bridge` — a relay-shaped WebSocket endpoint for the browser. Serves
  `/ws` and static assets.

The `Main` executable runs the bridge.

## UI

Lit 3.3 + TypeScript. Hand-rolled FP abstractions:

- `Maybe`, `Result`, `IO`, `pipe`, `compose`.
- `Rule`, `Monoid`, `validate` in `fp/algebra.ts`.
- `Signer` is an interface with three implementations.
- `FilterSpec` compiles to a `Rule<NostrEvent>`.

The UI talks to the bridge over WebSocket. It speaks the Nostr wire protocol,
so the transport layer is a drop-in replacement for direct relay connection.

## Data Flow

1. User types an event in `<nostr-compose>`.
2. `publish-request` bubbles to `<krivostr-app>`.
3. The app calls the chosen `Signer`.
4. The signed event is sent to the bridge (or directly to relays).
5. The bridge persists to SQLite and forwards to upstream relays.
6. Upstream relays return events. The bridge pushes to all connected UI
   clients.
7. The UI caches to IndexedDB.
