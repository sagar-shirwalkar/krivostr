# Relays

## The outbox model

Instead of reading everyone's events from a single relay, we do this:

- **Read** from the relays *you* and *the people you follow* advertise in
  their NIP-65 lists.
- **Write** to *your own* write relays only.

This is the NIP-65 outbox model. It minimises the number of relays that can
observe your traffic, and it scales because each user's relay set is small.

## Defaults

Until we learn your NIP-65 list, we use:

- wss://relay.damus.io
- wss://nos.lol
- wss://relay.primal.net
- wss://nostr.wine

Once we receive your kind 10002 event, we replace the default set with your
read relays. Your write relays are used for publishing.

## The bridge as a "personal relay"

The Haskell bridge is not a public relay. It is a personal, single-user
relay that runs on your machine. It:

- Caches events from upstream relays.
- Serves them from SQLite on request.
- Forwards your publishes to your write relays.
- Enforces a retention policy (30 days for ephemeral, forever for
  persistent kinds).

This means your browser can scroll back a month even if upstream relays
have pruned everything. It also means your browser doesn't need to maintain
a dozen WebSocket connections.

## Adding a relay

Relays are configured in `client/src/Krivostr/Main.hs` under
`defaultUpstreams`. Override with `KRIVOSTR_UPSTREAMS` (comma-separated) in the environment.

## Removing a relay

Edit the same list, or use the environment variable.
