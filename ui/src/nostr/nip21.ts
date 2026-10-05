/**
 * NIP-21 `nostr:` URIs: one reference, alone, as an address.
 *
 * Where NIP-27 scans mentions out of prose, NIP-21 names a single entity:
 * the whole input (modulo whitespace) must be exactly one `nostr:`
 * reference. Anything else is not a URI — opening it would mean guessing
 * which part was meant.
 *
 * `resolveTarget` maps a mention onto what the client opens: an event
 * reader, an author view, or an address lookup. Opaque references resolve
 * to nothing; the UI renders them inert rather than dead links.
 *
 * Mirrors `Krivostr.Nip.Nip21` on the Haskell side.
 */

import { Mention, findMentions } from './nip27';

/** Parse a `nostr:` URI into its mention, or fail it. */
export const parseNostrUri = (raw: string): Mention | undefined => {
  const trimmed = raw.trim();
  if (trimmed === '') return undefined;
  const found = findMentions(trimmed);
  return found.length === 1 && found[0].raw === trimmed ? found[0] : undefined;
};

/** What the client opens for a mention. */
export type OpenTarget =
  | { view: 'event'; id: string }
  | { view: 'author'; pubkey: string }
  | { view: 'address'; coordinate: string };

/** Map a mention onto its open target. Opaque references open nothing. */
export const resolveTarget = (m: Mention): OpenTarget | undefined => {
  switch (m.kind.type) {
    case 'pubkey':
      return { view: 'author', pubkey: m.kind.hex };
    case 'event':
      return { view: 'event', id: m.kind.hex };
    case 'profile':
      return { view: 'author', pubkey: m.kind.hex };
    case 'address':
      return { view: 'address', coordinate: m.kind.coordinate };
    case 'opaque':
      return undefined;
  }
};
