/**
 * NIP-65 relay list metadata. Kind 10002 events carry `r` tags that
 * advertise read/write relays. This is how we get rid of hard-coded
 * RELAYS in the UI and move to the outbox model.
 */

import { NostrEvent } from './event';

export type RelayMode = 'read' | 'write' | 'both';

export interface RelayHint {
  url: string;
  mode: RelayMode;
}

const isRelayUrl = (s: string): boolean =>
  s.startsWith('wss://') || s.startsWith('ws://');

export const parseRelayList = (e: NostrEvent): RelayHint[] => {
  if (e.kind !== 10002) return [];
  const out: RelayHint[] = [];
  for (const tag of e.tags) {
    if (tag[0] !== 'r') continue;
    const url = tag[1];
    if (!url || !isRelayUrl(url)) continue;
    const m = tag[2];
    const mode: RelayMode = m === 'read' ? 'read' : m === 'write' ? 'write' : 'both';
    out.push({ url, mode });
  }
  return out;
};

export const readRelays = (hints: RelayHint[]): string[] =>
  hints.filter((h) => h.mode === 'read' || h.mode === 'both').map((h) => h.url);

export const writeRelays = (hints: RelayHint[]): string[] =>
  hints.filter((h) => h.mode === 'write' || h.mode === 'both').map((h) => h.url);

export const buildRelayListTags = (hints: RelayHint[]): string[][] =>
  hints.map((h) =>
    h.mode === 'both' ? ['r', h.url] : ['r', h.url, h.mode],
  );

/**
 * Fallback pool. Used only until we learn the user's NIP-65 list.
 * These are the well-known general-purpose relays.
 */
export const DEFAULT_RELAYS: string[] = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://nostr.wine',
];

/**
 * The outbox model: given a pubkey and their NIP-65 hints, decide which
 * relays to *read* from (the user's read set + their follows' write sets).
 */
export const outboxFor = (hints: RelayHint[]): string[] => {
  const reads = readRelays(hints);
  return reads.length > 0 ? reads : DEFAULT_RELAYS;
};
