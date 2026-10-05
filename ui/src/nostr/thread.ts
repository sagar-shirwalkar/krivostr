/**
 * NIP-10 reply conventions: how a text note says what it answers.
 *
 * A reply carries `e` tags for the thread and `p` tags for the people. The
 * marked form is preferred — `["e", id, relay, "root"|"reply"]` — and the
 * positional form (first `e` is the root, last is the reply) is only the
 * fallback for old events, because a relay that reordered tags would silently
 * reparent the thread under the positional reading.
 *
 * Mirrors `Krivostr.Nip.Nip10` on the Haskell side.
 */

import { NostrEvent } from './event';

/** Where an event sits in a thread, if anywhere. */
export interface ThreadRef {
  rootId: string;
  rootRelay: string;
  replyId: string | undefined;
  replyRelay: string;
}

type Tags = Pick<NostrEvent, 'tags'>;

const headOf = (xs: string[]): string => (xs.length > 0 ? xs[0] : '');
const at = (xs: string[], i: number): string => (i < xs.length ? xs[i] : '');

/**
 * The thread an event belongs to, if its `e` tags say so. Marked tags win;
 * without markers the positional fallback applies (one `e` is both root and
 * parent; several make the first the root and the last the parent).
 */
export const threadOf = (e: Tags): ThreadRef | undefined => {
  const es = e.tags.filter((t) => t[0] === 'e').map((t) => t.slice(1));
  if (es.length === 0) return undefined;
  const marked = es.filter((r) => r[2] === 'root' || r[2] === 'reply');
  if (marked.length > 0) {
    const root = marked.find((r) => r[2] === 'root') ?? marked[0];
    const parent = marked.find((r) => r[2] === 'reply') ?? root;
    return { rootId: headOf(root), rootRelay: at(root, 1), replyId: headOf(parent), replyRelay: at(parent, 1) };
  }
  const first = es[0];
  const last = es[es.length - 1];
  return { rootId: headOf(first), rootRelay: at(first, 1), replyId: headOf(last), replyRelay: at(last, 1) };
};

/** Does the event answer something? A lone `e` tag counts. */
export const isReply = (e: Tags): boolean => threadOf(e) !== undefined;

/** The thread root's event id, if the event is a reply. */
export const replyRoot = (e: Tags): string | undefined => threadOf(e)?.rootId;

/** The parent event's id — the note being directly answered. */
export const replyTo = (e: Tags): string | undefined => threadOf(e)?.replyId;

/** Every pubkey the event addresses with a `p` tag, in wire order. */
export const mentionedPubkeys = (e: Tags): string[] =>
  e.tags.filter((t) => t[0] === 'p' && t.length > 1).map((t) => t[1]);

/**
 * The `e` and `p` tags for answering `parentId` in `rootId`'s thread. Marked
 * form, arranged so the positional reading agrees: root first, parent last,
 * each author `p`-tagged once.
 *
 * Empty authors are dropped, not emitted: the browser often answers a reply
 * whose root it never saw, and an empty `p` tag would be worse than a
 * missing one. (The Haskell builder is strict instead — the CLI looks the
 * root up in the store.)
 */
export const buildReplyTags = (
  rootId: string,
  rootRelayHint: string,
  rootAuthor: string,
  parentId: string,
  parentRelayHint: string,
  parentAuthor: string,
): string[][] => {
  if (rootId === parentId) {
    return [['e', rootId, rootRelayHint, 'root'], ['p', rootAuthor]].filter((t) => t[1] !== '');
  }
  const tags: string[][] = [
    ['e', rootId, rootRelayHint, 'root'],
    ['p', rootAuthor],
    ['e', parentId, parentRelayHint, 'reply'],
  ];
  if (parentAuthor !== '' && parentAuthor !== rootAuthor) tags.push(['p', parentAuthor]);
  return tags.filter((t) => t[1] !== '');
};

/** Group events by thread root; bare notes group under their own id. */
export const groupByThread = (events: NostrEvent[]): Map<string, NostrEvent[]> => {
  const groups = new Map<string, NostrEvent[]>();
  for (const e of events) {
    const key = replyRoot(e) ?? e.id;
    const list = groups.get(key) ?? [];
    list.push(e);
    groups.set(key, list);
  }
  return groups;
};
