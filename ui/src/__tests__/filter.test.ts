import { describe, it, expect } from 'vitest';
import { compile, matches, toWire } from '../nostr/filter';
import { NostrEvent } from '../nostr/event';

const e = (over: Partial<NostrEvent> = {}): NostrEvent => ({
  id: 'a'.repeat(64),
  pubkey: 'p'.repeat(64),
  created_at: 1000,
  kind: 1,
  tags: [],
  content: 'x',
  sig: 's'.repeat(128),
  ...over,
});

describe('filter.compile', () => {
  it('empty spec matches everything', () => {
    expect(compile({}).test(e())).toBe(true);
  });
  it('kinds filter', () => {
    expect(compile({ kinds: [1] }).test(e({ kind: 1 }))).toBe(true);
    expect(compile({ kinds: [7] }).test(e({ kind: 1 }))).toBe(false);
  });
  it('authors filter', () => {
    expect(compile({ authors: ['p'.repeat(64)] }).test(e())).toBe(true);
    expect(compile({ authors: ['q'] }).test(e())).toBe(false);
  });
  it('since / until', () => {
    expect(compile({ since: 500 }).test(e({ created_at: 1000 }))).toBe(true);
    expect(compile({ since: 1500 }).test(e({ created_at: 1000 }))).toBe(false);
    expect(compile({ until: 1500 }).test(e({ created_at: 1000 }))).toBe(true);
    expect(compile({ until: 500 }).test(e({ created_at: 1000 }))).toBe(false);
  });
  it('ids filter', () => {
    expect(compile({ ids: ['a'.repeat(64)] }).test(e())).toBe(true);
    expect(compile({ ids: ['z'] }).test(e())).toBe(false);
  });
  it('tag filter matches any value', () => {
    const ev = e({ tags: [['p', 'alice'], ['p', 'bob']] });
    expect(compile({ tags: { p: ['bob'] } }).test(ev)).toBe(true);
    expect(compile({ tags: { p: ['carol'] } }).test(ev)).toBe(false);
  });
  it('search matches a case-insensitive substring of the content', () => {
    const ev = e({ content: 'The Quick Brown Fox' });
    expect(compile({ search: 'quick brown' }).test(ev)).toBe(true);
    expect(compile({ search: 'QUICK' }).test(ev)).toBe(true);
    expect(compile({ search: 'aardvark' }).test(ev)).toBe(false);
  });
});

describe('filter.matches', () => {
  it('is a shorthand for compile().test()', () => {
    expect(matches({ kinds: [1] }, e())).toBe(true);
  });
});

describe('filter.toWire', () => {
  it('prepends # to tag filters', () => {
    expect(toWire({ tags: { e: ['x'] } })).toEqual({ '#e': ['x'] });
  });
  it('passes through other fields', () => {
    expect(toWire({ kinds: [1], limit: 10, since: 100 })).toEqual({
      kinds: [1], limit: 10, since: 100,
    });
  });
  it('sends search under its wire key', () => {
    expect(toWire({ search: 'hello' })).toEqual({ search: 'hello' });
  });
});
