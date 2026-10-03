import { describe, it, expect } from 'vitest';
import { parseRelayList, readRelays, writeRelays, outboxFor, buildRelayListTags, DEFAULT_RELAYS } from '../nostr/nip65';
import { NostrEvent } from '../nostr/event';

const ev = (over: Partial<NostrEvent> = {}): NostrEvent => ({
  id: 'a'.repeat(64), pubkey: 'p'.repeat(64), created_at: 1000,
  kind: 10002, tags: [], content: '', sig: 's'.repeat(128),
  ...over,
});

describe('parseRelayList', () => {
  it('parses read, write, and both', () => {
    const e = ev({
      tags: [
        ['r', 'wss://a', 'read'],
        ['r', 'wss://b', 'write'],
        ['r', 'wss://c'],
      ],
    });
    expect(parseRelayList(e)).toEqual([
      { url: 'wss://a', mode: 'read' },
      { url: 'wss://b', mode: 'write' },
      { url: 'wss://c', mode: 'both' },
    ]);
  });
  it('ignores non-r tags and invalid urls', () => {
    const e = ev({ tags: [['p', 'x'], ['r', 'http://bad'], ['r', 'wss://ok']] });
    expect(parseRelayList(e)).toEqual([{ url: 'wss://ok', mode: 'both' }]);
  });
  it('returns [] for wrong kind', () => {
    expect(parseRelayList(ev({ kind: 1 }))).toEqual([]);
  });
});

describe('readRelays / writeRelays', () => {
  it('extracts read-only and both', () => {
    const h = [
      { url: 'a', mode: 'read' as const },
      { url: 'b', mode: 'write' as const },
      { url: 'c', mode: 'both' as const },
    ];
    expect(readRelays(h)).toEqual(['a', 'c']);
    expect(writeRelays(h)).toEqual(['b', 'c']);
  });
});

describe('buildRelayListTags', () => {
  it('omits mode when both', () => {
    expect(buildRelayListTags([
      { url: 'a', mode: 'both' },
      { url: 'b', mode: 'read' },
    ])).toEqual([['r', 'a'], ['r', 'b', 'read']]);
  });
});

describe('outboxFor', () => {
  it('returns read relays when available', () => {
    expect(outboxFor([{ url: 'wss://mine', mode: 'read' }])).toEqual(['wss://mine']);
  });
  it('falls back to defaults', () => {
    expect(outboxFor([])).toEqual(DEFAULT_RELAYS);
  });
});
