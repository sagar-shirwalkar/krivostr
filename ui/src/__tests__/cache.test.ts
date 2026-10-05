import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach } from 'vitest';
import * as cache from '../nostr/cache';
import { NostrEvent } from '../nostr/event';
import { localSigner } from '../nostr/signer';

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

/** A genuinely signed event: the cache verifies, so fixtures must verify. */
const signed = async (over: Partial<NostrEvent> = {}): Promise<NostrEvent> => {
  const signer = localSigner('00'.repeat(31) + '01');
  const pk = await signer.pubkey();
  if (pk._tag !== 'Ok') throw new Error('no pubkey');
  const r = await signer.signEvent({
    pubkey: pk.value, created_at: 1000, kind: 1, tags: [], content: 'x', ...over,
  });
  if (r._tag !== 'Ok') throw new Error('not signed');
  return r.value;
};

beforeEach(async () => {
  // IDBFactory.deleteDatabase resolves with `result === undefined` per spec, so
  // the old `res(r.result)` handed back undefined and the following db.close()
  // threw. The cache drops its own handle on `versionchange`, so this cannot
  // block; treat `blocked` as success anyway rather than hanging the suite.
  await new Promise<void>((res, rej) => {
    const r = indexedDB.deleteDatabase('krivostr');
    r.onsuccess = () => res();
    r.onerror = () => rej(r.error);
    r.onblocked = () => res();
  });
});

describe('cache', () => {
  it('round-trips an event', async () => {
    const good = await signed();
    expect(await cache.put(good)).toBe(true);
    const got = await cache.get(good.id);
    expect(got?.content).toBe('x');
  });

  it('refuses forged events and stores nothing', async () => {
    const good = await signed();
    expect(await cache.put({ ...good, content: 'forged' })).toBe(false);
    expect(await cache.put({ ...good, sig: '0'.repeat(128) })).toBe(false);
    expect(await cache.put(e())).toBe(false);
    expect(await cache.get(good.id)).toBeUndefined();
  });

  it('returns undefined for missing', async () => {
    expect(await cache.get('missing')).toBeUndefined();
  });

  it('all() returns events newest-first', async () => {
    await cache.put(await signed({ content: 'older', created_at: 100 }));
    await cache.put(await signed({ content: 'newer', created_at: 200 }));
    const rows = await cache.all();
    expect(rows.map((r) => r.created_at)).toEqual([200, 100]);
  });

  it('evictExpired removes old public events', async () => {
    const old = Date.now() / 1000 - 40 * 24 * 60 * 60;
    await cache.put(await signed({ content: 'oldie', created_at: old }));
    const removed = await cache.evictExpired();
    expect(removed).toBe(1);
  });

  it('evictExpired keeps DMs and own events', async () => {
    const old = Date.now() / 1000 - 40 * 24 * 60 * 60;
    await cache.put(await signed({ content: 'dm', created_at: old, kind: 4 }));
    await cache.put(await signed({ content: 'wrap', created_at: old, kind: 1059 }));
    const removed = await cache.evictExpired();
    expect(removed).toBe(0);
  });
});
