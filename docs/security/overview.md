# Security overview

This document describes krivostr's threat model, its trust boundaries, and
how key material and event data are handled. It is written for contributors
reviewing the code and for users deciding whether to trust the client with
an identity worth protecting.

The short version: the client trusts the browser, does not trust relays, and
holds a private key only when the user has explicitly chosen the local
signer. Everything else is a cache of data that is either already public or
already encrypted.

---

## What krivostr is

Three components, in the order they touch a secret:

1. **`ui/`** — a Lit-based browser client. Handles key entry, signing, event
   display, and local caching. This is where user secrets live, if anywhere.
2. **`client/`** — a Haskell bridge. A personal relay that caches events in
   SQLite and serves them to the browser over a WebSocket. It never sees a
   private key.
3. **`core/`** — a pure Haskell library. Event construction, canonical
   serialisation, Schnorr signing, filter matching. No I/O.

Relays are external and untrusted. The Nostr protocol is adversarial by
default: any relay can log everything it is sent, and any peer can publish
anything it can sign.

---

## Assets

| Asset | Where it lives | Protected by |
|---|---|---|
| Private key (`nsec`) | Browser memory, or an external signer | Non-extractable `CryptoKey`, or not held at all |
| Encrypted private key at rest | IndexedDB | PBKDF2 (600k iters) + AES-GCM-256, passphrase-derived |
| Event cache | IndexedDB (browser), SQLite (bridge) | OS disk encryption, loopback-only binding |
| Session state | Browser memory | Nothing — ephemeral by design |
| Relay credentials (NIP-42) | Browser memory | Nothing — the challenge-response is per-connection |

The private key is the only asset whose compromise is irreversible. Every
design decision below either keeps it out of the system entirely or limits
how long it is present in memory.

---

## Trust boundaries


Trusted:

- The browser's JavaScript engine and origin.
- The bridge process, but only as far as the loopback interface. A bridge
  bound to a non-loopback address is a different trust model, documented
  separately below.
- The operating system's disk encryption.

Not trusted:

- Relays. They observe every event published to them and every filter
  subscribed. They can lie about their capabilities, drop events, or serve
  fabricated ones. Signature verification is the only defence.
- Other Nostr clients.
- Browser extensions, except NIP-07 signers, which are trusted for the
  narrow purpose of signing without exposing the key.

---

## Threat model

### Adversaries we defend against

**A hostile relay.** It receives every event published, every filter
subscribed, and can correlate a public key with an IP address and a
subscription pattern. Mitigations: the outbox model (NIP-65) limits which
relays see which keys; NIP-59 gift wrap and NIP-17 DMs exist in the core so a
relay need not see who is talking to whom, but the CLI `dm` command still
sends NIP-04 kind 4; all relay traffic is `wss://`.

