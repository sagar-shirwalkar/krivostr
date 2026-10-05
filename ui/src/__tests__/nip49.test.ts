import { describe, it, expect } from 'vitest';
import { encryptNcryptsec, decryptNcryptsec } from '../nostr/nip49';

// The spec's Test Data vector: password "nostr", log_n = 16.
const VECTOR_PASSWORD = 'nostr';
const VECTOR_PAYLOAD =
  'ncryptsec1qgg9947rlpvqu76pj5ecreduf9jxhselq2nae2kghhvd5g7dgjtcxfqtd67p9m0w57lspw8gsq6yphnm8623nsl8xn9j4jdzz84zm3frztj3z7s35vpzmqf6ksu8r89qk5z2zxfmu5gv8th8wclt0h4p';
const VECTOR_SECRET = '3501454135014541350145413501453fefb02227e449e57cf4d3a3ce05378683';

const CHEAP_LOG_N = 8;
const SALT = new Uint8Array(16).fill(0x5a);
const NONCE = new Uint8Array(24).fill(0x2b);
const SK = '0101010101010101010101010101010101010101010101010101010101010101';

const ok = <E, A>(r: { _tag: string; value?: A; error?: E }): A => {
  if (r._tag !== 'Ok') throw new Error(`expected Ok, got Err(${(r as { error: E }).error})`);
  return (r as { value: A }).value;
};

describe('decryptNcryptsec', () => {
  it('decrypts the spec vector', () => {
    const r = ok(decryptNcryptsec(VECTOR_PAYLOAD, VECTOR_PASSWORD));
    expect(r.seckeyHex).toBe(VECTOR_SECRET);
    expect(r.logN).toBe(16);
    expect(r.keySecurity).toBe('insecure');
  });
  it('rejects the wrong password', () => {
    expect(decryptNcryptsec(VECTOR_PAYLOAD, 'wrong')._tag).toBe('Err');
  });
  it('rejects a tampered ciphertext', () => {
    const tampered = VECTOR_PAYLOAD.slice(0, 60) + (VECTOR_PAYLOAD[60] === 'q' ? 'p' : 'q') + VECTOR_PAYLOAD.slice(61);
    expect(decryptNcryptsec(tampered, VECTOR_PASSWORD)._tag).toBe('Err');
  });
  it('rejects the wrong hrp, oversized input, and garbage', () => {
    expect(decryptNcryptsec('nsec1' + VECTOR_PAYLOAD.slice(9), VECTOR_PASSWORD)._tag).toBe('Err');
    expect(decryptNcryptsec('x'.repeat(1025), VECTOR_PASSWORD)._tag).toBe('Err');
    expect(decryptNcryptsec('not bech32 at all!', VECTOR_PASSWORD)._tag).toBe('Err');
  });
});

describe('encryptNcryptsec round-trip', () => {
  it('encrypts and decrypts under cheap parameters', () => {
    const payload = ok(encryptNcryptsec(SK, 'correct horse', CHEAP_LOG_N, 'secure', SALT, NONCE));
    expect(payload.startsWith('ncryptsec1')).toBe(true);
    const back = ok(decryptNcryptsec(payload, 'correct horse'));
    expect(back.seckeyHex).toBe(SK);
    expect(back.logN).toBe(CHEAP_LOG_N);
    expect(back.keySecurity).toBe('secure');
  });
  it('is deterministic for fixed salt and nonce', () => {
    const a = ok(encryptNcryptsec(SK, 'pw', CHEAP_LOG_N, 'untracked', SALT, NONCE));
    const b = ok(encryptNcryptsec(SK, 'pw', CHEAP_LOG_N, 'untracked', SALT, NONCE));
    expect(a).toBe(b);
  });
  it('refuses bad inputs without deriving a key', () => {
    expect(encryptNcryptsec('zzzz', 'pw', CHEAP_LOG_N, 'secure', SALT, NONCE)._tag).toBe('Err');
    expect(encryptNcryptsec(SK, 'pw', CHEAP_LOG_N, 'secure', SALT, new Uint8Array(8))._tag).toBe('Err');
    expect(encryptNcryptsec(SK, 'pw', 99, 'secure', SALT, NONCE)._tag).toBe('Err');
  });
});
