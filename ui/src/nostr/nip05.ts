/**
 * NIP-05 DNS identifiers: human names for public keys.
 *
 * `alice@example.com` resolves through the JSON document the domain serves
 * at `https://example.com/.well-known/nostr.json?name=alice`, which maps
 * names to pubkeys. Verification is comparing the claimed pubkey against the
 * mapped one — the whole trust decision is `verifyName`, and everything else
 * here is how to get its inputs.
 *
 * Fetching is async at the edge; parsing and comparing are pure. A failed
 * fetch is not "unverified", it is unknown — the badge has three states for
 * exactly this reason.
 *
 * Mirrors `Krivostr.Nip.Nip05` on the Haskell side.
 */

import { Result, Ok, Err } from '../fp/result';

/** The `nostr.json` document: names to hex pubkeys. Relays ignored. */
export interface Nip05Doc {
  names: Record<string, string>;
}

/**
 * Split `name@domain` into parts. A bare domain reads as the `_` name;
 * anything without exactly one `@`, or with an empty side, is not an
 * identifier.
 */
export const parseIdentifier = (raw: string): Result<string, { name: string; domain: string }> => {
  if (raw === '') return Err('empty identifier');
  const parts = raw.split('@');
  if (parts.length === 1) return Ok({ name: '_', domain: raw });
  if (parts.length === 2 && parts[0] !== '' && parts[1] !== '') {
    return Ok({ name: parts[0], domain: parts[1] });
  }
  return Err(`bad identifier: ${raw}`);
};

/**
 * The HTTPS URL serving the document, with the `?name=` query the spec asks
 * clients to send. Some hosts return an empty mapping without it, so leaving
 * it off turns valid identifiers into failures.
 */
export const wellKnownUrl = (name: string, domain: string): string =>
  `https://${domain}/.well-known/nostr.json?name=${encodeURIComponent(name)}`;

/**
 * Does the document map `name` to `pubkey`? Exact on both sides — a domain
 * mapping "Alice" does not verify "alice". Missing and mismatched fail
 * alike, so the message never tells an attacker which names exist.
 */
export const verifyName = (name: string, pubkey: string, doc: Nip05Doc): Result<string, void> =>
  doc.names[name] === pubkey ? Ok(undefined) : Err(`identifier does not match this pubkey: ${name}`);

/** Badge state: verified, failed, or not yet checked. */
export type Nip05Status = 'verified' | 'failed' | 'unknown';

/**
 * Fetch the document and verify `identifier` against `pubkey`. Network
 * errors, non-200 statuses, and bad JSON all read as `unknown` — only a
 * parsed document that disagrees reads as `failed`.
 */
export const fetchVerify = async (identifier: string, pubkey: string): Promise<Nip05Status> => {
  const parsed = parseIdentifier(identifier);
  if (parsed._tag === 'Err') return 'failed';
  try {
    const res = await fetch(wellKnownUrl(parsed.value.name, parsed.value.domain), {
      headers: { Accept: 'application/json' },
    });
    if (!res.ok) return 'unknown';
    const doc = (await res.json()) as { names?: unknown };
    if (typeof doc.names !== 'object' || doc.names === null) return 'unknown';
    return verifyName(parsed.value.name, pubkey, { names: doc.names as Record<string, string> })._tag === 'Ok'
      ? 'verified'
      : 'failed';
  } catch {
    return 'unknown';
  }
};
