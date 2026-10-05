/**
 * NIP-09 event deletion requests.
 *
 * A deletion is a kind-5 event whose `e` tags name event ids and whose `a`
 * tags name parameterized addresses (`kind:pubkey:d`). It takes effect only
 * against its author's own events — a kind 5 from anyone else is graffiti,
 * not authority, so every predicate here checks authorship first.
 *
 * Deletion is advisory: relays may keep serving the bytes. The client drops
 * its own copy (`applyDeletions`) and hides cited targets, which is the part
 * it controls. This works identically against the bridge and third-party
 * relays, because the rule is local.
 *
 * Mirrors `Krivostr.Nip.Nip09` on the Haskell side.
 */

import { NostrEvent } from './event';

/** Kind 5. */
export const deletionKind = 5;

/** A parsed deletion request: cited ids and cited addresses. */
export interface Deletion {
  eventIds: string[];
  addresses: string[];
}

/** Parse a kind-5 event. Any other kind is not a deletion. */
export const deletionOf = (e: NostrEvent): Deletion | undefined => {
  if (e.kind !== deletionKind) return undefined;
  return {
    eventIds: e.tags.filter((t) => t[0] === 'e' && t.length > 1 && t[1] !== '').map((t) => t[1]),
    addresses: e.tags.filter((t) => t[0] === 'a' && t.length > 1 && t[1] !== '').map((t) => t[1]),
  };
};

/** Is the event a deletion request? */
export const isDeletion = (e: NostrEvent): boolean => deletionOf(e) !== undefined;

/** The parameterized address of an event, if it has one (kinds 30000–39999 with a `d` tag). */
export const parameterizedAddress = (e: NostrEvent): string | undefined => {
  if (e.kind < 30000 || e.kind > 39999) return undefined;
  const d = e.tags.find((t) => t[0] === 'd' && t.length > 1);
  return d ? `${e.kind}:${e.pubkey}:${d[1]}` : undefined;
};

/**
 * Does a deletion request remove the target? Same author, and cited by id
 * or by address.
 */
export const appliesTo = (deletion: NostrEvent, target: NostrEvent): boolean => {
  if (deletion.kind !== deletionKind) return false;
  if (deletion.pubkey !== target.pubkey) return false;
  const d = deletionOf(deletion);
  if (!d) return false;
  if (d.eventIds.includes(target.id)) return true;
  const addr = parameterizedAddress(target);
  return addr !== undefined && d.addresses.includes(addr);
};

/**
 * Split events into visible and deleted: any event a valid deletion applies
 * to is dropped. Deletions themselves stay visible (the feed renders them
 * compactly) so the user sees what was asked, not just its absence.
 */
export const applyDeletions = (events: NostrEvent[]): NostrEvent[] => {
  const deletions = events.filter((e) => e.kind === deletionKind);
  if (deletions.length === 0) return events;
  return events.filter((e) => e.kind === deletionKind || !deletions.some((d) => appliesTo(d, e)));
};

/** Tags for deleting by ids and addresses. Empty cites are dropped. */
export const buildDeletionTags = (ids: string[], addresses: string[]): string[][] => [
  ...ids.filter((i) => i !== '').map((i) => ['e', i]),
  ...addresses.filter((a) => a !== '').map((a) => ['a', a]),
];
