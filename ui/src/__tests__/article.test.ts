import { describe, it, expect } from 'vitest';
import { articleOf, isArticle, articleAddress, buildArticleTags, slugify } from '../nostr/article';
import { NostrEvent } from '../nostr/event';

const ev = (tags: string[][], content = 'body'): NostrEvent => ({
  id: 'a'.repeat(64), pubkey: 'author', created_at: 1700000000,
  kind: 30023, tags, content, sig: 'c'.repeat(128),
});

describe('articleOf', () => {
  it('parses the header and body', () => {
    expect(
      articleOf(ev([['d', 'my-post'], ['title', 'My Post'], ['summary', 'hi'], ['published_at', '1699999999']])),
    ).toEqual({
      slug: 'my-post', title: 'My Post', summary: 'hi', image: '',
      publishedAt: 1699999999, content: 'body', author: 'author',
    });
  });
  it('defaults missing header fields', () => {
    expect(articleOf(ev([['d', 'slug']])))?.toMatchObject({ title: '', publishedAt: undefined });
  });
  it('rejects other kinds, slugless articles, and bad timestamps', () => {
    expect(articleOf(ev([['d', 's']], 'x'))?.slug).toBe('s');
    expect(articleOf({ ...ev([['d', 's']]), kind: 1 })).toBeUndefined();
    expect(articleOf(ev([['title', 'No Slug']]))).toBeUndefined();
    expect(isArticle(ev([]))).toBe(false);
    expect(articleOf(ev([['d', 's'], ['published_at', 'yesterday']]))?.publishedAt).toBeUndefined();
  });
});

describe('articleAddress', () => {
  it('addresses 30023:pubkey:slug', () => {
    expect(articleAddress(ev([['d', 'my-post']]))).toBe('30023:author:my-post');
    expect(articleAddress(ev([]))).toBeUndefined();
  });
});

describe('buildArticleTags / slugify', () => {
  it('emits d plus the non-empty header', () => {
    expect(buildArticleTags('my-post', 'My Post', '', '', 1699999999)).toEqual([
      ['d', 'my-post'], ['title', 'My Post'], ['published_at', '1699999999'],
    ]);
    expect(buildArticleTags('s', '', '', '', undefined)).toEqual([['d', 's']]);
  });
  it('lowercases, dashes, and drops punctuation', () => {
    expect(slugify('Hello, World!')).toBe('hello-world');
    expect(slugify('  NIP-23:  Long-Form  ')).toBe('nip-23-long-form');
  });
});
