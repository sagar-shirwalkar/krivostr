import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  localSigner, nip07Signer, nip46Signer, isNip07Available, parseBunkerUrl, publish,
} from '../nostr/signer';
import { Ok } from '../fp/result';

const NSEC_HEX = '0000000000000000000000000000000000000000000000000000000000000001';

describe('localSigner', () => {
  it('derives a pubkey', async () => {
    const s = localSigner(NSEC_HEX);
    const pk = await s.pubkey();
    expect(pk._tag).toBe('Ok');
    if (pk._tag === 'Ok') expect(pk.value).toHaveLength(64);
  });

  it('signs a well-formed event', async () => {
    const s = localSigner(NSEC_HEX);
    const pk = await s.pubkey();
    if (pk._tag !== 'Ok') throw new Error('pubkey failed');
    const r = await s.signEvent({
      pubkey: pk.value,
      created_at: 1700000000,
      kind: 1,
      tags: [],
      content: 'hi',
    });
    expect(r._tag).toBe('Ok');
    if (r._tag === 'Ok') {
      expect(r.value.id).toHaveLength(64);
      expect(r.value.sig).toHaveLength(128);
    }
  });
});

describe('nip07Signer', () => {
  const unsigned = {
    pubkey: 'b'.repeat(64),
    created_at: 1000,
    kind: 1,
    tags: [] as string[][],
    content: 'hello',
  };
  const provider = (getPublicKey: () => Promise<string>, signEvent: (e: unknown) => unknown) => {
    vi.stubGlobal('window', { nostr: { getPublicKey, signEvent } });
  };

  beforeEach(() => {
    vi.unstubAllGlobals();
  });

  // The stubbed window leaked into later suites until this was added.
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('returns Err when no provider', async () => {
    expect(isNip07Available()).toBe(false);
    const s = nip07Signer();
    expect((await s.pubkey())._tag).toBe('Err');
    expect((await s.signEvent(unsigned))._tag).toBe('Err');
  });

  it('delegates to window.nostr when present', async () => {
    provider(
      async () => 'pk',
      async (e: unknown) => ({ ...(e as object), id: 'x', sig: 'y' }),
    );
    expect(isNip07Available()).toBe(true);
    const s = nip07Signer();
    const r = await s.pubkey();
    expect(r).toEqual(Ok('pk'));
  });

  it('returns the event the provider signed', async () => {
    const signed = { ...unsigned, id: 'a'.repeat(64), sig: 'c'.repeat(128) };
    provider(async () => 'b'.repeat(64), async () => signed);

    const r = await nip07Signer().signEvent(unsigned);
    expect(r._tag).toBe('Ok');
    if (r._tag === 'Ok') expect(r.value.sig).toBe('c'.repeat(128));
  });

  it('surfaces a provider that rejects', async () => {
    provider(
      async () => {
        throw new Error('locked');
      },
      async () => {
        throw new Error('locked');
      },
    );
    const s = nip07Signer();
    expect((await s.pubkey())._tag).toBe('Err');
    expect((await s.signEvent(unsigned))._tag).toBe('Err');
  });
});

describe('parseBunkerUrl', () => {
  it('parses valid bunker URLs', () => {
    const r = parseBunkerUrl('bunker://abc?relay=wss%3A%2F%2Fr');
    expect(r._tag).toBe('Ok');
    if (r._tag === 'Ok') {
      expect(r.value.remotePubkey).toBe('abc');
      expect(r.value.relay).toBe('wss://r');
    }
  });
  it('rejects missing relay', () => {
    expect(parseBunkerUrl('bunker://abc')._tag).toBe('Err');
  });
  it('rejects wrong scheme', () => {
    expect(parseBunkerUrl('https://abc?relay=x')._tag).toBe('Err');
  });
});

describe('publish boundary', () => {
  it('signs then publishes', async () => {
    const signer = localSigner(NSEC_HEX);
    const published: unknown[] = [];
    const relay = {
      url: 'x',
      state: () => 'open' as const,
      subscribe: () => undefined,
      unsubscribe: () => undefined,
      publish: (e: unknown) => published.push(e),
      close: () => undefined,
    };
    const pk = await signer.pubkey();
    if (pk._tag !== 'Ok') throw new Error();
    const r = await publish(signer, relay, {
      pubkey: pk.value,
      created_at: 0,
      kind: 1,
      tags: [],
      content: 'hello',
    });
    expect(r._tag).toBe('Ok');
    expect(published).toHaveLength(1);
  });
});

// ── NIP-46 ──────────────────────────────────────────────────────────────

/**
 * WebSocket stand-in for the bunker connection.
 *
 * Everything goes through `send`, which is what `relay.ts` actually calls. When
 * `onReply` is set, an outgoing EVENT is answered *synchronously*, before
 * `send` returns: a bunker that replies faster than the caller can return. The
 * signer has to have registered its waiter before publishing, or the reply
 * arrives with nothing listening and is dropped.
 */
class BunkerSocket {
  static last: BunkerSocket | null = null;
  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: ((e: unknown) => void) | null = null;
  onmessage: ((m: MessageEvent) => void) | null = null;
  readyState = 0;
  frames: unknown[] = [];
  onReply: ((frame: unknown) => void) | null = null;

