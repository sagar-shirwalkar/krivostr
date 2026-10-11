import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { connectBridge } from '../nostr/bridge';

/**
 * Minimal WebSocket stand-in, mirroring relay.test.ts: `bridge.ts` assigns
 * `onopen`/`onclose`/`onerror`/`onmessage` as properties and calls `send`
 * and `close`, so tests drive the socket by hand.
 */
class FakeSocket {
  static instances: FakeSocket[] = [];

  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: ((e: unknown) => void) | null = null;
  onmessage: ((m: { data: string }) => void) | null = null;
  sent: string[] = [];

  constructor(public url: string) {
    FakeSocket.instances.push(this);
  }

  send(data: string): void {
    this.sent.push(data);
  }

  close(): void {
    this.onclose?.();
  }

  // ── test drivers ──
  open(): void {
    this.onopen?.();
  }

  parsed(): unknown[] {
    return this.sent.map((s) => JSON.parse(s) as unknown);
  }
}

const policy = { maxAttempts: 2, baseMs: 1000, capMs: 8000 };

const connectPolicy = () => {
  const states: string[] = [];
  const handle = connectBridge(
    {
      onEvent: () => undefined,
      onState: (s, detail) => states.push(detail ? `${s}:${detail}` : s),
    },
    policy,
  );
  return { handle, states, socket: FakeSocket.instances.at(-1)! };
};

beforeEach(() => {
  FakeSocket.instances = [];
  vi.stubGlobal('WebSocket', FakeSocket);
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe('connectBridge reconnect', () => {
  it('redials with backoff after a drop and replays subscriptions', () => {
    const { handle, states, socket } = connectPolicy();
    handle.subscribe('global', { kinds: [1], limit: 50 });
    socket.open();
    socket.close();
    expect(handle.state()).toBe('connecting');
    expect(states.at(-1)).toBe('connecting:reconnecting in 1s (attempt 1/2)');
    vi.advanceTimersByTime(1000);
    const redialed = FakeSocket.instances.at(-1)!;
    redialed.open();
    expect(handle.state()).toBe('open');
    expect(redialed.parsed()[0]).toEqual(['REQ', 'global', { kinds: [1], limit: 50 }]);
  });

  it('gives up after the budget and stays down', () => {
    const { handle, socket } = connectPolicy();
    socket.open();
    socket.close();
    vi.advanceTimersByTime(1000);
    FakeSocket.instances.at(-1)!.close();
    vi.advanceTimersByTime(2000);
    FakeSocket.instances.at(-1)!.close();
    expect(handle.state()).toBe('closed');
    vi.advanceTimersByTime(60_000);
    expect(FakeSocket.instances).toHaveLength(3);
  });

  it('never redials after close()', () => {
    const { handle, socket } = connectPolicy();
    socket.open();
    handle.close();
    vi.advanceTimersByTime(60_000);
    expect(FakeSocket.instances).toHaveLength(1);
    expect(handle.state()).toBe('closed');
  });

  it('reconnect() redials immediately', () => {
    const { handle, socket } = connectPolicy();
    socket.open();
    socket.close();
    handle.reconnect();
    expect(FakeSocket.instances).toHaveLength(2);
    FakeSocket.instances.at(-1)!.open();
    expect(handle.state()).toBe('open');
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
