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

Every stored event is signature-checked on the way in. On the backend,
`Store.insertEvent` verifies first and answers `Inserted`, `Duplicate`, or
`InvalidSignature` — bridge client events, bridge upstream events, CLI
follows, and CLI saves all funnel through it, so a forged event has no path
into SQLite. In the browser, `cache.put` refuses events that fail
`verifyEvent`, so unverified bytes do not survive a restart in IndexedDB
either.

The UI's `parseEvent` stays structural on purpose: it checks that the fields
are present and correctly typed, not that `id` really is the hash of the
content. Decoding is not the trust boundary; the store and cache gates are.

## Wire messages

The types below are the ADTs in `Krivostr.Wire`. Anything not listed here is
not produced or accepted.

Client to relay:

| Message | Notes |
|---|---|
| `["EVENT", <event>]` | Variadic in NIP-01; krivostr always sends exactly one event. |
| `["REQ", <sub-id>, <filter>…]` | Filters are **variadic**, per NIP-01. |
| `["CLOSE", <sub-id>]` | |
| `["COUNT", <sub-id>, <filter>…]` | NIP-45: how many stored events match, without fetching them. |

Relay to client:

| Message | Notes |
|---|---|
| `["EVENT", <sub-id>, <event>]` | |
| `["EOSE", <sub-id>]` | End of stored events. |
| `["OK", <event-id>, <bool>, <message>]` | |
| `["NOTICE", <message>]` | |
| `["CLOSED", <sub-id>, <message>]` | |
| `["AUTH", <challenge>]` | NIP-42 authentication challenge. |
| `["COUNT", <sub-id>, {"count": N}]` | NIP-45 answer. |

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
| `search` | string | NIP-50 full-text search. Relays answer from their own index; the bridge answers from SQLite FTS5; single-event matching is a case-insensitive substring. |

The UI's `FilterSpec` presents tag filters as a `tags` record and
`toWire` flattens them into `#name` keys before sending.

## NIPs implemented

| NIP | Title | Status |
|---|---|---|
| 01 | Basic protocol | ✅ full — variadic `REQ` filters, `EVENT`, `EOSE`, `OK`, `NOTICE`, `CLOSED` |
| 02 | Follow list | ❌ not implemented |
| 04 | Encrypted direct messages | ◐ CLI can send (NIP-04); UI cannot read incoming DMs |
| 05 | DNS identifiers | ✅ parse + HTTPS `nostr.json` verify (`krivostr verify`, UI badge logic) |
| 07 | `window.nostr` | ✅ full |
| 09 | Event deletion | ✅ kind 5 (author-checked), `krivostr delete`, local removal + UI hide |
| 10 | Reply conventions | ✅ marked + positional `e` tags, `krivostr reply`, UI thread rendering |
| 13 | Proof of work | ✅ `nonce` tag, leading-zero-bit difficulty, committed target |
| 18 | Reposts | ✅ kind 6 / 16 + `q`-tag quotes, `krivostr repost`, UI rendering |
| 19 | bech32 entities | ✅ `npub`/`nsec` keys plus `nevent`/`naddr` TLV pointers, both sides |
| 21 | `nostr:` URIs | ✅ single-reference parse; UI mentions open in-client (reader/author views) |
| 22 | Comments | ✅ kind 1111 (uppercase root / lowercase parent), `krivostr comment`, UI threads |
| 23 | Long-form content | ✅ kind 30023 articles, `krivostr publish`, UI article rendering |
| 25 | Reactions | ✅ kind 7 with `e`/`p`/`k` tags, `krivostr react`, UI counts |
| 27 | Text note references | ✅ `nostr:` scanning, `krivostr resolve`, UI mention rendering |
| 36 | Sensitive content | ✅ `content-warning` tag, CLI gate, UI blur-to-reveal |
| 40 | Expiration timestamp | ✅ `expiration` tag for deterministic purge (bridge + UI) |
| 42 | Authentication | ✅ NIP-42 challenge/response (ephemeral kind 22242, single-challenge queue) |
| 44 | Versioned encryption | ✅ NIP-44 v2 (ChaCha20 + HMAC + HKDF) with short-ciphertext panic fix and payload-size guard |
| 45 | Counting results | ✅ wire `COUNT`, bridge answers from SQLite, `krivostr count`, UI `count()` |
| 46 | Remote signer | ✅ bunker over NIP-44, wired into the signer picker |
| 49 | Private-key encryption | ✅ NIP-49 `ncryptsec` (scrypt + XChaCha20-Poly1305, bech32 `ncryptsec1...`) |
| 50 | Search | ✅ wire `search` filter; bridge answers from FTS5, CLI `--search`, UI search box |
| 51 | Lists | ✅ mute / pin / bookmark, `krivostr list`, UI mute filtering |
| 57 | Lightning zaps | ✅ kind 9734 request + 9735 receipts, LNURL flow, UI zap dialog |
| 59 | Gift wrap | ✅ NIP-59 kind 1059 (rumor → NIP-44 seal → ephemeral-key wrap) |
| 17 | Private direct messages | ✅ NIP-17 (rumor → NIP-44 seal → gift wrap, randomized timestamp ±2 days) |
| 65 | Relay list metadata | ◐ kind 10002 drives CLI read relays; `writeRelays` unused |

