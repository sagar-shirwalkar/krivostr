# Security

Key material is the most sensitive thing in the system, and what follows is an
inventory of what is actually true — including the parts that are not
implemented, which is where the previous version of this document was
optimistic.

## The two real gaps (now fixed)

**Ingest did not verify signatures.** `Krivostr.Schnorr.verifyEvent` existed but
was not called on the way in. The bridge now verifies signatures on all events
received from clients (via WebSocket) and from upstream relays before storing or
forwarding them. The CLI's `feed --ingest` path also verifies signatures before
storing. A malicious relay can no longer inject events with invalid signatures.

**`krivostr serve` bound every interface.** [`Bridge.hs`](../client/src/Krivostr/Bridge.hs)
called `setPort` with no `setHost`, so Warp's default applied and the bridge
listened on all interfaces. Fixed by adding a `--host` option (defaulting to
`127.0.0.1`, env `KRIVOSTR_BRIDGE_HOST`) to the `serve` command, mirroring the
API's `--host` option.

The JSON API never had this problem: `Cli/Api.hs` calls `setHost` from
`apiHost`, which defaults to `127.0.0.1`.

## Threat model

We assume:

- **The browser origin is hostile.** Any script execution on the origin is
  total compromise of an in-memory key. Mitigations: no `unsafeHTML` on remote
  data anywhere in `ui/src`, and a CSP on the Cloudflare Pages deployment.
- **Relays are hostile.** Any relay can log everything you publish and
  subscribe to, and can lie about who sent what, because of the signature gap
  above. There is no mitigation for the second half: NIP-59 gift wrap is not
  implemented, so a relay can correlate your reads with your writes.
- **The bridge is trusted as far as the machine it runs on.** It holds event
  metadata, never keys.
- **The local disk is partially trusted.** No key is ever written to it. That
  is not a design achievement so much as a consequence of keys living in memory
  only.

We do not assume the RNG is sound: `generatePrivateKey` reads
`/dev/urandom` directly, and there is no fallback source.

## Key handling

### Local signer

The `nsec1…` is bech32-decoded in the picker, converted to hex, and passed to
`localSigner`, which holds it in a closure for the lifetime of the tab. It is
never persisted, never sent to the bridge, and never logged.

There is **no passphrase, no key wrapping, and no unlock step.** No PBKDF2, no
AES-GCM, no `keys/primary` record — none of that exists in the codebase, though
a previous version of this document described it in detail. The consequence is
simpler than a wrapping design would be, and worse in one respect: the key is
readable by anything running on the origin for as long as the tab is open.

Use NIP-07, or a bunker, if that matters.

### NIP-07

krivostr never touches the key. `window.nostr.signEvent` is called per event
and the extension holds the private half. This is the recommended path.

### NIP-46

The bunker holds the key and returns signatures over NIP-04-encrypted kind
24133 DMs. Note that the UI cannot reach this path today: the signer picker
does not construct `nip46Signer`. See [signers.md](signers.md).

## Cached events

The IndexedDB cache and the SQLite store both hold events unencrypted at rest.
That matches Nostr's design — events are public — with one caveat: a kind 4 DM
is stored exactly as it arrived, encrypted, and **krivostr cannot decrypt it**,
so it is opaque rather than protected. The cache is readable by anything with
access to the origin's storage.

Neither store holds a key, a passphrase, or a relay credential.

## Network

Relay connections are `wss://` as configured. The UI derives the bridge's
scheme from the page's own protocol in
[`bridge.ts`](../ui/src/nostr/bridge.ts) — an `https:` page connects over
`wss:`, an `http:` page over `ws:`. There is no check restricting `ws://` to
localhost; it follows from serving the page over plain HTTP, so do not serve
krivostr that way on a shared network.

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