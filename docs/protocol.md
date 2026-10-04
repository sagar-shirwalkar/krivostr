# Protocol

krivostr speaks the [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md)
wire format. This document is the shared reference for both implementations:
[`core/src/Krivostr/Wire.hs`](../core/src/Krivostr/Wire.hs) and
[`ui/src/nostr/`](../ui/src/nostr).

## Events

| Field | Type | Notes |
|---|---|---|
| `id` | 32-byte hex | SHA-256 of the canonical serialization. |
| `pubkey` | 32-byte hex | x-only BIP-340 public key. |
| `created_at` | unix seconds | |
| `kind` | integer | |
| `tags` | `string[][]` | |
| `content` | string | |
| `sig` | 64-byte hex | BIP-340 Schnorr. |

The canonical serialization for the id is
`[0, pubkey, created_at, kind, tags, content]` — no whitespace, UTF-8, SHA-256.
`Krivostr.Nip.Nip01` builds it; the UI builds the same array in
[`nostr/event.ts`](../ui/src/nostr/event.ts).

### Signature verification

`Krivostr.Schnorr.verifyEvent` exists and is tested, but **ingest does not call
it.** Events are stored on their `id` and `pubkey` without checking that the
signature matches. Anything arriving from a relay or the bridge is therefore
unverified by the time it is stored or rendered.

The UI's `parseEvent` is likewise structural: it checks that the fields are
present and correctly typed, not that `id` is the hash of the content. This is a
known gap, called out in [security.md](security.md).

## Wire messages

The types below are the ADTs in `Krivostr.Wire`. Anything not listed here is
not produced or accepted.

Client to relay:

| Message | Notes |
|---|---|
| `["EVENT", <event>]` | Variadic in NIP-01; krivostr always sends exactly one event. |
| `["REQ", <sub-id>, <filter>…]` | Filters are **variadic**, per NIP-01. |
| `["CLOSE", <sub-id>]` | |

Relay to client:

| Message | Notes |
|---|---|
| `["EVENT", <sub-id>, <event>]` | |
| `["EOSE", <sub-id>]` | End of stored events. |
| `["OK", <event-id>, <bool>, <message>]` | |
| `["NOTICE", <message>]` | |
| `["CLOSED", <sub-id>, <message>]` | |
| `["AUTH", <challenge>]` | NIP-42 authentication challenge. |

### The REQ semantics that matter

A `REQ` carries any number of filters, and an event satisfies the request if it
matches **any** of them. Within one filter, every present clause must match —
they are conjunctive. The UI has it as `matchesAny` in
[`nostr/filter.ts`](../ui/src/nostr/filter.ts).

This is the distinction that matters in practice: multiple filters widen a
subscription, multiple clauses within one filter narrow it.

`Krivostr.Filter` exports only a single-filter `matches`, so the any-of rule
is applied by the caller — `any (\f -> Filter.matches f e) filters` in
`Bridge.hs`.

## Filters

| Key | Type | Semantics |
|---|---|---|
| `ids` | `string[]` | Event ids. |
| `authors` | `string[]` | x-only pubkeys. |
| `kinds` | `integer[]` | |
| `since` | integer | Inclusive lower bound on `created_at`. |
| `until` | integer | Inclusive upper bound on `created_at`. |
| `limit` | integer | Maximum events to return. |
| `#<name>` | `string[]` | Tag filter; matches if any tag with that name carries any listed value. |

The UI's `FilterSpec` presents tag filters as a `tags` record and
`toWire` flattens them into `#name` keys before sending.

## NIPs implemented

| NIP | Title | Status |
|---|---|---|
| 01 | Basic protocol | ✅ full — variadic `REQ` filters, `EVENT`, `EOSE`, `OK`, `NOTICE`, `CLOSED` |
| 02 | Follow list | ❌ not implemented |
| 04 | Encrypted direct messages | ◐ CLI can send (NIP-04); UI cannot read incoming DMs |
| 07 | `window.nostr` | ✅ full |
| 19 | bech32 entities | ◐ Haskell does `npub` / `nsec` only; UI encodes all six |
| 40 | Expiration timestamp | ✅ `expiration` tag for deterministic purge (bridge + UI) |
| 42 | Authentication | ✅ NIP-42 challenge/response (ephemeral kind 22242, single-challenge queue) |
| 44 | Versioned encryption | ✅ NIP-44 v2 (ChaCha20-Poly1305 + HKDF) with short-ciphertext panic fix and payload-size guard |
| 46 | Remote signer | ◐ implemented over NIP-04, not reachable from UI (NIP-44 transport planned) |
| 49 | Private-key encryption | ✅ NIP-49 `ncryptsec` (scrypt + XChaCha20-Poly1305, bech32 `ncryptsec1...`) |
| 50 | Search | ◐ local FTS5 only — no wire `search` filter |
| 59 | Gift wrap | ✅ NIP-59 kind 1059 (rumor → NIP-44 seal → ephemeral-key wrap) |
| 17 | Private direct messages | ✅ NIP-17 (rumor → NIP-44 seal → gift wrap, randomized timestamp ±2 days) |
| 65 | Relay list metadata | ◐ kind 10002 drives CLI read relays; `writeRelays` unused |

