# Relays

## Defaults

krivostr connects to three public relays, hard-coded in
`client/src/Krivostr/Cli/Nostr.hs` (`defaultRelays`):

- `wss://relay.damus.io`
- `wss://nos.lol`
- `wss://relay.primal.net`

Those are the fallback, not the whole story. The effective upstream set
resolves in three layers — `--upstream` flags, then the `relay_config` table
in SQLite, then the compiled-in defaults — and flags union with the table
rather than overriding it:

```bash
krivostr serve --upstream wss://relay.example.com --upstream wss://nos.lol
krivostr relay list      # the effective set serve would connect to
krivostr relay add wss://my-relay.example     # remembered in SQLite
krivostr relay remove wss://relay.damus.io    # forgotten (see below)
```

A flag adds a relay for one run without disturbing the saved set; when both
flags and table are empty, the three defaults apply. `relay list` prints the
effective set, noting on stderr when it falls back to defaults so stdout stays
a clean URL list.

Two honest details. The bridge's 30-second loop (`retryRelays`) picks up
`relay add` automatically, but a `relay remove` only forgets — a connection
already in use stays until it drops or the bridge restarts. For a live disconnect, use
`DELETE /relays` on the running bridge instead. And a newly connected relay
(upstream or bunker) is replayed every live client subscription, so it joins
the feed instead of sitting silent.

## NIP-11 relay info

The core `Krivostr.Nip.Nip11` module parses the NIP-11 document and answers
`supportsNip`; no CLI subcommand prints it yet, and nothing requests it on
connect, so no relay's capabilities are discovered in practice. When that
changes, the capabilities worth asking about are:

- Whether the relay enforces NIP-42 on reads (required for NIP-59 read privacy)
- Whether it serves kind 1059 (gift wrap)
- Whether it honours NIP-50 search
- Whether it supports PoW (NIP-13)

## NIP-65 relay hints

`Krivostr.Nip.Nip65` parses kind 10002 into `readRelays` and `writeRelays`.
The UI has a matching reader in
[`ui/src/nostr/nip65.ts`](../ui/src/nostr/nip65.ts).

Three limits worth knowing:

- **krivostr never publishes kind 10002.** It can read your relay list; it will
  not write one for you.
- **`writeRelays` is parsed and then ignored.** Publishing does not consult it.
- **Sends consult stored read hints first.** `feed --follow`, `dm`, and the
  other send paths try the newest kind-10002 read relays in the store when no
  `--relay` flag names relays explicitly, falling back to the compiled-in
  defaults. There is no `relay-hints` subcommand; the hints are an input to
  sending, not something printed.

## NIP-42 authentication

Relays that require authentication send an `AUTH` challenge (NIP-42). The CLI
implements the handshake through the relay pool:

1. Relay sends `["AUTH", <challenge>]`.
2. The pool builds a kind 22242 event with the relay's URL and the challenge as
   tags, signed by the loaded key.
3. The pool sends `["AUTH", <signed-event>]`.

The relay handle keeps only the **newest** challenge: a new one overwrites the
previous, so a stale challenge can never be signed and replayed.

## NIP-59 gift wrap

Relays that serve kind 1059 (gift wrap) can be used for private messages. The
relay sees only the kind 1059 wrapper; the inner rumor (kind 14) is encrypted
with NIP-44. Relays SHOULD gate kind 1059 behind NIP-42 auth.

**NIP-59 read privacy requires NIP-42 enforcement on reads.** A relay that
supports NIP-42 but never enforces it on reads offers no read privacy — a
passive observer can harvest every encrypted message and social graph.

## The bridge as a "personal relay"

The Haskell bridge is not a public relay. It is a personal, single-user relay
that runs on your machine. It:

- Caches events from upstream relays.
- Serves them from SQLite on request.
- Forwards your publishes to the effective upstream set (flags ∪ table, else
  defaults), queueing in the SQLite `outbox` what no relay confirms.
- Enforces a retention policy (30 days for ephemeral, forever for persistent
  kinds).
- Does not yet require browser clients to authenticate (NIP-42 on the bridge is
  not implemented).
- Stores kind 1059 gift wraps like any other event; it cannot open them.

This means your browser can scroll back a month even if upstream relays have
pruned everything. It also means your browser doesn't need to maintain a dozen
WebSocket connections.

## Choosing relays

The supported options, in increasing permanence:

1. Pass `--upstream` to `krivostr serve` (one run).
2. `krivostr relay add` to remember a relay, `krivostr relay remove` to forget
   one (plus a restart, or `DELETE /relays`, to drop a live connection).
3. Edit `defaultRelays` in `Cli/Nostr.hs` so the change applies to every
   subcommand.
4. Use a NIP-46 bunker, whose relay *is* configurable per signer — the only
   place a user can name an arbitrary relay without a flag or a table row.

**There is no environment variable or config file for this list.** No
`KRIVOSTR_UPSTREAMS` exists; the `relay_config` table is the persistent
store, and the compiled-in defaults are the fallback.