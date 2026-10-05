import { describe, it, expect } from 'vitest';
import {
  reactionOf,
  isReaction,
  isLike,
  isDislike,
  buildReactionTags,
  countReactions,
  hasReacted,
} from '../nostr/reaction';
import {
  repostOf,
  isRepost,
  quoteOf,
  isQuote,
  buildRepostTags,
  buildQuoteTags,
  embedOriginal,
  embeddedOriginal,
} from '../nostr/repost';
import { NostrEvent } from '../nostr/event';

const ev = (over: Partial<NostrEvent> = {}): NostrEvent => ({
  id: 'a'.repeat(64), pubkey: 'b'.repeat(64), created_at: 1700000000,
  kind: 7, tags: [], content: '+', sig: 'c'.repeat(128),
  ...over,
});

describe('reactionOf', () => {
  it('parses e, p and k tags', () => {
    expect(reactionOf(ev({ tags: [['e', 'target-id', 'wss://r'], ['p', 'alice'], ['k', '1']] }))).toEqual({
      eventId: 'target-id', author: 'alice', kind: 1, content: '+',
    });
  });
  it('rejects other kinds, tagless reactions, and malformed k', () => {
    expect(reactionOf(ev({ kind: 1 }))).toBeUndefined();
    expect(reactionOf(ev({ tags: [['p', 'alice']] }))).toBeUndefined();
    expect(reactionOf(ev({ tags: [['e', 't'], ['k', 'many']] }))?.kind).toBeUndefined();
  });
});

describe('isLike / isDislike', () => {
  it('reads +, emoji, -, and empty', () => {
    expect(isLike(ev({ content: '+' }))).toBe(true);
    expect(isLike(ev({ content: '❤' }))).toBe(true);
    expect(isLike(ev({ content: '-' }))).toBe(false);
    expect(isLike(ev({ content: '' }))).toBe(false);
    expect(isDislike(ev({ content: '-' }))).toBe(true);
  });
});

describe('buildReactionTags / countReactions / hasReacted', () => {
  it('emits e, p and k', () => {
    expect(buildReactionTags('t', 'wss://r', 'alice', 1)).toEqual([
      ['e', 't', 'wss://r'], ['p', 'alice'], ['k', '1'],
    ]);
  });
  it('counts per id in first-seen order', () => {
    const es = [
      ev({ tags: [['e', 'a']] }),
      ev({ content: '❤', tags: [['e', 'a']] }),
      ev({ content: '-', tags: [['e', 'a']] }),
      ev({ tags: [['e', 'b']] }),
      ev({ tags: [] }),
    ];
    expect(countReactions(es)).toEqual([
      { id: 'a', likes: 2, dislikes: 1 },
      { id: 'b', likes: 1, dislikes: 0 },
    ]);
  });
  it('detects one vote each', () => {
    const es = [ev({ pubkey: 'alice', tags: [['e', 'a']] })];
    expect(hasReacted(es, 'a', 'alice')).toBe(true);
    expect(hasReacted(es, 'a', 'bob')).toBe(false);
    expect(isReaction(es[0])).toBe(true);
  });
});

describe('repostOf / quoteOf', () => {
  it('parses kind 6 and kind 16 with k', () => {
    expect(repostOf(ev({ kind: 6, tags: [['e', 't', 'wss://r'], ['p', 'alice']] }))).toEqual({
      eventId: 't', author: 'alice', kind: 1,
    });
    expect(repostOf(ev({ kind: 16, tags: [['e', 'a'], ['p', 'bob'], ['k', '30023']] }))?.kind).toBe(30023);
    expect(isRepost(ev({ kind: 6, tags: [] }))).toBe(false);
    expect(isRepost(ev({ kind: 1, tags: [] }))).toBe(false);
  });
  it('quotes with q on kind 1 only', () => {
    expect(quoteOf(ev({ kind: 1, tags: [['q', 't', 'wss://r']] }))).toEqual({ eventId: 't', relay: 'wss://r' });
    expect(isQuote(ev({ kind: 1, tags: [['q', 't']] }))).toBe(true);
    expect(quoteOf(ev({ kind: 1, tags: [] }))).toBeUndefined();
    expect(quoteOf(ev({ kind: 6, tags: [['q', 't']] }))).toBeUndefined();
  });
});

describe('builders and embedding', () => {
  it('builds repost tags with k only for non-kind-1', () => {
    expect(buildRepostTags('t', 'wss://r', 'alice', 1)).toEqual([['e', 't', 'wss://r'], ['p', 'alice']]);
    expect(buildRepostTags('a', 'wss://r', 'bob', 30023)).toContainEqual(['k', '30023']);
    expect(buildQuoteTags('t', 'wss://r')).toEqual([['q', 't', 'wss://r']]);
  });
  it('embeds the original as JSON and reads it back', () => {
    const target = ev({ kind: 1, content: 'original', tags: [] });
    expect(embeddedOriginal(embedOriginal(target))).toEqual(target);
    expect(embeddedOriginal('not json')).toBeUndefined();
  });
});
