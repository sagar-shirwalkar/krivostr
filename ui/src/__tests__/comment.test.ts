import { describe, it, expect } from 'vitest';
import { commentOf, isComment, commentRoot, commentParent, buildCommentTags, ItemRef } from '../nostr/comment';
import { NostrEvent } from '../nostr/event';

const ev = (tags: string[][], kind = 1111): NostrEvent => ({
  id: 'a'.repeat(64), pubkey: 'commenter', created_at: 1700000000,
  kind, tags, content: 'great post', sig: 'c'.repeat(128),
});

const article: ItemRef = {
  id: 'article-v1', address: '30023:alice:slug', kind: 30023, author: 'alice', relay: 'wss://r',
};

describe('commentOf', () => {
  it('parses root and parent scopes on an article comment', () => {
    const c = commentOf(ev(buildCommentTags(article)));
    expect(c?.root).toEqual(article);
    expect(c?.parent).toEqual(article);
    expect(isComment(ev(buildCommentTags(article)))).toBe(true);
  });
  it('keeps the root when answering another comment', () => {
    const parent: ItemRef = { id: 'comment-1', address: undefined, kind: 1111, author: 'bob', relay: '' };
    const c = commentOf(ev(buildCommentTags(article, parent)));
    expect(c?.root).toEqual(article);
    expect(c?.parent).toEqual(parent);
    expect(commentRoot(ev(buildCommentTags(article)))?.kind).toBe(30023);
    expect(commentParent(ev(buildCommentTags(article, parent)))?.id).toBe('comment-1');
  });
  it('rejects other kinds and scopeless comments', () => {
    expect(commentOf(ev([], 1))).toBeUndefined();
    expect(commentOf(ev([['K', '30023'], ['k', '30023']]))).toBeUndefined();
    expect(commentOf(ev([['E', 'x'], ['e', 'x']]))).toBeUndefined();
    expect(isComment(ev([], 1))).toBe(false);
  });
});

describe('buildCommentTags', () => {
  it('addresses plain events by id alone', () => {
    expect(
      buildCommentTags({ id: 'note-9', address: undefined, kind: 42, author: 'carol', relay: '' }),
    ).toEqual([
      ['E', 'note-9', '', 'carol'], ['K', '42'], ['P', 'carol', ''],
      ['e', 'note-9', '', 'carol'], ['k', '42'], ['p', 'carol', ''],
    ]);
  });
  it('addresses articles by coordinate plus version', () => {
    expect(buildCommentTags(article)).toEqual([
      ['A', '30023:alice:slug', 'wss://r'], ['E', 'article-v1', 'wss://r', 'alice'],
      ['K', '30023'], ['P', 'alice', 'wss://r'],
      ['a', '30023:alice:slug', 'wss://r'], ['e', 'article-v1', 'wss://r', 'alice'],
      ['k', '30023'], ['p', 'alice', 'wss://r'],
    ]);
  });
});
