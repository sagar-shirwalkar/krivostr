/**
 * NIP-22 comments: threading for anything that is not a kind-1 note.
 *
 * A comment is a kind-1111 event with plaintext content. The root scope uses
 * UPPERCASE tags (`E`/`A`, `K`, `P`) and the parent scope lowercase ones
 * (`e`/`a`, `k`, `p`); both kind tags are mandatory. A top-level comment
 * points root and parent at the same item; a reply keeps the root and moves
 * the parent. Regular notes are never commented on this way — that is
 * NIP-10's job.
 *
 * Mirrors `Krivostr.Nip.Nip22` on the Haskell side.
 */

import { NostrEvent } from './event';

/** Kind 1111. */
export const commentKind = 1111;

/** One end of a comment: the item referenced, however addressed. */
export interface ItemRef {
  id: string | undefined;
  address: string | undefined;
  kind: number;
  author: string;
  relay: string;
}

/** A parsed comment: its root scope and its parent scope. */
export interface Comment {
  root: ItemRef;
  parent: ItemRef;
}

const firstOf = (e: Pick<NostrEvent, 'tags'>, name: string): string | undefined => {
  const t = e.tags.find((x) => x[0] === name && x.length > 1);
  return t?.[1];
};

const hintOf = (e: Pick<NostrEvent, 'tags'>, name: string): string => {
  const t = e.tags.find((x) => x[0] === name && x.length > 2);
  return t?.[2] ?? '';
};

/** Parse a kind-1111 event. Anything else, or a scopeless comment, fails. */
export const commentOf = (e: NostrEvent): Comment | undefined => {
  if (e.kind !== commentKind) return undefined;
  const scope = (eTag: string, aTag: string, kTag: string, pTag: string): ItemRef | undefined => {
    const id = firstOf(e, eTag);
    const address = firstOf(e, aTag);
    if (id === undefined && address === undefined) return undefined;
    const kindRaw = firstOf(e, kTag);
    if (kindRaw === undefined || !/^-?\d+$/.test(kindRaw)) return undefined;
    return {
      id,
      address,
      kind: parseInt(kindRaw, 10),
      author: firstOf(e, pTag) ?? '',
      relay: hintOf(e, eTag) || hintOf(e, aTag),
    };
  };
  const root = scope('E', 'A', 'K', 'P');
  const parent = scope('e', 'a', 'k', 'p');
  return root && parent ? { root, parent } : undefined;
};

/** Is the event a well-formed comment? */
export const isComment = (e: NostrEvent): boolean => commentOf(e) !== undefined;

/** The root scope of a comment. */
export const commentRoot = (e: NostrEvent): ItemRef | undefined => commentOf(e)?.root;

/** The parent scope of a comment. */
export const commentParent = (e: NostrEvent): ItemRef | undefined => commentOf(e)?.parent;

const scopeTags = (upper: boolean, r: ItemRef): string[][] => {
  const [eTag, aTag, kTag, pTag] = upper ? ['E', 'A', 'K', 'P'] : ['e', 'a', 'k', 'p'];
  const tags: string[][] = [];
  if (r.address !== undefined && r.id !== undefined) {
    tags.push([aTag, r.address, r.relay], [eTag, r.id, r.relay, r.author]);
  } else if (r.address !== undefined) {
    tags.push([aTag, r.address, r.relay]);
  } else if (r.id !== undefined) {
    tags.push([eTag, r.id, r.relay, r.author]);
  }
  tags.push([kTag, String(r.kind)]);
  if (r.author !== '') tags.push([pTag, r.author, r.relay]);
  return tags;
};

/**
 * Tags for commenting on `root`, optionally answering `parent`. `undefined`
 * parent means top-level: root and parent reference the same item.
 */
export const buildCommentTags = (root: ItemRef, parent?: ItemRef): string[][] => [
  ...scopeTags(true, root),
  ...scopeTags(false, parent ?? root),
];
