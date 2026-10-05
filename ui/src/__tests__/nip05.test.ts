import { describe, it, expect, vi, afterEach } from 'vitest';
import { parseIdentifier, wellKnownUrl, verifyName, fetchVerify } from '../nostr/nip05';

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('parseIdentifier', () => {
  it('splits name and domain', () => {
    expect(parseIdentifier('alice@example.com')).toEqual({ _tag: 'Ok', value: { name: 'alice', domain: 'example.com' } });
  });
  it('reads a bare domain as _', () => {
    expect(parseIdentifier('example.com')).toEqual({ _tag: 'Ok', value: { name: '_', domain: 'example.com' } });
  });
  it('rejects empty sides and double @', () => {
    expect(parseIdentifier('@example.com')._tag).toBe('Err');
    expect(parseIdentifier('alice@')._tag).toBe('Err');
    expect(parseIdentifier('a@b@c')._tag).toBe('Err');
    expect(parseIdentifier('')._tag).toBe('Err');
  });
});

describe('wellKnownUrl', () => {
  it('is HTTPS with the name query', () => {
    expect(wellKnownUrl('alice', 'example.com')).toBe('https://example.com/.well-known/nostr.json?name=alice');
  });
});

describe('verifyName', () => {
  const doc = { names: { alice: 'aaa', _: 'bbb' } };
  it('accepts the mapped pubkey', () => {
    expect(verifyName('alice', 'aaa', doc)._tag).toBe('Ok');
    expect(verifyName('_', 'bbb', doc)._tag).toBe('Ok');
  });
  it('rejects wrong keys, unknown names, and case drift alike', () => {
    expect(verifyName('alice', 'zzz', doc)._tag).toBe('Err');
    expect(verifyName('mallory', 'aaa', doc)._tag).toBe('Err');
    expect(verifyName('Alice', 'aaa', doc)._tag).toBe('Err');
  });
});

describe('fetchVerify', () => {
  it('verifies against a fetched document', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({
      ok: true,
      json: async () => ({ names: { alice: 'aaa' } }),
    })));
    expect(await fetchVerify('alice@example.com', 'aaa')).toBe('verified');
    expect(await fetchVerify('alice@example.com', 'zzz')).toBe('failed');
  });
  it('reads network failure as unknown, not failed', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 403 })));
    expect(await fetchVerify('alice@example.com', 'aaa')).toBe('unknown');
    vi.stubGlobal('fetch', vi.fn(async () => {
      throw new Error('down');
    }));
    expect(await fetchVerify('alice@example.com', 'aaa')).toBe('unknown');
  });
});
