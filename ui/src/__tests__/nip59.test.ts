import { describe, it, expect } from 'vitest';
import { schnorr } from '@noble/curves/secp256k1';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils';
import { NostrEvent } from '../nostr/event';
import {
  Rumor,
  createRumor,
  seal,
  unseal,
  wrap,
  wrapEphemeral,
  unwrap,
  isSeal,
  isWrap,
  isEphemeralWrap,
  wrapRecipient,
  sealKind,
  wrapKind,
  ephemeralWrapKind,
} from '../nostr/nip59';

// The spec's worked example: keys, rumor, and seal, transcribed from NIP-59.
const AUTHOR_SK = '0beebd062ec8735f4243466049d7747ef5d6594ee838de147f8aab842b15e273';
const RECIPIENT_SK = 'e108399bd8424357a710b606ae0c13166d853d327e47a6e5e038197346bdbf45';
const WRAPPER_SK = '4f02eac59266002db5801adc5270700ca69d5b8f761d8732fab2fbf233c90cbd';
const pubOf = (sk: string): string => bytesToHex(schnorr.getPublicKey(hexToBytes(sk)));
const AUTHOR_PUB = pubOf(AUTHOR_SK);
const RECIPIENT_PUB = pubOf(RECIPIENT_SK);

const SPEC_SEAL_CONTENT =
  'AqBCdwoS7/tPK+QGkPCadJTn8FxGkd24iApo3BR9/M0uw6n4RFAFSPAKKMgkzVMoRyR3ZS/aqATDFvoZJOkE9cPG/TAzmyZv' +
  'r/WUIS8kLmuI1dCA+itFF6+ULZqbkWS0YcVU0j6UDvMBvVlGTzHz+UHzWYJLUq2LnlynJtFap5k8560+tBGtxi9Gx2NIycKg' +
  'bOUv0gEqhfVzAwvg1IhTltfSwOeZXvDvd40rozONRxwq8hjKy+4DbfrO0iRtlT7G/eVEO9aJJnqagomFSkqCscttf/o6VeT2' +
  '+A9JhcSxLmjcKFG3FEK3Try/WkarJa1jM3lMRQqVOZrzHAaLFW/5sXano6DqqC5ERD6CcVVsrny0tYN4iHHB8BHJ9zvjff0N' +
  'jLGG/v5Wsy31+BwZA8cUlfAZ0f5EYRo9/vKSd8TV0wRb9DQ=';

const SPEC_SEAL: NostrEvent = {
  id: '28a87d7c074d94a58e9e89bb3e9e4e813e2189f285d797b1c56069d36f59eaa7',
  pubkey: '611df01bfcf85c26ae65453b772d8f1dfd25c264621c0277e1fc1518686faef9',
  created_at: 1703015180,
  kind: 13,
  tags: [],
  content: SPEC_SEAL_CONTENT,
  sig: '02fc3facf6621196c32912b1ef53bac8f8bfe9db51c0e7102c073103586b0d29c3f39bdaa1e62856c20e90b6c7cc5dc34ca8bb6a528872cf6e65e6284519ad73',
};

const SPEC_RUMOR: Rumor = {
  id: '9dd003c6d3b73b74a85a9ab099469ce251653a7af76f523671ab828acd2a0ef9',
  pubkey: '611df01bfcf85c26ae65453b772d8f1dfd25c264621c0277e1fc1518686faef9',
  created_at: 1691518405,
  kind: 1,
  tags: [],
  content: 'Are you going to the party tonight?',
};

const ok = <E, A>(r: { _tag: string; value?: A; error?: E }): A => {
  if (r._tag !== 'Ok') throw new Error(`expected Ok, got Err(${(r as { error: E }).error})`);
  return (r as { value: A }).value;
};

const NONCE_A = new Uint8Array(32).fill(0x11);
const NONCE_B = new Uint8Array(32).fill(0x22);

