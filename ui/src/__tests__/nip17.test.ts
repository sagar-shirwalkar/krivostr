import { describe, it, expect } from 'vitest';
import { schnorr } from '@noble/curves/secp256k1';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils';
import { unseal, unwrap } from '../nostr/nip59';
import {
  createChatRumor,
  createFileRumor,
  chatReceivers,
  chatSubject,
  pastTimestamp,
  sealAndWrap,
  dmRelayListTags,
  chatKind,
  fileMessageKind,
  dmRelayListKind,
  twoDaysSeconds,
} from '../nostr/nip17';

const AUTHOR_SK = '0beebd062ec8735f4243466049d7747ef5d6594ee838de147f8aab842b15e273';
const RECIPIENT_SK = 'e108399bd8424357a710b606ae0c13166d853d327e47a6e5e038197346bdbf45';
const WRAPPER_SK = '4f02eac59266002db5801adc5270700ca69d5b8f761d8732fab2fbf233c90cbd';
const pubOf = (sk: string): string => bytesToHex(schnorr.getPublicKey(hexToBytes(sk)));
const RECIPIENT_PUB = pubOf(RECIPIENT_SK);
const OTHER_PUB = pubOf('0101010101010101010101010101010101010101010101010101010101010101');

const ok = <E, A>(r: { _tag: string; value?: A; error?: E }): A => {
  if (r._tag !== 'Ok') throw new Error(`expected Ok, got Err(${(r as { error: E }).error})`);
  return (r as { value: A }).value;
};

const NONCE_A = new Uint8Array(32).fill(0x33);
const NONCE_B = new Uint8Array(32).fill(0x44);

describe('pastTimestamp', () => {
  it('shifts back within the window and clamps outside it', () => {
    expect(pastTimestamp(1000, 100)).toBe(900);
    expect(pastTimestamp(1000, -5)).toBe(1000);
    expect(pastTimestamp(1000000, twoDaysSeconds + 1)).toBe(1000000 - twoDaysSeconds);
  });
});

describe('createChatRumor', () => {
  it('builds kind 14 with p tags as the room and no empty receivers', () => {
    const r = ok(createChatRumor(AUTHOR_SK, 1700000000, [RECIPIENT_PUB, ''], 'hello', 'hi'));
    expect(r.kind).toBe(chatKind);
    expect(r.tags).toEqual([['p', RECIPIENT_PUB], ['subject', 'hello']]);
    expect(chatReceivers(r)).toEqual([RECIPIENT_PUB]);
    expect(chatSubject(r)).toBe('hello');
  });
  it('omits the subject tag when empty', () => {
    const r = ok(createChatRumor(AUTHOR_SK, 1700000000, [RECIPIENT_PUB], '', 'hi'));
    expect(r.tags).toEqual([['p', RECIPIENT_PUB]]);
    expect(chatSubject(r)).toBeUndefined();
  });
});

describe('createFileRumor', () => {
  it('builds kind 15 with file-type and caller tags', () => {
    const r = ok(createFileRumor(AUTHOR_SK, 1700000000, [RECIPIENT_PUB], 'image/png', 'blob', [['x', 'abc']]));
    expect(r.kind).toBe(fileMessageKind);
    expect(r.tags).toContainEqual(['file-type', 'image/png']);
    expect(r.tags).toContainEqual(['x', 'abc']);
  });
});

describe('sealAndWrap', () => {
  it('round-trips seal -> unseal and wrap -> unwrap', () => {
    const rumor = ok(createChatRumor(AUTHOR_SK, 1700000000, [RECIPIENT_PUB, OTHER_PUB], '', 'hello room'));
    const layers = ok(sealAndWrap(AUTHOR_SK, WRAPPER_SK, RECIPIENT_PUB, 1699900000, NONCE_A, 1699800000, NONCE_B, rumor));
    expect(ok(unseal(RECIPIENT_SK, layers.seal))).toEqual(rumor);
    const inner = ok(unwrap(RECIPIENT_SK, layers.wrap));
    expect(inner.id).toBe(layers.seal.id);
  });
  it('the wrap is author-anonymous: signed by the one-time key', () => {
    const rumor = ok(createChatRumor(AUTHOR_SK, 1700000000, [RECIPIENT_PUB], '', 'hi'));
    const layers = ok(sealAndWrap(AUTHOR_SK, WRAPPER_SK, RECIPIENT_PUB, 1699900000, NONCE_A, 1699800000, NONCE_B, rumor));
    expect(layers.wrap.pubkey).toBe(pubOf(WRAPPER_SK));
    expect(layers.wrap.pubkey).not.toBe(pubOf(AUTHOR_SK));
  });
});

describe('dmRelayListTags', () => {
  it('maps relays to r tags and drops empties', () => {
    expect(dmRelayListTags(['wss://a', '', 'wss://b'])).toEqual([['r', 'wss://a'], ['r', 'wss://b']]);
    expect(dmRelayListKind).toBe(10050);
  });
});