**NIP-04 is a backend feature.** `krivostr dm` encrypts with `encryptNip04` in
[`client/src/Krivostr/Cli/Nostr.hs`](../client/src/Krivostr/Cli/Nostr.hs) —
AES-256-CBC under an ECDH shared secret — before publishing, but nothing in the
UI decrypts: no UI module imports a NIP-04 implementation at all. A DM stored
by the bridge is unreadable in the browser today.

**NIP-44 v2 is a core feature.** Both Haskell (`Krivostr.Nip.Nip44`) and
TypeScript (`ui/src/nostr/nip44.ts`) implement the same ChaCha20-Poly1305 +
HKDF-SHA256 construction with two security fixes over the reference spec:
1. **Short-ciphertext panic fix** — validates ciphertext length before indexing
   the 2-byte length prefix (the spec reads `buffer[0..2]` after HMAC passes,
   which panics on <2 bytes).
2. **Payload-size guard** — enforces maximum payload size BEFORE base64 decoding
   (the spec decodes the full attacker-controlled payload before checking
   version/size).

**NIP-19 is asymmetric.** The UI encodes and decodes `npub`, `nsec`, `note`,
`nprofile`, `nevent` and `naddr` in a hand-rolled
[`bech32.ts`](../ui/src/nostr/bech32.ts). The Haskell core handles `npub` and
`nsec` only: `importNsec` and `importNpub` reject any other human-readable part,
and `Key.hs` has no `nprofile` decoder. `nprofile` appears there only in
comments.

**NIP-65 is read-only.** `Krivostr.Nip.Nip65` parses kind 10002 into
`readRelays` and `writeRelays`, and `krivostr relay-hints` resolves a pubkey's
read relays. Nothing publishes a kind 10002, and `writeRelays` is parsed but
never consulted when publishing.

**NIP-46 is unreachable from the browser.** `nip46Signer` is complete and
unit-tested, but `nostr-signer-picker.ts` imports only `localSigner` and
`nip07Signer`, so nothing constructs a bunker signer. It also takes its NIP-04
implementation as an **injected parameter** — the module imports no crypto for
it — so a caller would have to supply one. Reaching a bunker from the UI means
wiring up the picker and passing a NIP-44 implementation.

**NIP-59 gift wrap** wraps a rumor (unsigned kind 14) encrypted with NIP-44
into an ephemeral-key-signed kind 1059 event. The relay sees only the wrapper.

**NIP-17 composes NIP-44 + NIP-59** for private direct messages. A rumor (kind
14) is sealed with NIP-44, wrapped in a gift wrap (kind 1059), with a
randomized timestamp (±2 days) to defeat timing correlation.

**NIP-49 `ncryptsec`** encrypts private keys at rest using scrypt +
XChaCha20-Poly1305, encoded as bech32 `ncryptsec1...`. The Haskell and
TypeScript implementations share the same derivation logic.

**NIP-42 authentication** uses ephemeral kind 22242 events with a relay-supplied
challenge. The bridge and CLI implement a single-challenge queue (a new
challenge invalidates the previous one) to prevent challenge-queue exhaustion.

**NIP-40 expiration** tags let the bridge and UI purge ephemeral ciphertexts
deterministically, shrinking the window in which a stolen SQLite file is useful.

**NIP-11 relay info** is requested on connect to discover whether a relay
supports NIP-42, NIP-59, NIP-50, or PoW before sending traffic.

## Not implemented

- **NIP-02** follow lists: no parsing or rendering of kind 3. Kind 3 is stored
  and retained, nothing more.
- **NIP-09** deletion: no deletion-request handling. Kind 5 is recognized as a
  kind name but never published.
- **NIP-50** search: **local only**. The bridge has an FTS5 index and
  `krivostr search` queries it, but no `search` field is ever placed on the
  wire, so filters are not forwarded to relays and no relay is asked to search.
- **NIP-11** relay information: not requested, so the bridge reports no
  software version.