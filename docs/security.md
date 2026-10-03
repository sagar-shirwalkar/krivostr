# Security

krivostr treats key material as the single most sensitive thing in the system.
This document describes what we do, what we don't do, and what's on the
roadmap.

## Threat model

We assume:

- The browser is hostile. Any XSS on the origin is total compromise of the
  in-memory key. We mitigate by minimizing attack surface, CSP, and never
  rendering user content as HTML.
- The relays are hostile. Any relay can log every event you publish or
  subscribe to. We mitigate by supporting the outbox model (NIP-65) and
  gift-wrapping (NIP-59) so that the relay cannot correlate reader and
  writer.
- The bridge is trusted only as far as it runs on the same machine as the
  browser. It stores event metadata, not keys.
- The user's disk is partially trusted. We assume it can be read by another
  process on the same machine. We never store keys unencrypted at rest.

We do **not** assume:

- That the browser's random number generator is broken. If `crypto.getRandomValues`
  is compromised, all bets are off.
- That the user has chosen a strong passphrase. We rate-limit unlock attempts
  in the UI, but a weak passphrase is a weak passphrase.

## Key storage

### Local signer

The `nsec` is:

1. Received from the user in the signer picker as `nsec1...` bech32.
2. Decoded to 32 raw bytes.
3. **Immediately wrapped** in a non-extractable `CryptoKey`
4.  The ciphertext, salt, and IV are stored in IndexedDB under `keys/primary`.
5. The plaintext 32 bytes are held only in a `Uint8Array` inside the
`localSigner` closure. They are never written to disk, never sent to
the bridge, never logged.

The consequence is important: **after the passphrase is entered, the key
lives in JS memory for the lifetime of the tab**. An XSS or a browser
extension with content-script access can read it. This is inherent to
NIP-07-less local signing. To mitigate, we recommend NIP-07 (extension) or
NIP-46 (bunker) for users with a meaningful threat model.

### NIP-07

We do not touch the key at all. `window.nostr.signEvent` is called per event.
The extension holds the key. This is the recommended production path.

### NIP-46

The bunker holds the key. We send an encrypted request, the bunker returns
a signature. The signing key never enters the browser. NIP-46 currently uses
NIP-04 for transport because that is what bunkers speak in practice; NIP-44
is a drop-in swap at the `nip04` boundary in `signer.ts`.

### Cache

The IndexedDB cache stores:

- Public events (kind 1, 6, 7, ...) for 30 days.
- Persistent kinds (0, 3, 4, 1059, 10002) forever.
- Nothing else.

The cache is not encrypted. Events on Nostr are public by design, with two
exceptions:

- Kind 4 (NIP-04 encrypted DM) is stored encrypted on the wire and in the
    cache. Reading it requires the recipient's private key.
- Kind 1059 (NIP-59 gift wrap) is stored encrypted, with the inner event
    sealed inside.

We do not cache the private key. We do not cache the passphrase. We do not
cache the decrypted plaintext of DMs beyond the lifetime of the tab.

### Network

All relay connections use `wss:// ` (TLS). `ws:// ` is accepted only for
`localhost` and `127.0.0.1`, and only when the app is served from `localhost`.

The bridge listens on `127.0.0.1 ` only, never `0.0.0.0`, by default. The
Dockerfile binds `0.0.0.0 ` inside the container, which is intended to be
fronted by a reverse proxy.

### What we don't do

- We do not ship telemetry.
- We do not phone home to any krivostr server.
- We do not store or transmit `nsec` beyond the local encryption boundary.
- We do not render user content as HTML. Lit's `html` template escapes by
  default; we never use `unsafeHTML` on remote data.
- We do not import remote scripts. CSP is strict.

### CSP

The production HTML header sets:

```text
Content-Security-Policy:
  default-src 'self';
  script-src 'self';
  style-src 'self' 'unsafe-inline';
  img-src 'self' data:;
  connect-src 'self' wss:;
  font-src 'self' https://fonts.gstatic.com;
  object-src 'none';
  base-uri 'none';
  frame-ancestors 'none';
```

The `unsafe-inline` for styles is required by Lit's shadow DOM. If you
disable it, use adopted stylesheets.

### Reporting

Report security issues to `security@example.invalid`.