**NIP-04 is a backend feature.** `krivostr dm` encrypts with `encryptNip04` in
[`client/src/Krivostr/Cli/Nostr.hs`](../client/src/Krivostr/Cli/Nostr.hs) —
AES-256-CBC under an ECDH shared secret — before publishing, but nothing in the
UI decrypts: no UI module imports a NIP-04 implementation at all. A DM stored
by the bridge is unreadable in the browser today.

**NIP-44 v2 is implemented on both sides.** Haskell (`Krivostr.Nip.Nip44`)
and TypeScript (`ui/src/nostr/nip44.ts`) implement the same ChaCha20 + HMAC +
HKDF-SHA256 construction, checked against the same published vectors — the
TypeScript tests assert the canonical payload byte for byte. `nip46Signer`
takes its transport as an injected `{encrypt, decrypt}` pair, and the picker
passes the NIP-44 adapter (`nip44Transport`), so bunker traffic rides NIP-44.

Two security fixes over the reference spec:

1. **Short-ciphertext panic fix** — validates ciphertext length before indexing
   the 2-byte length prefix (the spec reads `buffer[0..2]` after HMAC passes,
   which panics on <2 bytes).
2. **Payload-size guard** — enforces maximum payload size BEFORE base64 decoding
   (the spec decodes the full attacker-controlled payload before checking
   version/size).

**NIP-19 entities live on both sides.** Keys stay in `Key.hs` (`npub`/`nsec`)
and the UI's hand-rolled [`bech32.ts`](../ui/src/nostr/bech32.ts); the TLV
pointers are `Krivostr.Nip.Nip19` and matching `nevent`/`naddr` codecs in
`bech32.ts` (type 0 id/identifier, 1 relays, 2 author, 3 uint32 kind).
Mentions resolve them: `nevent` to its id, `naddr` to its coordinate, and
`krivostr resolve` understands both.

**NIP-21 `nostr:` URIs open in the client.** `parseNostrUri` accepts exactly
one reference and nothing else; clicks dispatch `mention-open`, and the app
opens notes and addresses in a reader overlay (one-shot fetch, newest
version for addresses) or swaps the feed to an author's notes. Opaque spans
(`nsec`, unknown hrps) stay inert — there is nothing to open.

**NIP-57 zaps** split across visibility: the kind-9734 request is signed and
sent to the LNURL callback, never published; the kind-9735 receipt is
published by the recipient's wallet and rendered as a claim (amount from the
invoice, sender when public), never as settlement proof. The UI zap dialog
discovers the address from kind-0 metadata, honors the endpoint's min/max,
and shows the invoice for the wallet to pay. Amounts decode from bolt11 on
both sides, including the uneven-division refusal.

**NIP-65 is read-only.** `Krivostr.Nip.Nip65` parses kind 10002 into
`readRelays` and `writeRelays`, and the CLI resolves read relays from stored
kind 10002s when no `--relay` is given. Nothing publishes a kind 10002, and
`writeRelays` is parsed but never consulted when publishing.

**NIP-46 reaches the browser through the picker.** `nip46Signer` takes its
transport as an injected `{encrypt, decrypt}` pair; the picker passes
`nip44Transport`, so bunker traffic rides NIP-44 v2. The method table and
request/response codecs live in `ui/src/nostr/nip46.ts`, mirroring
`Krivostr.Nip.Nip46`. The session key is a fresh one-time key identifying
the tab — the user's key never leaves the bunker.

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

**NIP-05 identifiers** resolve `alice@example.com` through the domain's
`/.well-known/nostr.json` (always HTTPS, with the `?name=` query some hosts
require). `Krivostr.Nip.Nip05` parses and compares; `krivostr verify` fetches
and checks against a `--pubkey` or the `KRIVOSTR_NSEC` key; the UI mirrors
the logic in `ui/src/nostr/nip05.ts` with a three-state badge (verified /
failed / unknown — a network error is unknown, not failed).

