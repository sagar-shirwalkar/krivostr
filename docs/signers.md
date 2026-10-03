# Signers

The `Signer` interface lives in
[`ui/src/nostr/signer.ts`](../ui/src/nostr/signer.ts): a public key, and a way
to sign an unsigned event.

Three implementations exist in that file. **Two are reachable from the UI.**

`nostr-signer-picker.ts` imports `localSigner`, `nip07Signer` and
`isNip07Available` — and nothing else. `nip46Signer` is implemented and
unit-tested but never constructed by the app.

## Local nsec

`localSigner(seckeyHex)` takes a **32-byte hex** secret key and returns a signer
that closes over it.

What the picker does with an `nsec1…`:

1. Bech32-decodes it to 32 bytes.
2. Converts to hex.
3. Hands the hex to `localSigner`, which keeps it in a closure for the lifetime
   of the tab.

**The key is never written to disk.** There is no AES-GCM wrapping, no PBKDF2,
no passphrase prompt, and no `keys/primary` record in IndexedDB — none of that
code exists anywhere in the UI. The earlier version of this document described
all of it; none of it was real.

That makes the threat model simple and unforgiving: the secret is in JavaScript
memory from sign-in until the tab closes or reloads. Anything that can run
script on the origin can read it. NIP-07 removes that exposure by keeping the
key out of the page entirely.

| | |
|---|---|
| **Pros** | No extension, no bunker, works anywhere. |
| **Cons** | The key is in page memory; no at-rest protection of any kind. |

`localSigner` does not verify that the secret is in range before use, and does
not check the key's public half against anything. A malformed paste fails at
sign time with an error from `@noble/curves`, not at entry.

## NIP-07 (browser extension)

`nip07Signer()` calls `window.nostr.getPublicKey()` and
`window.nostr.signEvent()`. krivostr never sees the private key. Availability is
checked with `isNip07Available()` before the option is offered.

| | |
|---|---|
| **Pros** | The key never enters the page. The recommended path. |
| **Cons** | Requires an extension the user trusts. |

## NIP-46 (remote bunker)

Implemented in `nip46Signer` and covered by tests, but **not reachable from the
UI**. Two things stand in the way:

1. The picker does not import it.
2. It takes its NIP-04 implementation as an **injected parameter**
   (`{encrypt, decrypt}`) and imports no crypto for it. The test supplies a
   fake. A real caller must pass a real NIP-04 implementation.

Given a bunker, it parses `bunker://<remote-pubkey>?relay=…&secret=…`,
subscribes to kind 24133 events from the remote pubkey, and speaks
`get_public_key` and `sign_event`. Requests are signed with the local key so the
bunker can authenticate the caller. Transport is NIP-04.

## Generating a key

`krivostr keygen` prints an `nsec`/`npub` pair.
`Krivostr.Key.generatePrivateKey` reads 32 bytes from **`/dev/urandom`**, which
is POSIX-only: `keygen` will not work on Windows, and there is no fallback
entropy source. On a malformed draw it retries.

## Choosing a signer

| Use case | Use |
|---|---|
| Daily browsing | NIP-07, if you have an extension. |
| No extension available | Local nsec, accepting the memory exposure. |
| Key you care about | A NIP-46 bunker — after wiring up the picker. |
| Development | Local nsec with a throwaway key. |

Note what is *not* on this list: "local nsec with a strong passphrase." There is
no passphrase.