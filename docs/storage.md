# Storage

## Browser (IndexedDB)

Database: `krivostr`, version 1, object store `events` (keyPath `id`).
Indexes: `created_at`, `kind`.

Retention:

- Public events (anything not in the persistent set): 30 days.
- Persistent kinds (`0`, `3`, `4`, `1059`, `10002`): forever.

Eviction is scheduled from the UI on a one-hour timer and runs on demand
when the app starts.

## Bridge (SQLite)

Database: `.krivostr/events.db`, table `events`.

Same retention policy as the browser cache. Eviction runs hourly from a
background thread in the bridge.

Indexes: `pubkey`, `created_at`, `kind`. Full-text search is not yet
implemented; NIP-50 support would add it.

## What is not stored

- Private keys (only their wrapped ciphertext, in the browser).
- Passphrases.
- Decrypted DM plaintext (beyond the lifetime of the tab).
- Relay connection state.

## Cache invalidation

The browser cache and the bridge cache are independent. When the bridge
detects an event it has not seen, it stores and forwards. The browser
stores on receipt. Neither invalidates the other. Replaceable events (kind
0, 3, 10002, etc.) overwrite by pubkey in the browser and by id in the
bridge (the newest by `created_at` wins on read).
