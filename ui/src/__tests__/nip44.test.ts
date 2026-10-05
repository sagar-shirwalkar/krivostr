import { describe, it, expect } from 'vitest';
import { schnorr } from '@noble/curves/secp256k1';
import { bytesToHex, hexToBytes, utf8ToBytes } from '@noble/hashes/utils';
import {
  conversationKey,
  messageKeys,
  calcPaddedLen,
  pad,
  unpad,
  encryptWithNonce,
  decrypt,
} from '../nostr/nip44';

// sec1/sec2 from the spec's nip44.vectors.json: the scalars 1 and 2.
const SEC1 = '00'.repeat(31) + '01';
const SEC2 = '00'.repeat(31) + '02';
const SEC3 = '00'.repeat(31) + '03';
const pubOf = (sk: string): string => bytesToHex(schnorr.getPublicKey(hexToBytes(sk)));
const SEC2_PUB = pubOf(SEC2);
const SEC1_PUB = pubOf(SEC1);

// The canonical nonce every vector shares: 31 zero bytes then 0x01.
const VECTOR_NONCE = new Uint8Array([...new Array(31).fill(0), 1]);
const ALT_NONCE = new Uint8Array(new Array(32).fill(1));

const EXPECTED_CONV_KEY = 'c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d';

// The canonical single-character vector's payload, transcribed from the spec.
const CANONICAL_PAYLOAD =
  'AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb';

const ok = <E, A>(r: { _tag: string; value?: A; error?: E }): A => {
  if (r._tag !== 'Ok') throw new Error(`expected Ok, got Err(${(r as { error: E }).error})`);
  return (r as { value: A }).value;
};

describe('conversationKey', () => {
  it('matches the published vector', () => {
    expect(bytesToHex(ok(conversationKey(SEC1, SEC2_PUB)))).toBe(EXPECTED_CONV_KEY);
  });
  it('is symmetric', () => {
    expect(bytesToHex(ok(conversationKey(SEC1, SEC2_PUB)))).toBe(bytesToHex(ok(conversationKey(SEC2, SEC1_PUB))));
  });
  it('rejects a pubkey that is not on the curve', () => {
    expect(conversationKey(SEC1, '00'.repeat(32))._tag).toBe('Err');
  });
  it('rejects a pubkey that is not 32 bytes', () => {
    expect(conversationKey(SEC1, 'abcd')._tag).toBe('Err');
  });
});

describe('padding', () => {
  it('floors at 32 and grows in 32s to 256', () => {
    expect([1, 16, 32].map(calcPaddedLen)).toEqual([32, 32, 32]);
    expect(calcPaddedLen(33)).toBe(64);
    expect(calcPaddedLen(64)).toBe(64);
    expect(calcPaddedLen(65)).toBe(96);
    expect(calcPaddedLen(257)).toBe(320);
  });
  it('round-trips through pad and unpad', () => {
    for (const n of [1, 31, 32, 33, 255, 256, 1000]) {
      const plain = new Uint8Array(n).fill(0x61);
      const padded = ok(pad(plain));
      const prefix = n < 65536 ? 2 : 6;
      expect(padded.length).toBe(prefix + calcPaddedLen(n));
      expect(ok(unpad(padded))).toEqual(plain);
    }
  });
  it('refuses empty plaintext and mangled padding', () => {
    expect(pad(new Uint8Array(0))._tag).toBe('Err');
    const padded = ok(pad(utf8ToBytes('a')));
    expect(unpad(padded.subarray(0, padded.length - 1))._tag).toBe('Err');
    expect(unpad(new Uint8Array(34))._tag).toBe('Err');
  });
});

describe('messageKeys', () => {
  it('slices 76 bytes into 32 + 12 + 32', () => {
    const keys = ok(messageKeys(hexToBytes(EXPECTED_CONV_KEY), VECTOR_NONCE));
    expect(keys.chachaKey.length).toBe(32);
    expect(keys.chachaNonce.length).toBe(12);
    expect(keys.hmacKey.length).toBe(32);
  });
  it('rejects wrong-size inputs and derives per-nonce keys', () => {
    const ck = hexToBytes(EXPECTED_CONV_KEY);
    expect(messageKeys(new Uint8Array(31).fill(1), VECTOR_NONCE)._tag).toBe('Err');
    expect(messageKeys(ck, new Uint8Array(31).fill(1))._tag).toBe('Err');
    const a = ok(messageKeys(ck, VECTOR_NONCE));
    const b = ok(messageKeys(ck, ALT_NONCE));
    expect(a.chachaKey).not.toEqual(b.chachaKey);
  });
});

describe('payload', () => {
  it('encrypts the canonical vector byte for byte', () => {
    expect(ok(encryptWithNonce(SEC1, SEC2_PUB, VECTOR_NONCE, utf8ToBytes('a')))).toBe(CANONICAL_PAYLOAD);
  });
  it('decrypts the canonical payload back to its plaintext', () => {
    expect(ok(decrypt(SEC2, SEC1_PUB, CANONICAL_PAYLOAD))).toEqual(utf8ToBytes('a'));
  });
  it('emits the 0x02 version byte', () => {
    expect(ok(encryptWithNonce(SEC1, SEC2_PUB, VECTOR_NONCE, utf8ToBytes('a'))).startsWith('AgAA')).toBe(true);
  });
  it('is deterministic per nonce and differs across nonces', () => {
    const a = ok(encryptWithNonce(SEC1, SEC2_PUB, VECTOR_NONCE, utf8ToBytes('hello nostr')));
    const b = ok(encryptWithNonce(SEC1, SEC2_PUB, VECTOR_NONCE, utf8ToBytes('hello nostr')));
    expect(a).toBe(b);
    expect(ok(encryptWithNonce(SEC1, SEC2_PUB, ALT_NONCE, utf8ToBytes('hello nostr')))).not.toBe(a);
  });
  it('round-trips across plaintext lengths', () => {
    for (const n of [1, 32, 33, 255, 256, 1000]) {
      const plain = new Uint8Array(n).fill(0x61);
      const payload = ok(encryptWithNonce(SEC1, SEC2_PUB, VECTOR_NONCE, plain));
      expect(ok(decrypt(SEC2, SEC1_PUB, payload))).toEqual(plain);
    }
  });
});

describe('rejects malformed payloads', () => {
  it('refuses an oversized payload before decoding', () => {
    expect(decrypt(SEC2, SEC2_PUB, 'A'.repeat(1024 * 1024 + 1))._tag).toBe('Err');
  });
  it('refuses a future version marker and short payloads', () => {
    expect(decrypt(SEC2, SEC2_PUB, '#somefutureversion')._tag).toBe('Err');
    expect(decrypt(SEC2, SEC2_PUB, 'QUJD')._tag).toBe('Err');
  });
  it('refuses tampered ciphertext and wrong-key reads', () => {
    expect(decrypt(SEC2, SEC1_PUB, CANONICAL_PAYLOAD.replace('ee0G5', 'ff0G5'))._tag).toBe('Err');
    expect(decrypt(SEC3, SEC1_PUB, CANONICAL_PAYLOAD)._tag).toBe('Err');
  });
});
