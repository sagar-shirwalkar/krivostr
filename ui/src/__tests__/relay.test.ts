import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { connect } from '../nostr/relay';
import { NostrEvent } from '../nostr/event';

/**
 * Minimal WebSocket stand-in.
 *
 * `relay.ts` assigns `onopen`/`onmessage`/... as properties and calls `send`
 * and `close`, so the fake only has to model those. Tests drive the socket by
 * hand (`open()`, `message()`) instead of waiting on a real network.
 */
class FakeSocket {
  static instances: FakeSocket[] = [];

  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: ((e: unknown) => void) | null = null;
  onmessage: ((m: MessageEvent) => void) | null = null;
  readyState = 0;
  sent: string[] = [];
  closed = false;

  constructor(public url: string) {
    FakeSocket.instances.push(this);
  }

  send(data: string): void {
    this.sent.push(data);
  }

  close(): void {
    this.closed = true;
    this.onclose?.();
  }

  // ── test drivers ──
  open(): void {
    this.readyState = 1;
    this.onopen?.();
  }
  deliver(data: unknown): void {
    this.onmessage?.({ data: JSON.stringify(data) } as MessageEvent);
  }
  deliverRaw(data: string): void {
    this.onmessage?.({ data } as MessageEvent);
  }
  parsed(): unknown[] {
    return this.sent.map((s) => JSON.parse(s) as unknown);
  }
}

// id, pubkey and sig must be real hex: parseEvent enforces it, and a relay
// frame carrying a non-hex pubkey is malformed by definition.
const event = (over: Partial<NostrEvent> = {}): NostrEvent => ({
  id: 'a'.repeat(64),
  pubkey: 'b'.repeat(64),
  created_at: 1000,
  kind: 1,
  tags: [],
  content: 'x',
  sig: 'c'.repeat(128),
  ...over,
});

/** Connect and return the handle plus the socket behind it. */
const connectTo = (url = 'wss://relay.example') => {
  const states: string[] = [];
  const events: NostrEvent[] = [];
  const handle = connect(url, {
    onEvent: (e) => events.push(e),
    onState: (s, detail) => states.push(detail ? `${s}:${detail}` : s),
  });
  return { handle, states, events, socket: FakeSocket.instances.at(-1)! };
};

beforeEach(() => {
  FakeSocket.instances = [];
  vi.stubGlobal('WebSocket', FakeSocket);
});

afterEach(() => vi.unstubAllGlobals());

describe('connect', () => {
  it('starts in connecting state', () => {
    const { handle } = connectTo();
    expect(handle.state()).toBe('connecting');
    expect(handle.url).toBe('wss://relay.example');
  });

  it('reports open once the socket opens', () => {
    const { handle, states, socket } = connectTo();
    socket.open();
    expect(handle.state()).toBe('open');
    expect(states).toContain('open');
  });
});

describe('subscribe', () => {
  it('queues before the socket opens and flushes on open', () => {
    const { handle, socket } = connectTo();
    handle.subscribe('a', { kinds: [1] });
    expect(socket.sent).toHaveLength(0);
    socket.open();
    expect(socket.parsed()[0]).toEqual(['REQ', 'a', { kinds: [1] }]);
  });

  it('sends immediately when already open', () => {
    const { handle, socket } = connectTo();
    socket.open();
    handle.subscribe('b', { kinds: [7], limit: 5 });
    expect(socket.parsed()[0]).toEqual(['REQ', 'b', { kinds: [7], limit: 5 }]);
  });

  it('translates tag filters to the #name wire form', () => {
    const { handle, socket } = connectTo();
    socket.open();
    handle.subscribe('c', { tags: { e: ['x'] } });
    expect(socket.parsed()[0]).toEqual(['REQ', 'c', { '#e': ['x'] }]);
  });
});

describe('incoming frames', () => {
  it('delivers a well-formed EVENT', () => {
    const { socket, events } = connectTo();
    socket.open();
    socket.deliver(['EVENT', 'sub', event()]);
    expect(events).toHaveLength(1);
    expect(events[0].content).toBe('x');
  });

  it('drops a malformed EVENT without reporting a transport failure', () => {
    const { socket, events, states } = connectTo();
    socket.open();
    states.length = 0;
    socket.deliver(['EVENT', 'sub', { id: 'nope' }]);
    expect(events).toHaveLength(0);
    // A bad frame from a relay is not a socket problem.
    expect(states.filter((s) => s.startsWith('error'))).toHaveLength(0);
  });

  it('reports invalid json as an error state', () => {
    const { socket, states } = connectTo();
    socket.open();
    states.length = 0;
    socket.deliverRaw('{not json');
    expect(states[0]).toMatch(/^error:invalid json/);
  });

  it('surfaces NOTICE, EOSE, OK and CLOSED as detail', () => {
    const { socket, states } = connectTo();
    socket.open();
    for (const kind of ['NOTICE', 'EOSE', 'OK', 'CLOSED']) {
      states.length = 0;
      socket.deliver([kind, 'hello']);
      expect(states[0]).toBe(`open:${kind} hello`);
    }
  });

  it('ignores non-array frames', () => {
    const { socket, events, states } = connectTo();
    socket.open();
    states.length = 0;
    socket.deliver({ not: 'an array' });
    socket.deliver('a string');
    expect(events).toHaveLength(0);
    expect(states).toHaveLength(0);
  });
});

