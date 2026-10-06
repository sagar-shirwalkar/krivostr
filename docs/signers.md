# Signers

krivostr supports three signer backends. All three implement the `Signer`
interface in [`ui/src/nostr/signer.ts`](../ui/src/nostr/signer.ts).

## NIP-49 `ncryptsec` (local encrypted key) — **recommended**

NIP-49 lives in the Haskell core (`Krivostr.Nip.Nip49`, covered by tests
against the spec's published vector) and in `ui/src/nostr/nip49.ts` (same
KDF parameters, same 91-byte payload layout, decrypting the same spec
vector): the `ncryptsec1...` bech32 string is decoded and decrypted with
the passphrase via scrypt + XChaCha20-Poly1305. The signer picker does not
use it yet — the UI's local signer still holds a raw pasted key in a
closure — so encrypted-at-rest keys are a CLI-side reality and a UI-side
module awaiting its unlock flow.

| | |
|---|---|
| **Pros** | Key encrypted at rest (scrypt + XChaCha20-Poly1305); no extension needed; works everywhere. |
| **Cons** | Decrypted key lives in JS memory for the tab lifetime; passphrase required. |

**Passphrase handling (Haskell):** The passphrase is never stored. It derives
the key via scrypt on unlock and decrypts the private key. The spec recommends
zeroing password and key memory before freeing — the Haskell side zeroes the
heap buffer on drop.

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

The picker gates this option behind an explicit risk acknowledgment: the first
continue with a key pasted shows what pasting means (decrypted into page
memory, wrong place for a main identity — use the bunker or run the UI
locally) and only proceeds on "I understand". The acknowledgment is
session-only; a fresh picker asks again.

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

Implemented in `nip46Signer`, reachable from the signer picker, and covered
by tests. It takes its transport as an **injected parameter**
(`{encrypt, decrypt}`); the picker passes `nip44Transport` from
`ui/src/nostr/nip46.ts`, so the wire transport is NIP-44 v2 — the same
conversation most bunkers have moved to. The method table and
request/response codecs live in the same module, mirroring
`Krivostr.Nip.Nip46`.

Given a bunker, it parses `bunker://<remote-pubkey>?relay=…&secret=…`,
subscribes to kind 24133 events from the remote pubkey, and speaks
`get_public_key` and `sign_event`. Requests are signed with a fresh one-time
session key — not the user's key, which never leaves the bunker — so the
bunker can authenticate the caller.

The Haskell core mirrors the same codecs in `Krivostr.Nip.Nip46`, and the
TypeScript side calls them through `ui/src/nostr/nip46.ts`, so the two stay
interoperable by construction. In the picker, the bunker option carries a
tooltip naming where the URL comes from (Amber, nsec.app, a hardware wallet
interface), and the picker heading nudges main identities toward the bunker.

| | |
|---|---|
| **Pros** | Key is on a separate device. Best for high-value keys. |
| **Cons** | Needs a bunker service (e.g., nsec.app); the session key lives in page memory. |

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
| High-value key | NIP-46 bunker |
| Development | Local `nsec` (throwaway key only) |

Note what is *not* on this list: "local nsec with a strong passphrase" (legacy
local signer has no passphrase — use NIP-49 instead).
