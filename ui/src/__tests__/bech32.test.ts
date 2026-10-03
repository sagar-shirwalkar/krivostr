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
