import { describe, it, expect } from 'vitest';
import { listEntries, mutedPubkeys, pinnedIds, addEntry, removeEntry, isListEvent } from '../nostr/lists';
import { NostrEvent } from '../nostr/event';

const ev = (kind: number, tags: string[][]): NostrEvent => ({
  id: 'a'.repeat(64), pubkey: 'owner', created_at: 1700000000,
  kind, tags, content: '', sig: 'c'.repeat(128),
});

describe('listEntries', () => {
  it('reads mutes, pins, and bookmarks', () => {
    expect(listEntries(ev(10000, [['p', 'alice', 'wss://r'], ['p', 'bob']]))?.pubkeys).toEqual(['alice', 'bob']);
    expect(listEntries(ev(10001, [['e', 'n1'], ['e', 'n2']]))?.events).toEqual(['n1', 'n2']);
    expect(
      listEntries(ev(10003, [['e', 'n1'], ['a', '30023:x:y'], ['d', 'i'], ['t', 'art']])),
    ).toEqual({ pubkeys: [], events: ['n1'], addresses: ['30023:x:y'], tags: ['i', 'art'] });
  });
  it('rejects other kinds', () => {
    expect(listEntries(ev(1, [['p', 'alice']]))).toBeUndefined();
    expect(mutedPubkeys(ev(1, [['p', 'alice']]))).toEqual([]);
    expect(pinnedIds(ev(10001, [['e', 'n1']]))).toEqual(['n1']);
  });
});

describe('addEntry / removeEntry', () => {
  it('adds idempotently and removes regardless of hints', () => {
    expect(addEntry([], 'p', 'alice')).toEqual([['p', 'alice']]);
    expect(addEntry([['p', 'alice']], 'p', 'alice')).toEqual([['p', 'alice']]);
    expect(removeEntry([['p', 'alice', 'wss://r'], ['p', 'bob']], 'p', 'alice')).toEqual([['p', 'bob']]);
  });
});

describe('isListEvent', () => {
  it('names the list kinds', () => {
    expect([10000, 10001, 10003].every((k) => isListEvent({ kind: k }))).toBe(true);
    expect(isListEvent({ kind: 1 })).toBe(false);
  });
});
