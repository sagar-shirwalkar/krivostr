/**
 * NIP-25 user reactions.
 *
 * A reaction is a kind-7 event whose content is an emoji (or `+`/`-`) and
 * whose tags point at what it answers: `e` names the reacted event, `p` its
 * author, `k` records the reacted kind so a reader need not fetch the target
 * to tell a like on a note from a like on an article.
 *
 * The content is advisory, not load-bearing: anything that is not `-` reads
 * as a like to a client that cannot render it. Counting reactions is
 * counting kind-7 events per `e` tag, not parsing content.
 *
 * Mirrors `Krivostr.Nip.Nip25` on the Haskell side.
 */

import { NostrEvent } from './event';

/** Kind 7. */
export const reactionKind = 7;

/** A parsed reaction: what it answers and what it says. */
export interface Reaction {
  eventId: string;
  author: string;
  kind: number | undefined;
  content: string;
}

/**
 * Parse a kind-7 event. Anything else is not a reaction, and a kind 7
 * without an `e` tag answers nothing — malformed rather than universal.
 */
export const reactionOf = (e: NostrEvent): Reaction | undefined => {
  if (e.kind !== reactionKind) return undefined;
  const et = e.tags.find((t) => t[0] === 'e' && t.length > 1);
  if (!et) return undefined;
  const pt = e.tags.find((t) => t[0] === 'p' && t.length > 1);
  const kt = e.tags.find((t) => t[0] === 'k' && t.length > 1);
  const kind = kt !== undefined ? /^-?\d+$/.test(kt[1]) ? parseInt(kt[1], 10) : undefined : undefined;
  return { eventId: et[1], author: pt?.[1] ?? '', kind, content: e.content };
};

/** Is the event a well-formed reaction? */
export const isReaction = (e: NostrEvent): boolean => reactionOf(e) !== undefined;

/** `+`, an emoji, anything that is not `-` or empty. */
export const isLike = (e: Pick<NostrEvent, 'kind' | 'content'>): boolean =>
  e.kind === reactionKind && e.content !== '' && e.content !== '-';

/** An explicit dislike. */
export const isDislike = (e: Pick<NostrEvent, 'kind' | 'content'>): boolean =>
  e.kind === reactionKind && e.content === '-';

/**
 * The tags for reacting to an event: `e` for the event, `p` for its author,
 * `k` for its kind.
 */
export const buildReactionTags = (
  eventId: string,
  relayHint: string,
  author: string,
  eventKind: number,
): string[][] => [
  ['e', eventId, relayHint],
  ['p', author],
  ['k', String(eventKind)],
];

/** Likes and dislikes per reacted event id, in first-seen order. */
export const countReactions = (events: NostrEvent[]): Array<{ id: string; likes: number; dislikes: number }> => {
  const counts = new Map<string, { likes: number; dislikes: number }>();
  for (const e of events) {
    const r = reactionOf(e);
    if (!r) continue;
    const c = counts.get(r.eventId) ?? { likes: 0, dislikes: 0 };
    if (r.content === '-') c.dislikes += 1;
    else if (r.content !== '') c.likes += 1;
    counts.set(r.eventId, c);
  }
  return [...counts.entries()].map(([id, c]) => ({ id, ...c }));
};

/** True when this pubkey already reacted to the event (one vote each). */
export const hasReacted = (events: NostrEvent[], eventId: string, pubkey: string): boolean =>
  events.some((e) => e.kind === reactionKind && e.pubkey === pubkey && reactionOf(e)?.eventId === eventId);

