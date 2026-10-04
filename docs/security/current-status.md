# Security

Key material is the most sensitive thing in the system, and what follows is an
inventory of what is actually true — including the parts that are not
implemented, which is where the previous version of this document was
optimistic.

## The two real gaps (now fixed)

**Ingest does not verify signatures.** `Krivostr.Schnorr.verifyEvent` exists and
is tested, but nothing calls it on the way in. The bridge stores events on the
`pubkey` they carry; the UI's `parseEvent` checks that fields are present and
correctly typed, not that `id` hashes the content or that `sig` verifies. A
malicious relay can serve events attributed to anyone. Nothing downstream
notices.

**`krivostr serve` binds every interface.** [`Bridge.hs`](../client/src/Krivostr/Bridge.hs)
calls `setPort` with no `setHost`, so Warp's default applies and the bridge
listens on all interfaces, not just loopback — even though the startup log
prints `listening on :8081` with no host. Anything on the local network can
connect, read the store, and publish events as you.

This is worth fixing, and it is a small fix: mirror the API's `--host` option
(defaulting to `127.0.0.1`) in `serveP`, and set `setHost` in `Bridge.hs`.

The JSON API does not have this problem: `Cli/Api.hs` calls `setHost` from
`apiHost`, which defaults to `127.0.0.1`.

## NIP-44 v2 security fixes

The NIP-44 v2 implementation includes two critical security fixes over the
reference specification:

1. **Short-ciphertext panic fix** — The reference spec reads a 2-byte length
   prefix via `buffer[0..2]` after HMAC verification. On ciphertexts shorter
   than 2 bytes, this panics. Our implementation validates ciphertext length
   before any array indexing (both Haskell and TypeScript).

2. **Payload-size guard** — The reference spec base64-decodes the full
   attacker-controlled payload before checking version or size. Our
   implementation enforces a maximum base64 payload size BEFORE decoding
   (~88KB for 64KB plaintext + overhead), preventing resource exhaustion.

Both the Haskell (`Krivostr.Nip.Nip44`) and TypeScript (`ui/src/nostr/nip44.ts`)
implementations include these fixes.

## Threat model

We assume:

- **The browser origin is hostile.** Any script execution on the origin is
  total compromise of the in-memory key. Mitigations: no `unsafeHTML` on remote
  data anywhere in `ui/src`, and a CSP on the Cloudflare Pages deployment.
- **Relays are hostile.** Any relay can log everything you publish and
  subscribe to, and can lie about who sent what, because of the signature gap
  above. There is no mitigation for the second half: NIP-59 gift wrap is
  implemented but relay-side enforcement varies.
- **The bridge is trusted as far as the machine it runs on.** It holds event
  metadata, never keys.
- **The local disk is partially trusted.** We assume it can be read by another
  process on the same machine. Private keys are encrypted at rest via NIP-49
  `ncryptsec` (scrypt + XChaCha20-Poly1305).

We do **not** assume:

- That the browser's random number generator is broken. If `crypto.getRandomValues`
  is compromised, all bets are off.
- That the user has chosen a strong passphrase. We rate-limit unlock attempts
  in the UI, but a weak passphrase is a weak passphrase.

## Key handling

### Local signer (NIP-49 `ncryptsec`)

The `nsec1…` is bech32-decoded, then encrypted with NIP-49 (scrypt +
XChaCha20-Poly1305) and stored in IndexedDB as `ncryptsec1...`. On unlock,
the passphrase derives the key via scrypt, decrypts the private key, and holds
it in a closure for the lifetime of the tab.

There is **no passphrase, no key wrapping, and no unlock step** for the legacy
local signer (which stores the raw key in memory). The new NIP-49 flow is the
recommended path.

Use NIP-07, or a bunker, if memory exposure matters.

### NIP-07

krivostr never touches the key. `window.nostr.signEvent` is called per event
and the extension holds the private half. This is the recommended path.

### NIP-46

The bunker holds the key and returns signatures over NIP-44-encrypted kind
24133 DMs. Note that the UI cannot reach this path today: the signer picker
does not construct `nip46Signer`. See [signers.md](signers.md).

## Cached events

The IndexedDB cache and the SQLite store both hold events unencrypted at rest.
That matches Nostr's design — events are public — with one caveat: a kind 4 DM
is stored exactly as it arrived, encrypted, and **krivostr cannot decrypt it**,
so it is opaque rather than protected. The cache is readable by anything with
access to the origin's storage.

Neither store holds a key, a passphrase, or a relay credential.

**NIP-49 `ncryptsec`** encrypts private keys at rest with scrypt +
XChaCha20-Poly1305. The passphrase is never stored; only the derived key is
used to decrypt on unlock. The spec recommends zeroing key and password memory
after use — we zero the heap-allocated key buffer on drop.

## Network

Relay connections are `wss://` as configured. The UI derives the bridge's
scheme from the page's own protocol in
[`bridge.ts`](../ui/src/nostr/bridge.ts) — an `https:` page connects over
`wss:`, an `http:` page over `ws:`. There is no check restricting `ws://` to
localhost; it follows from serving the page over plain HTTP, so do not serve
krivostr that way on a shared network.

**NIP-42 authentication** uses ephemeral kind 22242 events with a relay-supplied
challenge. The bridge and CLI implement a single-challenge queue (a new
challenge invalidates the previous one) to prevent challenge-queue exhaustion.

**NIP-42 on reads** — a relay that supports NIP-42 but never enforces it on
reads offers no read privacy; a passive observer can harvest every encrypted
message and social graph. Clients MUST verify that relays enforce NIP-42 on
reads for NIP-59 recipient metadata to be actually private.

## Headers

The Content-Security-Policy lives in
[`ui/public/_headers`](../ui/public/_headers) and applies to the **Cloudflare
Pages deployment only**. `krivostr serve` serves the same `dist/` over plain
Warp and never reads that file, so a self-hosted bridge sends **no CSP, no
`X-Frame-Options`, and no `X-Content-Type-Options`**.

The policy is:

```text
default-src 'none'; script-src 'self';
style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;
font-src 'self' https://fonts.gstatic.com data:;
img-src 'self' data:; connect-src 'self' wss:;
base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'
```

`'unsafe-inline'` for styles is required by Lit's shadow DOM.
`connect-src` needs `wss:` rather than `'self'` because `'self'` does not
resolve to WebSocket schemes in every browser, and the bridge is often on a
different origin. Serving those same headers from `krivostr serve` is a small
addition — a Warp middleware over `setBeforeMainLoop` — and worth doing if you
self-host.

## What we don't do

- No telemetry, no analytics, no beacon. The UI makes no `fetch`, `XHR` or
  `sendBeacon` call to any origin.
- No phone home. The only outbound connections are the relays you configure and
  the bridge or bunker you name.
- No remote script imports; Vite emits local bundles.
- No `unsafeHTML` on remote data.

## Reporting

No security contact is configured. Before publishing, put a real address here —
a reachable one, in `README.md` and this file — rather than a placeholder like
`security@example.invalid`, which is worse than nothing because it looks
handled.