**An XSS on the hosted UI origin.** If an attacker injects script into the
Cloudflare Pages deployment, they can read whatever is in the page's memory.
Mitigations: the signer picker defaults to NIP-07 and NIP-46, both of which
keep the key off the origin entirely; a strict Content-Security-Policy;
no third-party scripts; no `dangerouslySetInnerHTML` equivalents on remote
data (Lit's `html` escapes by default).

**A stolen bridge database file.** The SQLite store is unencrypted. It holds
public events and ciphertexts, not plaintext or keys. The metadata — who you
follow, which relays you publish to — is the only thing worth protecting,
and OS disk encryption is the assumed control.

**A malicious dependency.** Covered by the supply-chain policy in
[`supply-chain.md`](supply-chain.md): every GitHub Action is pinned to a
full-length commit SHA, and dependency updates are reviewed rather than
auto-merged.

### Adversaries we do not defend against

**A compromised browser or OS.** If the user's machine is compromised, the
key is compromised. No client-side mitigation exists for this.

**A compromised NIP-07 extension.** Extension signers see every event before
signing. Choosing one is a trust decision that belongs to the user.

**A compromised NIP-46 bunker.** Same reasoning. The bunker holds the key;
if it is malicious, it can sign anything on the user's behalf.

**Traffic analysis by a global passive adversary.** krivostr does not use
Tor, does not use mixnets, and does not add timing noise beyond what NIP-59
specifies. An adversary who can observe network traffic to relays can
correlate a user with a set of IP addresses.

**Compromised DNS.** Relay URLs are resolved by the browser or the bridge.
There is no DNSSEC enforcement and no certificate pinning.

---

## Key handling

Three signers. Only one of them holds a key.

### Local signer

The user pastes an `nsec1...` string. On confirmation:

1. The bech32 is decoded to 32 raw bytes.
2. A PBKDF2 key is derived from a user passphrase with 600,000 iterations of
   SHA-256 and a 16-byte random salt.
3. An AES-GCM-256 `CryptoKey` is derived from that PBKDF2 key, marked
   **non-extractable**.
4. The 32-byte secret is encrypted with that key under a 12-byte random IV.
5. The ciphertext, salt, and IV are stored in IndexedDB under `keys/primary`.
6. The plaintext 32 bytes are held only in a `Uint8Array` inside the
   `localSigner` closure. They are not written to disk, not logged, and not
   sent to the bridge.

**Consequence:** after the passphrase is entered, the key lives in JS memory
for the lifetime of the tab. An XSS or a content-script-armed extension can
read it. This is inherent to local signing and is why the hosted UI defaults
to NIP-07.

**What is not done:** the key is not zeroed on tab close (JS has no
reliable mechanism for this), not moved to a Web Worker (which would not
help — the tab still owns the worker), and not put behind a second factor
(no hardware-backed option exists in a browser without WebAuthn, and WebAuthn
does not expose raw secp256k1 signing).

### NIP-07 (extension)

`window.nostr.signEvent` is called per event. The key never enters krivostr's
code. This is the recommended signer for any user with a meaningful threat
model.

### NIP-46 (bunker)

The user pastes a `bunker://` URL. Requests are encrypted with NIP-44 v2
(ChaCha20 + HMAC-SHA256, authenticated) and sent over the bunker's relay.
The bunker holds the key and returns signatures. The signing key never
enters the browser; only a fresh one-time session key identifying this tab
to the bunker lives in page memory.

---

## Data at rest

### Browser (IndexedDB)

Database `krivostr`, object store `events`, indexes on `created_at` and
`kind`. Contents:

- Public events (kind 1, 6, 7, ...) for 30 days.
- Persistent kinds (`0`, `3`, `4`, `1059`, `10002`) forever.
- Encrypted private key material under `keys/primary` (separate store).

DM ciphertext (kind 4 and 1059) is stored as received. It is encrypted on
the wire, so a database dump does not reveal plaintext. The key to decrypt
it is not in the same database unless the user has chosen the local signer
with the same origin — in which case the encrypted key is there, and the
passphrase is required to use it.

### Bridge (SQLite)

Path `.krivostr/events.db` by default, `/data/events.db` in the Docker
image. Same retention policy as the browser, enforced by `evictExpired`
in `Store.hs`. Also unencrypted.

**What is not stored anywhere:** passphrases, plaintext DMs, relay
credentials, or session tokens. The bridge does not hold a private key.

---

## Data in transit

| Path | Protocol | Notes |
|---|---|---|
| Browser → relay | `wss://` | Direct. TLS required. |
| Browser → bridge | `ws://` on loopback | Plaintext on loopback only. If the bridge is remote, `wss://` behind a TLS reverse proxy. |
| Bridge → relay | `wss://` | Direct. TLS required. |

`ws://` is accepted only for `localhost` and `127.0.0.1`. The bridge refuses
to bind to a non-loopback address unless `KRIVOSTR_BIND` is set explicitly,
and logs a warning when it is.

### Deployment footgun

`docker run -p 8081:8081 krivostr` publishes to the host's default interface,
which is reachable from the LAN. The compose file in `docker/` uses
`127.0.0.1:8081:8081` for this reason. If you run the container without
compose, use `-p 127.0.0.1:8081:8081` unless you have a reverse proxy in
front of it and understand the consequences.

A bridge exposed to the network with no authentication lets anyone on that
network read the event cache, subscribe to any filter, and (if the user has
not enabled a signer at the bridge — they cannot, in the current
architecture) do nothing on the user's behalf. The cache is the exposure.
See [`../relays.md`](../relays.md) for the deployment patterns that make
this safe.

---

## What is not protected

An honest accounting, because a security document that claims to cover
everything is a security document nobody should trust.

- **The user's own machine.** Compromised OS, compromised browser,
  compromised extension, and physical access are all out of scope.
- **Network metadata.** Which relays are contacted, when, and from which IP
  is visible to anyone between the user and the relay. NIP-59 hides the
  social graph from relays, not from the network.
- **Relay-side correlation.** A relay that sees a NIP-65 list and a
  subscription to a set of authors can correlate them. NIP-42 does not fix
  this; it authenticates the client, not the request.
- **Content authenticity beyond signatures.** krivostr verifies that an
  event was signed by the key it claims. It does not verify that the key
  belongs to the human the display name suggests. NIP-05 is a weak signal
  and is displayed as such.
- **Anything written by a future version of this client.** Security
  properties are per-release. A finding against one version does not
  automatically apply to another.

---

## Reporting

See [`../../.github/SECURITY.md`](../../.github/SECURITY.md).
