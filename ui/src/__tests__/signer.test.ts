import { describe, it, expect, vi, beforeEach } from 'vitest';
import { localSigner, nip07Signer, isNip07Available, parseBunkerUrl, publish } from '../nostr/signer';
import { Ok, Err } from '../fp/result';

const NSEC_HEX = '0000000000000000000000000000000000000000000000000000000000000001';

describe('localSigner', () => {
  it('derives a pubkey', async () => {
    const s = localSigner(NSEC_HEX);
    const pk = await s.pubkey();
    expect(pk._tag).toBe('Ok');
    if (pk._tag === 'Ok') expect(pk.value).toHaveLength(64);
  });

  it('signs a well-formed event', async () => {
    const s = localSigner(NSEC_HEX);
    const pk = await s.pubkey();
    if (pk._tag !== 'Ok') throw new Error('pubkey failed');
    const r = await s.signEvent({
      pubkey: pk.value,
      created_at: 1700000000,
      kind: 1,
      tags: [],
      content: 'hi',
    });
    expect(r._tag).toBe('Ok');
    if (r._tag === 'Ok') {
      expect(r.value.id).toHaveLength(64);
      expect(r.value.sig).toHaveLength(128);
    }
  });
});

describe('nip07Signer', () => {
  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  it('returns Err when no provider', async () => {
    const s = nip07Signer();
    const r = await s.pubkey();
    expect(r._tag).toBe('Err');
  });

  it('delegates to window.nostr when present', async () => {
    vi.stubGlobal('window', {
      nostr: {
        getPublicKey: async () => 'pk',
        signEvent: async (e: unknown) => ({ ...(e as object), id: 'x', sig: 'y' }),
      },
    });
    expect(isNip07Available()).toBe(true);
    const s = nip07Signer();
    const r = await s.pubkey();
    expect(r).toEqual(Ok('pk'));
  });
});

describe('parseBunkerUrl', () => {
  it('parses valid bunker URLs', () => {
    const r = parseBunkerUrl('bunker://abc?relay=wss%3A%2F%2Fr');
    expect(r._tag).toBe('Ok');
    if (r._tag === 'Ok') {
      expect(r.value.remotePubkey).toBe('abc');
      expect(r.value.relay).toBe('wss://r');
    }
  });
  it('rejects missing relay', () => {
    expect(parseBunkerUrl('bunker://abc')._tag).toBe('Err');
  });
  it('rejects wrong scheme', () => {
    expect(parseBunkerUrl('https://abc?relay=x')._tag).toBe('Err');
  });
});

describe('publish boundary', () => {
  it('signs then publishes', async () => {
    const signer = localSigner(NSEC_HEX);
    const published: unknown[] = [];
    const relay = {
      url: 'x',
      state: () => 'open' as const,
      subscribe: () => undefined,
      publish: (e: unknown) => published.push(e),
      close: () => undefined,
    };
    const pk = await signer.pubkey();
    if (pk._tag !== 'Ok') throw new Error();
    const r = await publish(signer, relay, {
      pubkey: pk.value,
      created_at: 0,
      kind: 1,
      tags: [],
      content: 'hello',
    });
    expect(r._tag).toBe('Ok');
    expect(published).toHaveLength(1);
  });
});