describe('unseal against the spec example', () => {
  it('opens the published seal to the published rumor', () => {
    expect(ok(unseal(RECIPIENT_SK, SPEC_SEAL))).toEqual(SPEC_RUMOR);
  });
  it('the spec author key matches the seal author', () => {
    expect(AUTHOR_PUB).toBe(SPEC_SEAL.pubkey);
  });
  it('refuses the wrong kind, forged tags, and wrong recipient', () => {
    expect(unseal(RECIPIENT_SK, { ...SPEC_SEAL, kind: 1 })._tag).toBe('Err');
    expect(unseal(RECIPIENT_SK, { ...SPEC_SEAL, tags: [['p', 'x']] })._tag).toBe('Err');
    expect(unseal(WRAPPER_SK, SPEC_SEAL)._tag).toBe('Err');
  });
});

describe('seal and wrap round-trip', () => {
  it('seal -> unseal recovers the rumor', () => {
    const rumor = ok(createRumor(AUTHOR_SK, { pubkey: '', created_at: 1700000000, kind: 1, tags: [], content: 'hi' }));
    expect(rumor.id).toMatch(/^[0-9a-f]{64}$/);
    const s = ok(seal(AUTHOR_SK, RECIPIENT_PUB, 1700000100, NONCE_A, rumor));
    expect(s.kind).toBe(sealKind);
    expect(s.tags).toEqual([]);
    expect(ok(unseal(RECIPIENT_SK, s))).toEqual(rumor);
  });
  it('wrap -> unwrap recovers the seal, addressed to exactly one recipient', () => {
    const rumor = ok(createRumor(AUTHOR_SK, { pubkey: '', created_at: 1700000000, kind: 1, tags: [], content: 'hi' }));
    const s = ok(seal(AUTHOR_SK, RECIPIENT_PUB, 1700000100, NONCE_A, rumor));
    const w = ok(wrap(WRAPPER_SK, RECIPIENT_PUB, 1700000200, NONCE_B, s));
    expect(w.kind).toBe(wrapKind);
    expect(wrapRecipient(w)).toBe(RECIPIENT_PUB);
    expect(ok(unwrap(RECIPIENT_SK, w))).toEqual(s);
  });
  it('the wrap leaks nothing: no author, no content, no inner kind', () => {
    const rumor = ok(createRumor(AUTHOR_SK, { pubkey: '', created_at: 1700000000, kind: 1, tags: [], content: 'secret' }));
    const s = ok(seal(AUTHOR_SK, RECIPIENT_PUB, 1700000100, NONCE_A, rumor));
    const w = ok(wrap(WRAPPER_SK, RECIPIENT_PUB, 1700000200, NONCE_B, s));
    expect(w.pubkey).not.toBe(AUTHOR_PUB);
    expect(w.content).not.toContain('secret');
    expect(isSeal(w)).toBe(false);
    expect(isWrap(w)).toBe(true);
    expect(isEphemeralWrap(w)).toBe(false);
  });
  it('ephemeral wraps carry the ephemeral kind', () => {
    const rumor = ok(createRumor(AUTHOR_SK, { pubkey: '', created_at: 1700000000, kind: 1, tags: [], content: 'live' }));
    const s = ok(seal(AUTHOR_SK, RECIPIENT_PUB, 1700000100, NONCE_A, rumor));
    const w = ok(wrapEphemeral(WRAPPER_SK, RECIPIENT_PUB, 1700000200, NONCE_B, s));
    expect(w.kind).toBe(ephemeralWrapKind);
    expect(isEphemeralWrap(w)).toBe(true);
    expect(ok(unwrap(RECIPIENT_SK, w))).toEqual(s);
  });
  it('wrapRecipient is undefined for zero or several p tags', () => {
    const rumor = ok(createRumor(AUTHOR_SK, { pubkey: '', created_at: 1700000000, kind: 1, tags: [], content: 'x' }));
    const s = ok(seal(AUTHOR_SK, RECIPIENT_PUB, 1700000100, NONCE_A, rumor));
    const w = ok(wrap(WRAPPER_SK, RECIPIENT_PUB, 1700000200, NONCE_B, s));
    expect(wrapRecipient({ ...w, tags: [] })).toBeUndefined();
    expect(wrapRecipient({ ...w, tags: [['p', 'a'], ['p', 'b']] })).toBeUndefined();
  });
});