**NIP-10 replies** read marked `e` tags (`root` / `reply`) with the positional
order as fallback for old events. `krivostr reply` looks the parent up in the
store, resolves the thread root, and publishes a marked kind 1 both old and
new clients parse the same way. The UI groups threads and renders reply
context; the compose box carries the target.

**NIP-25 reactions** are kind 7 with `e` / `p` / `k` tags; content is `+`,
`-`, or an emoji. `krivostr react` publishes one (`--emoji`, default `+`);
the UI shows per-note like/dislike counts and one-click ♥ buttons.

**NIP-18 reposts** are kind 6 (notes) embedding the original as JSON, kind 16
for other kinds with a `k` tag, and kind-1 *quotes* citing with `q` — never
`e`, so quotes stay out of the reply thread. `krivostr repost` does both
(`--quote` for the quote form); the UI renders embedded originals.

**NIP-23 articles** are kind 30023 with a `d` slug, `title` / `summary` /
`image` / `published_at` header, and Markdown body. `krivostr publish FILE
--title …` publishes (or replaces, per slug) and prints the
`30023:pubkey:slug` address; the UI renders the header over the body.

**NIP-50 search** rides the wire `search` filter. The bridge answers it from
SQLite FTS5 (ranked by bm25, other filter clauses still applied); without an
index the same filter degrades to a substring scan rather than failing.
`feed`, `export`, and `watch` take `--search`, the API takes `?search=`, and
the UI has a search box that swaps the global subscription for a search one
(and back on clear).

**NIP-09 deletion** is a kind 5 citing `e` ids and `a` addresses, effective
only against its author's own events. `krivostr delete` refuses foreign
events, publishes, then drops its own copies; the UI hides cited targets and
renders the request as a receipt. Advisory throughout — relays may keep the
bytes.

**NIP-22 comments** thread anything but kind 1 notes: kind 1111, plaintext,
UPPERCASE root scope (`E`/`A`, `K`, `P`) and lowercase parent (`e`/`a`,
`k`, `p`). `krivostr comment` takes an id or `kind:pubkey:slug` address and
refuses kind 1 (that is NIP-10's job); the UI comments on articles from the
feed and renders comment threads.

**NIP-27 mentions** scan `nostr:` URIs out of free text: `npub` to hex
authors, `note` to ids, `nprofile` through its TLV. `nsec` parses as opaque
and is never decoded. `krivostr resolve` prints authors, relays, and stored
events; the UI renders mentions as labelled spans (click-through is NIP-21's
phase).

**NIP-36 sensitive content** is the `content-warning` tag — presence is the
signal, the reason advisory, and a reasonless tag still counts. `feed` hides
bodies behind the warning unless `--show-sensitive`; the UI blurs behind a
click that never persists.

**NIP-51 lists** are replaceable tag-sets: kind 10000 mutes `p` pubkeys,
10001 pins `e` ids, 10003 bookmarks `e`/`a`/`d`/`t`. `krivostr list
mute|pin|bookmark [--add V]... [--del V]...` edits (or shows) the latest own
list, publishes, and stores it; lists are retention-exempt. The UI subscribes
to its own kind 10000 and hides muted authors locally — no relay support
needed.

**NIP-45 COUNT** asks `["COUNT", id, filters…]` and gets
`["COUNT", id, {"count": N}]`. The bridge answers from SQLite — one indexed
`COUNT(*)` (search via an FTS subquery), tags via a bounded fetch — and never
forwards; overlapping filters union by id. `krivostr count` prints the
number; the UI `count()` backs the search result line, bridge-slot only,
because cross-relay sums would double-count.

**NIP-47 wallet connect** is client-only: no wallet service ships here. The
URI (`nostr+walletconnect://pubkey?relay=…&secret=…`) parses in core and UI;
requests (kind 23194, `encryption` + `p` tags, NIP-44 payload) and responses
(kind 23195) share codecs on both sides reusing the one NIP-44 implementation.
`krivostr wallet` (`KRIVOSTR_NWC`) does `balance`, `info`, `pay`, and
`invoice` as single-flight relay calls; the zap dialog pays through a pasted
URI that lives in dialog state and dies with the tab. NIP-04 legacy mode is
not implemented — a service speaking only it yields undecryptable payloads,
not a silent downgrade.

## Not implemented

- **NIP-02** follow lists: no parsing or rendering of kind 3. Kind 3 is stored
  and retained, nothing more.
- **NIP-11** relay information: the document is parsed and `supported_nips` is
  queryable, but nothing requests it on connect yet, so no relay's capabilities
  are discovered in practice.
