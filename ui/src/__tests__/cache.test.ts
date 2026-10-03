import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach } from 'vitest';
import * as cache from '../nostr/cache';
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

beforeEach(async () => {
  const db = await new Promise<IDBDatabase>((res, rej) => {
    const r = indexedDB.deleteDatabase('krivostr');
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
  db.close();
});

describe('cache', () => {
  it('round-trips an event', async () => {
    await cache.put(e());
    const got = await cache.get('a'.repeat(64));
    expect(got?.content).toBe('x');
  });

  it('returns undefined for missing', async () => {
    expect(await cache.get('missing')).toBeUndefined();
  });

  it('all() returns events newest-first', async () => {
    await cache.put(e({ id: '1'.repeat(64), created_at: 100 }));
    await cache.put(e({ id: '2'.repeat(64), created_at: 200 }));
    const rows = await cache.all();
    expect(rows.map((r) => r.created_at)).toEqual([200, 100]);
  });

  it('evictExpired removes old public events', async () => {
    const old = Date.now() / 1000 - 40 * 24 * 60 * 60;
    await cache.put(e({ id: '3'.repeat(64), created_at: old }));
    const removed = await cache.evictExpired();
    expect(removed).toBe(1);
  });

  it('evictExpired keeps DMs and own events', async () => {
    const old = Date.now() / 1000 - 40 * 24 * 60 * 60;
    await cache.put(e({ id: '4'.repeat(64), created_at: old, kind: 4 }));
    await cache.put(e({ id: '5'.repeat(64), created_at: old, kind: 1059 }));
    const removed = await cache.evictExpired();
    expect(removed).toBe(0);
  });
});
