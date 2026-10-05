# Relays

## Defaults

krivostr connects to three public relays, hard-coded in
[`client/src/Krivostr/Cli/Nostr.hs:42`](../client/src/Krivostr/Cli/Nostr.hs):

- `wss://relay.damus.io`
- `wss://nos.lol`
- `wss://relay.primal.net`

**There is no environment variable or config file for this list.** No
`KRIVOSTR_UPSTREAMS` exists. Changing the set means editing that source list and
rebuilding. Every relay krivostr opens is one of these three, or a relay named
in a bunker URL.

The one supported override is a repeatable flag on `serve`:

```bash
krivostr serve --upstream wss://relay.example.com --upstream wss://nos.lol
```

Passing at least one `--upstream` replaces the defaults entirely; passing none
keeps all three. There is no equivalent flag on the other subcommands, and no
environment variable anywhere.

## NIP-11 relay info

The core `Krivostr.Nip.Nip11` module parses the NIP-11 document and answers
`supportsNip`. Nothing requests it on connect yet, so no relay's capabilities
are discovered in practice. A relay may:

- Enforces NIP-42 on reads (required for NIP-59 read privacy)
- Serves kind 1059 (gift wrap)
- Honours NIP-50 search
- Supports PoW (NIP-13)

The core `Krivostr.Nip.Nip11` module parses the document and answers
`supportsNip`; no CLI subcommand prints it yet.

## NIP-65 relay hints

`Krivostr.Nip.Nip65` parses kind 10002 into `readRelays` and `writeRelays`.
`krivostr relay-hints <npub>` looks up a pubkey's most recent kind 10002 in the
local store and prints the read relays. The UI has a matching reader in
[`ui/src/nostr/nip65.ts`](../ui/src/nostr/nip65.ts).

Three limits worth knowing:

- **krivostr never publishes kind 10002.** It can read your relay list; it will
  not write one for you.
- **`writeRelays` is parsed and then ignored.** Publishing does not consult it.
- **Publishing uses `dmRelays`, or the default set if there are none** — see
  `Cli.Nostr`. The outbox model this NIP describes is *not* what happens, and
  the "personal relay" framing below should be read with that in mind.

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
- Forwards your publishes to your write relays (currently `dmRelays` or the
  default set).
- Enforces a retention policy (30 days for ephemeral, forever for persistent
  kinds).
- Does not yet require browser clients to authenticate (NIP-42 on the bridge is
  not implemented).
- Stores kind 1059 gift wraps like any other event; it cannot open them.

This means your browser can scroll back a month even if upstream relays have
pruned everything. It also means your browser doesn't need to maintain a dozen
WebSocket connections.

## Choosing relays

Because the list is a source constant, the honest options are:

1. Pass `--upstream` to `krivostr serve`.
2. Edit `defaultRelays` in `Cli/Nostr.hs` so the change applies to every
   subcommand.
3. Use a NIP-46 bunker, whose relay *is* configurable per signer — the only
   place a user can name an arbitrary relay without a flag.

If relay configuration becomes a real requirement, the change is small and
belongs in `Cli.Nostr`: read a `KRIVOSTR_UPSTREAMS` value, fall back to the
defaults, and document it in `.env.example`.