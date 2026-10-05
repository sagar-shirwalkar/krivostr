/**
 * NIP-18 reposts and quotes.
 *
 * Two shapes, and confusing them breaks the reader:
 * - A *repost* (kind 6) embeds the original event as JSON in its content
 *   and `e`-tags its id. The repost carries no text of its own.
 * - A *quote* (kind 1) is an ordinary note with commentary whose `q` tag
 *   cites the quoted event. The `q` tag — not `e` — keeps the quote out of
 *   the original's reply thread: an `e` tag would make every quoter look
 *   like a replier.
 *
 * Kind 16 (generic repost) wraps any other kind the way kind 6 wraps kind 1,
 * with a `k` tag recording the reposted kind so a reader need not parse the
 * embedded JSON to decide whether it can render the event.
 *
 * Mirrors `Krivostr.Nip.Nip18` on the Haskell side.
 */

import { NostrEvent, parseEvent } from './event';

/** Kind 6: repost of a kind-1 note. */
export const repostKind = 6;
/** Kind 16: generic repost of any other kind. */
export const genericRepostKind = 16;

/** A parsed repost: the original's id, author, and kind. */
export interface Repost {
  eventId: string;
  author: string;
  kind: number | undefined;
}

/** Parse a kind-6 or kind-16 event. Any other kind is not a repost. */
export const repostOf = (e: NostrEvent): Repost | undefined => {
  if (e.kind !== repostKind && e.kind !== genericRepostKind) return undefined;
  const et = e.tags.find((t) => t[0] === 'e' && t.length > 1);
  if (!et) return undefined;
  const pt = e.tags.find((t) => t[0] === 'p' && t.length > 1);
  const kt = e.tags.find((t) => t[0] === 'k' && t.length > 1);
  const kind =
    kt !== undefined ? (/^-?\d+$/.test(kt[1]) ? parseInt(kt[1], 10) : undefined)
    : e.kind === repostKind ? 1
    : undefined;
  return { eventId: et[1], author: pt?.[1] ?? '', kind };
};

/** Is the event a well-formed repost? */
export const isRepost = (e: NostrEvent): boolean => repostOf(e) !== undefined;

/** A parsed quote: the cited event's id and relay hint. */
export interface Quote {
  eventId: string;
  relay: string;
}

/**
 * Parse the `q` tag of a kind-1 note. A quote is a kind 1 *with* a `q` tag;
 * the same tag on any other kind is ignored.
 */
export const quoteOf = (e: NostrEvent): Quote | undefined => {
  if (e.kind !== 1) return undefined;
  const q = e.tags.find((t) => t[0] === 'q' && t.length > 1);
  if (!q) return undefined;
  return { eventId: q[1], relay: q.length > 2 ? q[2] : '' };
};

/** Is the event a quote? */
export const isQuote = (e: NostrEvent): boolean => quoteOf(e) !== undefined;

/**
 * Tags for reposting: `e` for the original, `p` for its author. A kind-6
 * needs no `k` (always a kind 1 inside); a generic repost adds one.
 */
export const buildRepostTags = (
  eventId: string,
  relayHint: string,
  author: string,
  originalKind: number,
): string[][] => {
  const tags: string[][] = [
    ['e', eventId, relayHint],
    ['p', author],
  ];
  if (originalKind !== 1) tags.push(['k', String(originalKind)]);
  return tags;
};

/**
 * Tags for quoting: a single `q` tag. Deliberately not `e`, so the quote
 * never joins the original's reply thread.
 */
export const buildQuoteTags = (eventId: string, relayHint: string): string[][] => [
  ['q', eventId, relayHint],
];

/** The repost content: the original event as JSON text. */
export const embedOriginal = (e: NostrEvent): string => JSON.stringify(e);

/** Read the embedded original back out of a repost's content. */
export const embeddedOriginal = (content: string): NostrEvent | undefined => {
  try {
    const r = parseEvent(JSON.parse(content) as unknown);
    return r._tag === 'Ok' ? r.value : undefined;
  } catch {
    return undefined;
  }
};
