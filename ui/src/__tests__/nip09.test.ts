import { describe, it, expect } from 'vitest';
import {
  deletionOf,
  isDeletion,
  parameterizedAddress,
  appliesTo,
  applyDeletions,
  buildDeletionTags,
} from '../nostr/nip09';
import { NostrEvent } from '../nostr/event';

const ev = (over: Partial<NostrEvent> = {}): NostrEvent => ({
  id: 'a'.repeat(64), pubkey: 'alice', created_at: 1700000000,
  kind: 1, tags: [], content: 'hi', sig: 'c'.repeat(128),
  ...over,
});

describe('deletionOf', () => {
  it('parses e and a tags', () => {
    expect(deletionOf(ev({ kind: 5, tags: [['e', 't1'], ['a', '30023:alice:s']] }))).toEqual({
      eventIds: ['t1'], addresses: ['30023:alice:s'],
    });
  });
  it('rejects other kinds and drops empty cites', () => {
    expect(deletionOf(ev({ tags: [['e', 't1']] }))).toBeUndefined();
    expect(deletionOf(ev({ kind: 5, tags: [['e', ''], ['p', 'bob']] }))).toEqual({ eventIds: [], addresses: [] });
    expect(isDeletion(ev({ kind: 5, tags: [['e', 't1']] }))).toBe(true);
    expect(isDeletion(ev({ kind: 1, tags: [] }))).toBe(false);
  });
});

describe('parameterizedAddress', () => {
  it('addresses replaceable events', () => {
    expect(parameterizedAddress(ev({ kind: 30023, tags: [['d', 'slug']] }))).toBe('30023:alice:slug');
  });
  it('has no address for regular or d-less events', () => {
    expect(parameterizedAddress(ev({ kind: 1, tags: [] }))).toBeUndefined();
    expect(parameterizedAddress(ev({ kind: 30023, tags: [] }))).toBeUndefined();
  });
});

describe('appliesTo', () => {
  it('matches by id and by address with the same author', () => {
    expect(appliesTo(ev({ kind: 5, tags: [['e', 't1']] }), ev({ id: 't1' }))).toBe(true);
    expect(
      appliesTo(ev({ kind: 5, tags: [['a', '30023:alice:s']] }), ev({ kind: 30023, tags: [['d', 's']] })),
    ).toBe(true);
  });
  it('refuses other authors, uncited events, and non-deletions', () => {
    expect(appliesTo(ev({ kind: 5, pubkey: 'mallory', tags: [['e', 't1']] }), ev({ id: 't1' }))).toBe(false);
    expect(appliesTo(ev({ kind: 5, tags: [['e', 'other']] }), ev({ id: 't1' }))).toBe(false);
    expect(appliesTo(ev({ kind: 7, tags: [['e', 't1']] }), ev({ id: 't1' }))).toBe(false);
  });
});

describe('applyDeletions', () => {
  it('drops cited targets and keeps the requests', () => {
    const target = ev({ id: 't1' });
    const req = ev({ id: 'd1', kind: 5, tags: [['e', 't1']] });
    const other = ev({ id: 'o1' });
    expect(applyDeletions([target, req, other]).map((e) => e.id)).toEqual(['d1', 'o1']);
  });
  it('passes everything through when nothing is deleted', () => {
    const es = [ev({ id: 't1' })];
    expect(applyDeletions(es)).toBe(es);
  });
});

describe('buildDeletionTags', () => {
  it('emits e and a tags, dropping empties', () => {
    expect(buildDeletionTags(['a', ''], ['x:y:z', ''])).toEqual([['e', 'a'], ['a', 'x:y:z']]);
  });
});
