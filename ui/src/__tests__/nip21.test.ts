import { describe, it, expect } from 'vitest';
import { parseNostrUri, resolveTarget } from '../nostr/nip21';
import { npubEncode, noteEncode, naddrEncode } from '../nostr/bech32';
import { schnorr } from '@noble/curves/secp256k1';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils';

const pub = bytesToHex(schnorr.getPublicKey(hexToBytes('00'.repeat(31) + '01')));
const npubUri = `nostr:${npubEncode(pub)}`;
const noteUri = `nostr:${noteEncode('ab'.repeat(32))}`;
const addrUri = `nostr:${naddrEncode({ identifier: 'my-post', author: 'cd'.repeat(32), kind: 30023 })}`;

describe('parseNostrUri', () => {
  it('parses a lone reference', () => {
    expect(parseNostrUri(npubUri)?.raw).toBe(npubUri);
  });
  it('tolerates surrounding whitespace', () => {
    expect(parseNostrUri(`  ${noteUri}\n`)?.raw).toBe(noteUri);
  });
  it('rejects prose, pairs, and bare text', () => {
    expect(parseNostrUri(`see ${npubUri}`)).toBeUndefined();
    expect(parseNostrUri(`${npubUri} ${noteUri}`)).toBeUndefined();
    expect(parseNostrUri('just words')).toBeUndefined();
    expect(parseNostrUri('')).toBeUndefined();
  });
});

describe('resolveTarget', () => {
  it('maps mentions onto open targets', () => {
    expect(resolveTarget(parseNostrUri(npubUri)!)).toEqual({ view: 'author', pubkey: pub });
    expect(resolveTarget(parseNostrUri(noteUri)!)).toEqual({ view: 'event', id: 'ab'.repeat(32) });
    expect(resolveTarget(parseNostrUri(addrUri)!)).toEqual({
      view: 'address',
      coordinate: `30023:${'cd'.repeat(32)}:my-post`,
    });
  });
  it('opens nothing opaque', async () => {
    const { nsecEncode } = await import('../nostr/bech32');
    const uri = `nostr:${nsecEncode('00'.repeat(32))}`;
    const m = parseNostrUri(uri);
    expect(m?.kind.type).toBe('opaque');
    expect(resolveTarget(m!)).toBeUndefined();
  });
});
