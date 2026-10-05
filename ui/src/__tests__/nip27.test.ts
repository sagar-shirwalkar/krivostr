import { describe, it, expect } from 'vitest';
import { schnorr } from '@noble/curves/secp256k1';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils';
import { findMentions, splitSegments, mentionLabel } from '../nostr/nip27';
import { npubEncode, noteEncode, nprofileEncode } from '../nostr/bech32';

const sk1Pub = bytesToHex(schnorr.getPublicKey(hexToBytes('00'.repeat(31) + '01')));
const npub = `nostr:${npubEncode(sk1Pub)}`;
const note = `nostr:${noteEncode('ab'.repeat(32))}`;
const profile = `nostr:${nprofileEncode({ pubkey: 'cd'.repeat(32), relays: ['wss://r.ly'] })}`;

describe('findMentions', () => {
  it('finds npub, note, and profile mentions with spans', () => {
    const ms = findMentions(`hello ${npub} see ${note} by ${profile} bye`);
    expect(ms.map((m) => m.kind.type)).toEqual(['pubkey', 'event', 'profile']);
    expect(ms[0].raw).toBe(npub);
    if (ms[0].kind.type !== 'pubkey') throw new Error('kind drift');
    expect(ms[0].kind.hex).toBe(sk1Pub);
    if (ms[2].kind.type !== 'profile') throw new Error('kind drift');
    expect(ms[2].kind.relays).toEqual(['wss://r.ly']);
  });
  it('skips garbage and finds nothing in plain text', () => {
    expect(findMentions(`a ${npub} b nostr:notbech32! c ${note}`).map((m) => m.kind.type)).toEqual([
      'pubkey',
      'event',
    ]);
    expect(findMentions('just some words')).toEqual([]);
  });
  it('treats nsec as opaque, never decoded', () => {
    const ms = findMentions('x nostr:nsec1vl029mgpspedva04ghmrk0r4p24 Trop');
    for (const m of ms) expect(m.kind.type).not.toBe('pubkey');
  });
});

describe('splitSegments / mentionLabel', () => {
  it('splits text around mentions', () => {
    const segs = splitSegments(`hi ${note} bye`);
    expect(segs).toHaveLength(3);
    expect(segs[0]).toEqual({ text: 'hi ' });
    expect(segs[2]).toEqual({ text: ' bye' });
  });
  it('returns one text segment without mentions', () => {
    expect(splitSegments('plain')).toEqual([{ text: 'plain' }]);
  });
  it('labels mentions compactly', () => {
    const [m] = findMentions(npub);
    expect(mentionLabel(m)).toMatch(/^@[0-9a-f]{4}…[0-9a-f]{4}$/);
  });
});
<<<<<<< HEAD
<<<<<<< HEAD
=======
>>>>>>> 9d5e0b9 (NIP 19 21 57 and ui)

describe('entities', () => {
  it('decodes nevent to its id and naddr to its coordinate', async () => {
    const { neventEncode, naddrEncode } = await import('../nostr/bech32');
    const ev = `nostr:${neventEncode({ id: 'ef'.repeat(32) })}`;
    const ad = `nostr:${naddrEncode({ identifier: 'my-post', author: 'cd'.repeat(32), kind: 30023 })}`;
    const { findMentions } = await import('../nostr/nip27');
    expect(findMentions(`x ${ev}`).map((m) => m.kind)).toEqual([
      { type: 'event', hex: 'ef'.repeat(32) },
    ]);
    expect(findMentions(`x ${ad}`).map((m) => m.kind)).toEqual([
      { type: 'address', coordinate: `30023:${'cd'.repeat(32)}:my-post` },
    ]);
  });
});
<<<<<<< HEAD
=======
>>>>>>> 1c7941b (NIP 09 22 27 36 51)
=======
>>>>>>> 9d5e0b9 (NIP 19 21 57 and ui)
