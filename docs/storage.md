# Storage

Two independent stores, one per side of the bridge, with the same retention
rule. Nothing synchronizes them.

## Bridge (SQLite)

The store is [`client/src/Krivostr/Store.hs`](../client/src/Krivostr/Store.hs).
The path comes from `KRIVOSTR_DB` and defaults to `.krivostr/events.db`.

| Object | Definition |
|---|---|
| `events` | `id` primary key, plus `pubkey`, `created_at`, `kind`, `tags`, `content`, `sig`. |
| `events_fts` | FTS5 virtual table over `(event_id, body)`, where `body` is `content`. |
| `idx_pubkey` | On `events(pubkey)`. |
| `idx_created_at` | On `events(created_at)`. |
| `idx_kind` | On `events(kind)`. |
| `events_fts_ai` | Trigger keeping `events_fts` in step on insert. |
| `events_fts_ad` | Trigger keeping `events_fts` in step on delete. |

Full-text search is implemented: `krivostr search <query>` and the bridge's
`/search` endpoint match `events_fts` and rank with `bm25`, falling back to a
lexical query when FTS5 is missing at build time. `krivostr reindex` rebuilds
the index from `events`.

**NIP-40 expiration:** Events with an `expiration` tag are purged deterministically
by the retention job. The `expiration` tag (NIP-40) carries a unix timestamp;
events past that timestamp are purged on the next retention run.

**Both `INSERT` and retention are per-id.** There is no replaceable-event logic:
a newer kind 0 or kind 3 from the same author does not displace the older one,
and neither does a read pick "the newest per pubkey". The store keeps every
event it is given, keyed by id. Deduplication happens only in the sense that
re-delivering the same id replaces the same row.

**NIP-59 gift wrap** events (kind 1059) are stored with the same retention
policy. The outer wrapper is kind 1059; the inner rumor (kind 14) is encrypted
with NIP-44 and opaque to the store.

## Browser (IndexedDB)

[`ui/src/nostr/cache.ts`](../ui/src/nostr/cache.ts). Database `krivostr`,
version 1, object store `events` keyed on `id`, with **one** index:
`created_at`, used to read newest-first.

Retention matches the bridge: 30 days for everything except the persistent
kinds, which are `0`, `3`, `4`, `1059` and `10002`. The Haskell side spells the
same set in `persistentKinds` and the UI in `PERSISTENT_KINDS`; changing one
means changing both.

`evictExpired` exists and is unit-tested, but **nothing in the app calls it** —
no timer, no startup sweep. The browser cache grows until the user clears it.
Wiring it into an hourly timer is a one-line change if you want the documented
behaviour.

**NIP-49 `ncryptsec`** — Private keys are stored encrypted in IndexedDB as
`ncryptsec1...` bech32 strings (NIP-49: scrypt + XChaCha20-Poly1305). The
passphrase is never stored; only the derived key is used to decrypt on unlock.
The heap-allocated key buffer is zeroed on drop.

Kind 4 events are stored **encrypted**, because that is how they arrive over
the wire — the relay or sender already encrypted them. krivostr does not
decrypt them, and the cache is not encrypted at rest. Events on Nostr are
public by design; a cached DM is as readable as the file it sits in.

## What is not stored

- **Private keys.** No store holds a key. The local signer keeps the secret in
  a JavaScript closure for the lifetime of the tab, and never writes it. See
  [signers.md](signers.md).
- Passphrases: never stored; only the derived key is used to decrypt on unlock.
- Relay connection state, in either store.

## Cache invalidation

There is none, in either direction.

The bridge stores whatever it receives and answers `REQ` from its own store; the
UI caches whatever it receives. Neither store invalidates the other, and
neither coalesces replaceable events. Both are keyed by event id, so the same
event arriving twice is idempotent and a *changed* event (new `created_at`,
same kind and author) is simply a second row.

The practical consequence: after you publish a new profile, both stores hold the
old and new metadata, and nothing in krivostr will pick between them.
Deduplicating replaceable events is not implemented.