import { describe, it, expect } from 'vitest';
import {
  allMethods,
  methodFromText,
  parseRequest,
  encodeRequest,
  parseResponse,
  encodeResponse,
  authChallengeUrl,
  rejectPayload,
  requestPeer,
  responsePeer,
  requestEventKind,
  nip44Transport,
} from '../nostr/nip46';

describe('methodFromText', () => {
  it('accepts the full spec table and nothing else', () => {
    expect(allMethods).toHaveLength(10);
    for (const m of allMethods) {
      expect(methodFromText(m)).toEqual({ _tag: 'Ok', value: m });
    }
    expect(methodFromText('sign_message')._tag).toBe('Err');
    expect(methodFromText('get_relays')._tag).toBe('Err');
    expect(methodFromText('close')._tag).toBe('Err');
  });
});

describe('request codec', () => {
  it('round-trips a sign_event request', () => {
    const req = { id: 'abc', method: 'sign_event' as const, params: ['{...}'] };
    const back = parseRequest(JSON.parse(encodeRequest(req)) as unknown);
    expect(back).toEqual({ _tag: 'Ok', value: req });
  });
  it('rejects unknown methods and non-string params', () => {
    expect(parseRequest({ id: 'a', method: 'sign_message', params: [] })._tag).toBe('Err');
    expect(parseRequest({ id: 'a', method: 'ping', params: [1] })._tag).toBe('Err');
    expect(parseRequest({ id: 1, method: 'ping', params: [] })._tag).toBe('Err');
  });
});

describe('response codec', () => {
  it('round-trips result and error responses', () => {
    expect(parseResponse(JSON.parse(encodeResponse({ id: 'a', result: 'pong' })) as unknown)).toEqual({
      _tag: 'Ok',
      value: { id: 'a', result: 'pong', error: undefined },
    });
    expect(parseResponse(JSON.parse(encodeResponse({ id: 'a', error: 'nope' })) as unknown)).toEqual({
      _tag: 'Ok',
      value: { id: 'a', result: undefined, error: 'nope' },
    });
  });
  it('extracts the auth_url challenge only when result and error agree', () => {
    expect(authChallengeUrl({ id: 'a', result: 'auth_url', error: 'https://x' })).toBe('https://x');
    expect(authChallengeUrl({ id: 'a', result: 'pong' })).toBeUndefined();
    expect(authChallengeUrl({ id: 'a', result: 'auth_url' })).toBeUndefined();
  });
  it('rejectPayload answers an unknown method with an error', () => {
    const back = parseResponse(JSON.parse(rejectPayload('a', 'unknown NIP-46 method: nope')) as unknown);
    expect(back).toEqual({ _tag: 'Ok', value: { id: 'a', result: undefined, error: 'unknown NIP-46 method: nope' } });
  });
});

describe('peers', () => {
  it('requestPeer reads the p tag, responsePeer the author', () => {
    expect(requestPeer({ tags: [['p', 'abc']] })).toBe('abc');
    expect(requestPeer({ tags: [] })).toBeUndefined();
    expect(responsePeer({ pubkey: 'xyz' })).toBe('xyz');
    expect(requestEventKind).toBe(24133);
  });
});

describe('nip44Transport', () => {
  it('encrypts and decrypts a round trip between two keys', async () => {
    const alice = '0101010101010101010101010101010101010101010101010101010101010101';
    const bob = '0202020202020202020202020202020202020202020202020202020202020202';
    const { schnorr } = await import('@noble/curves/secp256k1');
    const { bytesToHex } = await import('@noble/hashes/utils');
    const { hexToBytes } = await import('@noble/hashes/utils');
    const bobPub = bytesToHex(schnorr.getPublicKey(hexToBytes(bob)));
    const alicePub = bytesToHex(schnorr.getPublicKey(hexToBytes(alice)));
    const aToB = nip44Transport(alice, bobPub);
    const bFromA = nip44Transport(bob, alicePub);
    const cipher = await aToB.encrypt(alice, bobPub, '{"id":"1","method":"ping","params":[]}');
    expect(await bFromA.decrypt(bob, alicePub, cipher)).toBe('{"id":"1","method":"ping","params":[]}');
  });
});
