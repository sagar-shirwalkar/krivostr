# Relays

## Defaults

krivostr connects to three public relays, hard-coded in
[`client/src/Krivostr/Cli/Nostr.hs:42`](../client/src/Krivostr/Cli/Nostr.hs):

- `wss://relay.damus.io`
- `wss://nos.lol`
- `wss://relay.primal.net`

**There is no environment variable or config file for this list.** No
`KRIVOSTR_UPSTREAMS` exists — the previous version of this document claimed
otherwise. The list is a source constant in `Cli/Nostr.hs`.

The one supported override is a repeatable flag on `serve`:

```bash
krivostr serve --upstream wss://relay.example.com --upstream wss://nos.lol
```

Passing at least one `--upstream` replaces the defaults entirely; passing none
keeps all three. There is no equivalent flag on the other subcommands, and no
environment variable anywhere.

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

## The bridge

The bridge is a single-user cache and fan-out point, not a public relay. On
`serve` it holds one pool over the three default relays and one SQLite store.

What it actually does:

- Replays matching events from SQLite for a `REQ`, sends `EOSE`, then keeps the
  subscription open upstream. A client sees history and then live events.
- Stores every event it receives.
- Forwards a client's `EVENT` to the upstream pool and to other connected
  clients, then replies `OK`.
- Evicts expired rows hourly from a background thread.

What it does not do: verify signatures, enforce any limit, restrict who may
connect, or answer `INFO`. The `RelayMessage` type has no `INFO` constructor, so
a client asking for relay metadata gets nothing.

## Choosing relays

Because the list is a source constant, the honest options are:

1. Pass `--upstream` to `krivostr serve`.
2. Edit `defaultRelays` in `Cli/Nostr.hs` so the change applies to every
   subcommand.
3. Use a NIP-46 bunker, whose relay *is* configurable per signer — the only
   place a user can name an arbitrary relay without a flag.

If relay configuration becomes a real requirement, the change is small and
belongs in `Cli/Nostr`: read a `KRIVOSTR_UPSTREAMS` value, fall back to the
defaults, and document it in `.env.example`.