describe('publish and close', () => {
  it('publish sends an EVENT frame', () => {
    const { handle, socket } = connectTo();
    socket.open();
    handle.publish(event());
    expect(socket.parsed()[0]).toEqual(['EVENT', event()]);
  });

  it('close revokes every subscription and closes the socket', () => {
    const { socket, handle } = connectTo();
    socket.open();
    handle.subscribe('a', { kinds: [1] });
    handle.subscribe('b', { kinds: [1] });
    handle.close();

    expect(socket.parsed().slice(2)).toEqual([
      ['CLOSE', 'a'],
      ['CLOSE', 'b'],
    ]);
    expect(socket.closed).toBe(true);
    expect(handle.state()).toBe('closed');
  });

  it('close works even before the socket ever opened', () => {
    const { socket, handle } = connectTo();
    expect(() => handle.close()).not.toThrow();
    expect(socket.closed).toBe(true);
  });

  it('reports socket close', () => {
    const { socket, handle } = connectTo();
    socket.open();
    socket.close();
    expect(handle.state()).toBe('closed');
  });

  it('reports socket error', () => {
    const { socket, handle } = connectTo();
    socket.open();
    socket.onerror?.(new Event('error'));
    expect(handle.state()).toBe('error');
  });
});

describe('count', () => {
  it('sends COUNT and resolves the matching answer', async () => {
    const { handle, socket } = connectTo();
    socket.open();
    const p = handle.count({ kinds: [1] });
    expect(socket.parsed()[0]).toEqual(['COUNT', 'count-0', { kinds: [1] }]);
    socket.deliver(['COUNT', 'count-0', { count: 41 }]);
    await expect(p).resolves.toBe(41);
  });

  it('ignores COUNT answers for other ids', async () => {
    const { handle, socket } = connectTo();
    socket.open();
    const p = handle.count({ kinds: [1] });
    socket.deliver(['COUNT', 'count-99', { count: 1 }]);
    socket.deliver(['COUNT', 'count-0', { count: 7 }]);
    await expect(p).resolves.toBe(7);
  });

  it('rejects when nobody answers', async () => {
    vi.useFakeTimers();
    try {
      const { handle, socket } = connectTo();
      socket.open();
      const p = handle.count({ kinds: [1] });
      const assertion = expect(p).rejects.toThrow('COUNT timed out');
      await vi.advanceTimersByTimeAsync(10_000);
      await assertion;
    } finally {
      vi.useRealTimers();
    }
  });
});
<<<<<<< HEAD
<<<<<<< HEAD
=======
>>>>>>> 9d5e0b9 (NIP 19 21 57 and ui)

describe('onEose', () => {
  it('routes EOSE sub ids to the handler', () => {
    const eosed: string[] = [];
    connect('wss://relay.example', {
      onEvent: () => undefined,
      onState: () => undefined,
      onEose: (id) => eosed.push(id),
    });
    const socket = FakeSocket.instances.at(-1)!;
    socket.open();
    socket.deliver(['EOSE', 's1']);
    socket.deliver(['EOSE', 's2']);
    expect(eosed).toEqual(['s1', 's2']);
  });
});
<<<<<<< HEAD

describe('count robustness', () => {
  it('ignores prototype-probe and foreign ids without throwing', async () => {
    const { handle, socket } = connectTo();
    socket.open();
    const p = handle.count({ kinds: [1] });
    expect(() =>
      socket.deliver(['COUNT', '__proto__', { count: 1 }]),
    ).not.toThrow();
    expect(() => socket.deliver(['COUNT', 'constructor', { count: 1 }])).not.toThrow();
    expect(() => socket.deliver(['COUNT', 'count-0', { count: 'many' }])).not.toThrow();
    socket.deliver(['COUNT', 'count-0', { count: 3 }]);
    await expect(p).resolves.toBe(3);
  });

  it('rejects outstanding counts on close', async () => {
    const { handle, socket } = connectTo();
    socket.open();
    const p = handle.count({ kinds: [1] });
    const assertion = expect(p).rejects.toThrow('connection closed');
    handle.close();
    await assertion;
  });
});
=======
>>>>>>> 1c7941b (NIP 09 22 27 36 51)
=======
>>>>>>> 9d5e0b9 (NIP 19 21 57 and ui)
