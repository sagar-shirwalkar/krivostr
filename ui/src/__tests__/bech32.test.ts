import { describe, it, expect } from 'vitest';
import {
  encode, decode, npubEncode, npubDecode, nsecEncode, nsecDecode,
  noteEncode, noteDecode, nprofileEncode, nprofileDecode,
} from '../nostr/bech32';

const HEX64 = 'a'.repeat(64);

describe('bech32 primitives', () => {
  it('round-trips raw bytes', () => {
    const bytes = new Uint8Array([0xde, 0xad, 0xbe, 0xef]);
    const s = encode('test', bytes);
    expect(decode(s).bytes).toEqual(bytes);
  });
  it('rejects mixed case', () => {
    expect(() => decode('nPub1ABC')).toThrow();
  });
  it('rejects bad checksum', () => {
    expect(() => decode('npub1qqqqqqqq')).toThrow();
  });
});

describe('npub / nsec', () => {
  it('npub round-trips', () => {
    expect(npubDecode(npubEncode(HEX64))).toBe(HEX64);
  });
  it('nsec round-trips', () => {
    expect(nsecDecode(nsecEncode(HEX64))).toBe(HEX64);
  });
  it('rejects wrong prefix', () => {
    expect(() => npubDecode(nsecEncode(HEX64))).toThrow();
    expect(() => nsecDecode(npubEncode(HEX64))).toThrow();
  });
});

describe('note', () => {
  it('round-trips', () => {
    expect(noteDecode(noteEncode(HEX64))).toBe(HEX64);
  });
});

describe('nprofile TLV', () => {
  it('encodes and decodes pubkey + relays', () => {
    const p = { pubkey: HEX64, relays: ['wss://a.example', 'wss://b.example'] };
    const decoded = nprofileDecode(nprofileEncode(p));
    expect(decoded.pubkey).toBe(HEX64);
    expect(decoded.relays).toEqual(p.relays);
  });
  it('handles no relays', () => {
    const decoded = nprofileDecode(nprofileEncode({ pubkey: HEX64 }));
    expect(decoded.pubkey).toBe(HEX64);
    expect(decoded.relays).toBeUndefined();
  });
});

describe('nevent / naddr', () => {
  it('round-trips a full event pointer', async () => {
    const { neventEncode, neventDecode } = await import('../nostr/bech32');
    const p = { id: 'ab'.repeat(32), relays: ['wss://r.ly'], author: 'cd'.repeat(32), kind: 1 };
    expect(neventDecode(neventEncode(p))).toEqual({ ...p });
    expect(neventEncode({ id: 'ab'.repeat(32) })).toMatch(/^nevent1/);
  });

  it('round-trips a bare event pointer', async () => {
    const { neventEncode, neventDecode } = await import('../nostr/bech32');
    expect(neventDecode(neventEncode({ id: 'ab'.repeat(32) }))).toEqual({
      id: 'ab'.repeat(32), relays: [], author: undefined, kind: undefined,
    });
  });

  it('rejects a pointer without an id', async () => {
    const { neventDecode, encode } = await import('../nostr/bech32');
    const bad = encode('nevent', new Uint8Array([1, 7, ...new TextEncoder().encode('wss://r')]));
    expect(() => neventDecode(bad)).toThrow();
    expect(() => neventDecode('npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq')).toThrow();
  });

  it('round-trips an address pointer and names its coordinate', async () => {
    const { naddrEncode, naddrDecode, naddrAddress } = await import('../nostr/bech32');
    const p = { identifier: 'my-post', relays: ['wss://r.ly'], author: 'cd'.repeat(32), kind: 30023 };
    expect(naddrDecode(naddrEncode(p))).toEqual({ ...p });
    expect(naddrAddress(p)).toBe(`30023:${'cd'.repeat(32)}:my-post`);
    expect(naddrEncode(p)).toMatch(/^naddr1/);
  });

  it('rejects missing identifier, author, and kind', async () => {
    const { naddrDecode, naddrEncode, encode } = await import('../nostr/bech32');
    const noIdent = encode('naddr', new Uint8Array([2, 32, ...new Uint8Array(32).fill(0xcd), 3, 4, 0, 0, 0x75, 0x47]));
    expect(() => naddrDecode(noIdent)).toThrow();
    expect(() => naddrEncode({ identifier: '', relays: [], author: 'cd'.repeat(32), kind: 1 })).toThrow();
  });
});
