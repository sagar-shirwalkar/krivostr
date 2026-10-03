# Signers

krivostr supports three signer backends. All three implement the `Signer`
interface in `ui/src/nostr/signer.ts`.

## Local nsec

The user pastes an `nsec1...` string. We decode it, wrap it in a
non-extractable `CryptoKey` with AES-GCM-256 keyed by a PBKDF2-derived key
from a passphrase, and store the ciphertext in IndexedDB.

**Pros:** works everywhere, no extension needed.
**Cons:** the key lives in JS memory while the tab is open. See
[security.md](security.md).

## NIP-07 (browser extension)

We call `window.nostr.getPublicKey()` and `window.nostr.signEvent(event)`.
The extension holds the key.

Supported extensions: Alby, nos2x, Nostore, Flamingo.

**Pros:** key never enters our page. Works across all sites.
**Cons:** requires an extension.

## NIP-46 (remote bunker)

The user pastes a `bunker://<remote-pubkey>?relay=wss://...&secret=...` URL.
We connect to the relay, subscribe to kind 24133 events tagged with our
pubkey, and send encrypted requests.

Requests:

- `get_public_key` → returns hex pubkey
- `sign_event` → returns JSON-serialized signed event

Transport is NIP-04 encrypted DMs. NIP-44 is planned.

**Pros:** key is on a separate device. Best for high-value keys.
**Cons:** needs a bunker service (e.g., nsec.app).

## Choosing a signer

| Use case | Recommended signer |
|---|---|
| Casual browser use | NIP-07 (Alby) |
| Mobile, no extension | Local nsec (with strong passphrase) |
| High-value key | NIP-46 (bunker) |
| Development | Local nsec (test key only) |
