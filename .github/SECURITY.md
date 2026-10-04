# Security policy

## Reporting a vulnerability

Use [GitHub's private vulnerability reporting][gh-pvr] for this repository.
It creates a private advisory visible only to you and the maintainer, and
keeps the discussion in one place.

If you cannot use GitHub's reporting flow, email
`security@example.invalid` with `krivostr` in the subject.

**Do not open a public issue for a security problem.**

[gh-pvr]: https://github.com/yourhandle/krivostr/security/advisories/new

## What to expect

- **Acknowledgement** within 7 days.
- **Initial assessment** within 30 days: whether the report is accepted,
  what the impact is, and a rough severity.
- **A fix or a decision not to fix** within 90 days for accepted reports.

This is a small project maintained in spare time. The timings above are
what can be met reliably, not what would be ideal. If a report is
time-sensitive — an actively exploited vulnerability, a live key
compromise — say so in the report and it will be handled first.

## What is in scope

The krivostr client, bridge, and core library:

- **Key handling.** The local signer's PBKDF2 + AES-GCM wrapping, the
  non-extractability of the derived `CryptoKey`, the failure modes of
  NIP-07 and NIP-46 signers.
- **Cryptographic implementation.** The Schnorr signing and verification
  in `core/`, the bech32 encoding in the UI, the canonical serialisation
  used for event IDs.
- **The bridge.** The SQLite store, the WebSocket endpoint, the HTTP
  static server, the binding defaults.
- **The UI.** XSS surface, the Content-Security-Policy, IndexedDB access
  patterns, the signer picker.
- **The build and release pipeline.** Workflow permissions, artifact
  integrity, the SHA pinning policy.

## What is not in scope

- **The Nostr protocol itself.** NIP-level issues belong in the
  [NIPs repository][nips].
- **Third-party relays.** Report problems with `relay.damus.io`,
  `nos.lol`, or any other relay to its operator.
- **Browser extension signers.** Alby, nos2x, and similar are separate
  projects. Report to them.
- **NIP-46 bunker services.** nsec.app and other bunkers are separate
  projects. Report to them.
- **Upstream dependencies.** Report to the maintainers of the affected
  package. Tell us as well so the pin can move, but the fix belongs
  upstream.
- **The hosted demo UI.** If you find a vulnerability in the Cloudflare
  Pages deployment that is not also present in the source, report it —
  but a general XSS on a static origin is not a finding against krivostr
  unless the CSP failed or the source is also affected.

## Please do not

- **Send a private key.** If a report involves `nsec`, `ncryptsec`, or
  any other key material, describe the vulnerability without including
  a real key. Generate a test key and share that if a reproduction is
  needed.
- **Test against relays or bunkers you do not control.** The scope above
  is the krivostr codebase, not the network it talks to.
- **Run automated scanners against any hosted instance** without prior
  arrangement. A local instance you started yourself is fine.

## No bug bounty

There is no financial reward for reports. Credit will be given in the
advisory and in release notes unless you ask not to be named.

## Disclosure

Fixes are published as a new release, with the advisory describing the
vulnerability and its impact. The advisory is published at the same time
as the fix, not before. If a fix requires coordination with a relay
operator, an extension maintainer, or another project, the timeline is
extended and the reporter is kept informed.

[nips]: https://github.com/nostr-protocol/nips