  constructor(public url: string) {
    BunkerSocket.last = this;
  }

  send(data: string): void {
    const frame = JSON.parse(data) as unknown[];
    this.frames.push(frame);
    if (frame[0] === 'EVENT') this.onReply?.(frame);
  }

  close(): void {}

  /** Flush whatever the handle queued while the socket was still connecting. */
  open(): void {
    this.readyState = 1;
    this.onopen?.();
  }

  /** Deliver a kind-24133 reply carrying `payload` back to the signer. */
  answer(payload: Record<string, unknown>): void {
    this.onmessage?.({
      data: JSON.stringify([
        'EVENT',
        'nip46',
        {
          id: 'd'.repeat(64),
          pubkey: CFG.remotePubkey,
          created_at: 2000,
          kind: 24133,
          tags: [],
          content: `enc:${JSON.stringify(payload)}`,
          sig: 'c'.repeat(128),
        },
      ]),
    } as MessageEvent);
  }
}

const CFG = { remotePubkey: 'b'.repeat(64), relay: 'wss://bunker.example' };
const IDENTITY =
  '0000000000000000000000000000000000000000000000000000000000000001';

/** Trivial reversible stand-in for NIP-04 so the test can read plaintext. */
const NIP04 = {
  encrypt: async (_sk: string, _pk: string, plain: string) => `enc:${plain}`,
  decrypt: async (_sk: string, _pk: string, cipher: string) =>
    cipher.startsWith('enc:') ? cipher.slice(4) : Promise.reject(new Error('bad')),
};

/** Read the request id out of an encrypted outbound EVENT frame. */
const requestIdOf = (frame: unknown): string => {
  const ev = (frame as [string, { content: string }])[1];
  const plain = ev.content.slice('enc:'.length);
  return (JSON.parse(plain) as { id: string }).id;
};

describe('nip46Signer', () => {
  beforeEach(() => {
    BunkerSocket.last = null;
    vi.stubGlobal('WebSocket', BunkerSocket);
  });
  afterEach(() => vi.unstubAllGlobals());

  it('subscribes to kind 24133 from the remote pubkey', async () => {
    await nip46Signer(CFG, IDENTITY, NIP04);
    // The REQ is queued until the socket opens.
    expect(BunkerSocket.last!.frames).toHaveLength(0);
    BunkerSocket.last!.open();
    expect(BunkerSocket.last!.frames[0]).toEqual([
      'REQ',
      'nip46',
      { kinds: [24133], authors: [CFG.remotePubkey] },
    ]);
  });

  it('answers a bunker that replies before publish returns', async () => {
    const s = await nip46Signer(CFG, IDENTITY, NIP04);
    BunkerSocket.last!.open();
    BunkerSocket.last!.onReply = (frame) =>
      BunkerSocket.last!.answer({ id: requestIdOf(frame), result: 'f'.repeat(64) });

    // No await between the request and the reply: if the signer registered its
    // waiter after publishing, this promise would sit until the 30s timeout.
    expect(await s.pubkey()).toEqual(Ok('f'.repeat(64)));
  });

  it('signs an event via the bunker', async () => {
    const s = await nip46Signer(CFG, IDENTITY, NIP04);
    const target = {
      pubkey: 'f'.repeat(64),
      created_at: 1,
      kind: 1,
      tags: [] as string[][],
      content: 'x',
    };
    const signed = { ...target, id: 'a'.repeat(64), sig: 'c'.repeat(128) };
    BunkerSocket.last!.open();
    BunkerSocket.last!.onReply = (frame) =>
      BunkerSocket.last!.answer({
        id: requestIdOf(frame),
        result: JSON.stringify(signed),
      });

    const r = await s.signEvent(target);
    expect(r._tag).toBe('Ok');
    if (r._tag === 'Ok') expect(r.value.sig).toBe('c'.repeat(128));
  });

  it('reports an error result from the bunker', async () => {
    const s = await nip46Signer(CFG, IDENTITY, NIP04);
    BunkerSocket.last!.open();
    BunkerSocket.last!.onReply = (frame) =>
      BunkerSocket.last!.answer({ id: requestIdOf(frame), error: 'denied' });

    expect((await s.pubkey())._tag).toBe('Err');
  });

  it('ignores replies that are not from the remote pubkey', async () => {
    const s = await nip46Signer(CFG, IDENTITY, NIP04);
    const stranger = CFG.remotePubkey.replace(/^b/, 'a');
    BunkerSocket.last!.open();
    BunkerSocket.last!.onReply = (frame) => {
      const socket = BunkerSocket.last!;
      socket.onmessage?.({
        data: JSON.stringify([
          'EVENT',
          'nip46',
          {
            id: 'd'.repeat(64),
            pubkey: stranger,
            created_at: 2000,
            kind: 24133,
            tags: [],
            content: `enc:${JSON.stringify({ id: requestIdOf(frame), result: 'x' })}`,
            sig: 'c'.repeat(128),
          },
        ]),
      } as MessageEvent);
    };

    // Still waiting: the reply was correctly discarded.
    const settled = await Promise.race([
      s.pubkey(),
      new Promise((r) => setTimeout(() => r('pending'), 50)),
    ]);
    expect(settled).toBe('pending');
  });
});
