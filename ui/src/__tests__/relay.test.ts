import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { backoffMs, connect } from '../nostr/relay';
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

  it('redials instead of settling on socket close', () => {
    vi.useFakeTimers();
    try {
      const { handle, states, socket } = connectTo();
      socket.open();
      states.length = 0;
      socket.close();
      // A drop is not a verdict: the handle stays on the socket and budgets a redial.
      expect(handle.state()).toBe('connecting');
      expect(states.at(-1)).toMatch(/^connecting:reconnecting in \d+s/);
    } finally {
      vi.useRealTimers();
    }
  });

  it('keeps its state on socket error and lets the close decide', () => {
    vi.useFakeTimers();
    try {
      const { handle, states, socket } = connectTo();
      socket.open();
      states.length = 0;
      socket.onerror?.(new Event('error'));
      // Error is a detail line, never a state: browsers deliver close next,
      // and one drop must schedule exactly one redial.
      expect(handle.state()).toBe('connecting');
      expect(states).toContain('open:socket error');
      expect(states.at(-1)).toMatch(/^connecting:reconnecting in \d+s/);
    } finally {
      vi.useRealTimers();
    }
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

describe('reconnect', () => {
  const policy = { maxAttempts: 2, baseMs: 1000, capMs: 8000 };
  const connectPolicy = () => {
    const states: string[] = [];
    const handle = connect(
      'wss://relay.example',
      {
        onEvent: () => undefined,
        onState: (s, detail) => states.push(detail ? `${s}:${detail}` : s),
      },
      policy,
    );
    return { handle, states, socket: FakeSocket.instances.at(-1)! };
  };

  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('backoffMs doubles per attempt and caps', () => {
    expect(backoffMs(1, policy)).toBe(1000);
    expect(backoffMs(2, policy)).toBe(2000);
    expect(backoffMs(3, policy)).toBe(4000);
    expect(backoffMs(10, policy)).toBe(8000);
  });

  it('redials with backoff after a drop and replays subscriptions', () => {
    const { handle, states, socket } = connectPolicy();
    handle.subscribe('a', { kinds: [1] });
    socket.open();
    socket.close();
    expect(handle.state()).toBe('connecting');
    expect(states.at(-1)).toBe('connecting:reconnecting in 1s (attempt 1/2)');
    expect(FakeSocket.instances).toHaveLength(1);
    vi.advanceTimersByTime(1000);
    expect(FakeSocket.instances).toHaveLength(2);
    const redialed = FakeSocket.instances.at(-1)!;
    redialed.open();
    expect(handle.state()).toBe('open');
    // The dead socket held sub 'a'; the redial re-issues it unprompted.
    expect(redialed.parsed()[0]).toEqual(['REQ', 'a', { kinds: [1] }]);
  });

  it('gives up after the budget and stays down', () => {
    const { handle, socket } = connectPolicy();
    socket.open();
    socket.close();
    vi.advanceTimersByTime(1000);
    const second = FakeSocket.instances.at(-1)!;
    second.close();
    vi.advanceTimersByTime(2000);
    const third = FakeSocket.instances.at(-1)!;
    third.close();
    expect(handle.state()).toBe('closed');
    vi.advanceTimersByTime(60_000);
    expect(FakeSocket.instances).toHaveLength(3);
  });

  it('resets the budget on every open', () => {
    const { handle, socket } = connectPolicy();
    socket.open();
    socket.close();
    vi.advanceTimersByTime(1000);
    const second = FakeSocket.instances.at(-1)!;
    second.open();
    // A later drop gets a full new budget, not the remainder.
    second.close();
    vi.advanceTimersByTime(1000);
    expect(FakeSocket.instances).toHaveLength(3);
    expect(handle.state()).toBe('connecting');
  });

  it('never redials after close()', () => {
    const { handle, socket } = connectPolicy();
    socket.open();
    handle.close();
    expect(handle.state()).toBe('closed');
    vi.advanceTimersByTime(60_000);
    expect(FakeSocket.instances).toHaveLength(1);
  });

  it('reconnect() redials immediately and replays', () => {
    const { handle, socket } = connectPolicy();
    handle.subscribe('a', { kinds: [1] });
    socket.open();
    socket.close();
    handle.reconnect();
    expect(FakeSocket.instances).toHaveLength(2);
    const redialed = FakeSocket.instances.at(-1)!;
    redialed.open();
    expect(handle.state()).toBe('open');
    expect(redialed.parsed()[0]).toEqual(['REQ', 'a', { kinds: [1] }]);
  });

  it('reconnect() is a no-op when open or closed', () => {
    const { handle, socket } = connectPolicy();
    socket.open();
    handle.reconnect();
    expect(FakeSocket.instances).toHaveLength(1);
    handle.close();
    handle.reconnect();
    expect(FakeSocket.instances).toHaveLength(1);
  });

  it('rejects outstanding counts on drop instead of hanging them', async () => {
    const { handle, socket } = connectPolicy();
    socket.open();
    const p = handle.count({ kinds: [1] });
    const assertion = expect(p).rejects.toThrow('connection lost');
    socket.close();
    await assertion;
  });
});

describe('onEose', () => {  it('routes EOSE sub ids to the handler', () => {
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
