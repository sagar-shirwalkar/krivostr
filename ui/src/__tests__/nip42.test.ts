import { describe, it, expect } from 'vitest';
import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils';
import { NostrEvent, canonicalBytes } from '../nostr/event';
import {
  buildAuthUnsigned,
  authEventRelay,
  authEventChallenge,
  validateAuthEvent,
  authRequiredNotice,
  parseAuthChallenge,
} from '../nostr/nip42';

const ev = (over: Partial<NostrEvent> = {}): NostrEvent => ({
  id: 'a'.repeat(64), pubkey: 'p'.repeat(64), created_at: 1000,
  kind: 22242, tags: [['relay', 'wss://r'], ['challenge', 'c']], content: '', sig: 's'.repeat(128),
  ...over,
});

/** Sign an AUTH event with a fixed key, mirroring the Haskell builder. */
const signAuth = (skHex: string, relay: string, challenge: string, now: number): NostrEvent => {
  const u = buildAuthUnsigned(relay, challenge, now, bytesToHex(schnorr.getPublicKey(hexToBytes(skHex))));
  const id = bytesToHex(sha256(canonicalBytes(u)));
  const sig = bytesToHex(schnorr.sign(id, hexToBytes(skHex)));
  return { ...u, id, sig };
};

const SK = '0101010101010101010101010101010101010101010101010101010101010101';

describe('buildAuthUnsigned', () => {
  it('builds kind 22242 with relay and challenge tags', () => {
    const u = buildAuthUnsigned('wss://r', 'c', 1000, 'p'.repeat(64));
    expect(u.kind).toBe(22242);
    expect(u.tags).toEqual([['relay', 'wss://r'], ['challenge', 'c']]);
    expect(u.content).toBe('');
  });
});

describe('tag accessors', () => {
  it('extract relay and challenge', () => {
    expect(authEventRelay(ev())).toEqual({ _tag: 'Ok', value: 'wss://r' });
    expect(authEventChallenge(ev())).toEqual({ _tag: 'Ok', value: 'c' });
  });
  it('reject missing and empty tags', () => {
    expect(authEventRelay(ev({ tags: [] }))._tag).toBe('Err');
    expect(authEventChallenge(ev({ tags: [['relay', 'wss://r'], ['challenge', '']] }))._tag).toBe('Err');
  });
});

describe('validateAuthEvent', () => {
  it('accepts a fresh, correctly signed event', () => {
    const e = signAuth(SK, 'wss://r', 'c', 1000);
    expect(validateAuthEvent('wss://r', 'c', 1005, 600, e)).toEqual({ _tag: 'Ok', value: undefined });
  });
  it('rejects wrong kind, relay, challenge', () => {
    const e = signAuth(SK, 'wss://r', 'c', 1000);
    expect(validateAuthEvent('wss://r', 'c', 1005, 600, { ...e, kind: 1 })._tag).toBe('Err');
    expect(validateAuthEvent('wss://other', 'c', 1005, 600, e)._tag).toBe('Err');
    expect(validateAuthEvent('wss://r', 'other', 1005, 600, e)._tag).toBe('Err');
  });
  it('rejects old and future-dated events', () => {
    const e = signAuth(SK, 'wss://r', 'c', 1000);
    expect(validateAuthEvent('wss://r', 'c', 1000 + 601, 600, e)._tag).toBe('Err');
    const future = signAuth(SK, 'wss://r', 'c', 2000);
    expect(validateAuthEvent('wss://r', 'c', 1000, 600, future)._tag).toBe('Err');
  });
  it('rejects a tampered signature', () => {
    const e = signAuth(SK, 'wss://r', 'c', 1000);
    expect(validateAuthEvent('wss://r', 'c', 1005, 600, { ...e, sig: '0'.repeat(128) })._tag).toBe('Err');
  });
});

describe('notices and challenges', () => {
  it('formats the auth-required prefix', () => {
    expect(authRequiredNotice('why')).toBe('auth-required: why');
  });
  it('parses an AUTH challenge frame', () => {
    expect(parseAuthChallenge(['AUTH', 'abc'])).toBe('abc');
    expect(parseAuthChallenge(['EVENT', 'x'])).toBeUndefined();
    expect(parseAuthChallenge(['AUTH'])).toBeUndefined();
  });
});
