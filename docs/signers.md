# Signers

krivostr supports three signer backends. All three implement the `Signer`
interface in [`ui/src/nostr/signer.ts`](../ui/src/nostr/signer.ts).

## NIP-49 `ncryptsec` (local encrypted key) — **recommended**

The `ncryptsec1...` bech32 string is decoded, decrypted with the passphrase
via scrypt + XChaCha20-Poly1305 (NIP-49), and the raw private key is held in
a closure for the lifetime of the tab.

| | |
|---|---|
| **Pros** | Key encrypted at rest (scrypt + XChaCha20-Poly1305); no extension needed; works everywhere. |
| **Cons** | Decrypted key lives in JS memory for the tab lifetime; passphrase required. |

**Passphrase handling:** The passphrase is never stored. It derives the key via
scrypt on unlock, decrypts the private key, and holds it in a closure. The
heap-allocated key buffer is zeroed on drop. The spec recommends zeroing
password and key memory before freeing — we zero the heap buffer on drop.

## Local `nsec` (legacy, not recommended)

The user pastes an `nsec1...` string. We decode it to 32 bytes, convert to hex,
and hand it to `localSigner`, which keeps it in a closure for the lifetime of
the tab.

**The key is never written to disk.** There is no AES-GCM wrapping, no PBKDF2,
no passphrase prompt, and no `keys/primary` record in IndexedDB — none of that
code exists anywhere in the UI.

| | |
|---|---|
| **Pros** | No extension, no bunker, works anywhere. |
| **Cons** | Key in page memory; no at-rest protection of any kind. |

## NIP-07 (browser extension)

`nip07Signer()` calls `window.nostr.getPublicKey()` and
`window.nostr.signEvent()`. krivostr never sees the private key. Availability
is checked with `isNip07Available()` before the option is offered.

| | |
|---|---|
| **Pros** | Key never enters the page. Recommended production path. |
| **Cons** | Requires an extension the user trusts. |

Supported extensions: Alby, nos2x, Nostore, Flamingo.

## NIP-46 (remote bunker)

Implemented in `nip46Signer` and covered by tests, but **not reachable from the
UI**. Two things stand in the way:

1. The picker does not import it.
2. It takes its NIP-04 implementation as an **injected parameter**
   (`{encrypt, decrypt}`) and imports no crypto for it. The test supplies a
   fake. A real caller must pass a real NIP-04 implementation.

Given a bunker, it parses `bunker://<remote-pubkey>?relay=…&secret=…`,
subscribes to kind 24133 events from the remote pubkey, and speaks
`get_public_key` and `sign_event`. Requests are signed with the local key so
the bunker can authenticate the caller. Transport is NIP-04 (NIP-44 planned).

| | |
|---|---|
| **Pros** | Key is on a separate device. Best for high-value keys. |
| **Cons** | Needs a bunker service (e.g., nsec.app); not wired in the picker yet. |

## Generating a key

`krivostr keygen` prints an `nsec`/`npub` pair.
`Krivostr.Key.generatePrivateKey` reads 32 bytes from **`/dev/urandom`**,
which is POSIX-only: `keygen` will not work on Windows, and there is no
fallback entropy source. On a malformed draw it retries.

## Choosing a signer

| Use case | Use |
|---|---|
| Daily browsing | NIP-07 (Alby) |
| No extension available | NIP-49 `ncryptsec` (with strong passphrase) |
| High-value key | NIP-46 bunker (after wiring up the picker) |
| Development | Local `nsec` (throwaway key only) |

Note what is *not* on this list: "local nsec with a strong passphrase" (legacy
local signer has no passphrase — use NIP-49 instead).