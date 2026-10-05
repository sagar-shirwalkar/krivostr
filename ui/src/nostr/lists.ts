/**
 * NIP-51 lists: mute, pins, and bookmarks.
 *
 * Kind 10000 mutes `p`-tag pubkeys, 10001 pins `e`-tag event ids, 10003
 * bookmarks `e` ids, `a` addresses, `d` identifiers, and `t` hashtags.
 * Content is conventionally empty; the tags are the list.
 *
 * The browser's use is read-side: the feed hides events from authors on
 * the viewer's own mute list. That rule is local — no relay support needed
 * — so muting works identically against the bridge and third-party relays.
 * Editing (add/remove) is the CLI's job; the pure tag ops live here for
 * the day the UI grows an editor.
 *
 * Mirrors `Krivostr.Nip.Nip51` on the Haskell side.
 */

import { NostrEvent } from './event';

/** Kind 10000: muted pubkeys. */
export const muteKind = 10000;
/** Kind 10001: pinned event ids. */
export const pinKind = 10001;
/** Kind 10003: bookmarks. */
export const bookmarkKind = 10003;

/** Every entry channel a list event can carry. */
export interface ListEntries {
  pubkeys: string[];
  events: string[];
  addresses: string[];
  tags: string[];
}

const tagged = (e: Pick<NostrEvent, 'tags'>, name: string): string[] =>
  e.tags.filter((t) => t[0] === name && t.length > 1).map((t) => t[1]);

/** Split a list event's tags into entries. Anything else is not a list. */
export const listEntries = (e: NostrEvent): ListEntries | undefined => {
  if (e.kind === muteKind) return { pubkeys: tagged(e, 'p'), events: [], addresses: [], tags: [] };
  if (e.kind === pinKind) return { pubkeys: [], events: tagged(e, 'e'), addresses: [], tags: [] };
  if (e.kind === bookmarkKind) {
    return {
      pubkeys: [],
      events: tagged(e, 'e'),
      addresses: tagged(e, 'a'),
      tags: [...tagged(e, 'd'), ...tagged(e, 't')],
    };
  }
  return undefined;
};

/** Muted pubkeys of a kind 10000. */
export const mutedPubkeys = (e: NostrEvent): string[] => listEntries(e)?.pubkeys ?? [];

/** Pinned event ids of a kind 10001. */
export const pinnedIds = (e: NostrEvent): string[] => listEntries(e)?.events ?? [];

/** Add an entry tag, idempotent: re-adding changes nothing. */
export const addEntry = (tags: string[][], name: string, value: string): string[][] =>
  tags.some((t) => t[0] === name && t[1] === value) ? tags : [...tags, [name, value]];

/** Remove every entry tag with this name and value, hints or not. */
export const removeEntry = (tags: string[][], name: string, value: string): string[][] =>
  tags.filter((t) => !(t[0] === name && t[1] === value));

/** True for the list kinds, which render as protocol traffic, not posts. */
export const isListEvent = (e: Pick<NostrEvent, 'kind'>): boolean =>
  e.kind === muteKind || e.kind === pinKind || e.kind === bookmarkKind;
