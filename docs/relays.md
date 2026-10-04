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

krivostr requests `supported_nips` on connect (NIP-11). This lets the client
discover whether a relay:

- Enforces NIP-42 on reads (required for NIP-59 read privacy)
- Serves kind 1059 (gift wrap)
- Honours NIP-50 search
- Supports PoW (NIP-13)

The CLI's `relay-info` command prints the relay's advertised capabilities.

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

Relays that require authentication send an `AUTH` challenge (NIP-42). The bridge
and CLI both implement the handshake:

1. Relay sends `["AUTH", <challenge>]`.
2. Client signs the challenge with an ephemeral key (kind 22242).
3. Client sends `["AUTH", <signed-challenge>]`.

The bridge and CLI implement a **single-challenge queue**: a new challenge
invalidates the previous one. This prevents challenge-queue exhaustion (an
attacker flooding the client with challenges to exhaust memory).

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
- **NIP-42 auth** — the bridge requires NIP-42 auth for private operations.
- **NIP-59** — the bridge can serve and forward kind 1059 gift wraps.

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