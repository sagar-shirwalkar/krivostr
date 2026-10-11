/**
 * Bridge transport. The UI talks to the Haskell bridge at /ws instead of
 * connecting to upstream relays directly. This gives us:
 *
 *   - a durable local cache the browser can't lose
 *   - one connection instead of N
 *   - server-side eviction policy we control
 *
 * The bridge speaks the same Nostr wire protocol as a relay, so this is
 * a drop-in replacement at the transport layer.
 */

import { parseEvent } from './event';
import { FilterSpec, toWire } from './filter';
import {
  DEFAULT_RECONNECT,
  ReconnectPolicy,
  RelayHandle,
  RelayState,
  RelayHandlers,
  backoffMs,
} from './relay';

/**
 * Work out where the bridge lives.
 *
 * A UI hosted on Cloudflare Pages is not being served by the bridge, so there
 * is no same-origin /ws to fall back to: VITE_BRIDGE_URL names it at build
 * time, e.g. wss://bridge.example.com/ws. Unset, the page and the bridge are
 * assumed to be one origin, which is what `krivostr serve` gives you, and an
 * empty string is treated as unset rather than as a broken address.
 *
 * Kept separate from the module-level constant because Vite inlines
 * `import.meta.env` when it builds this file, which leaves nothing a test can
 * stub; the decision itself is worth testing on its own.
 */
export const resolveBridgeUrl = (
  configured: string | undefined,
  origin: { protocol: string; host: string } | undefined,
): string => {
  if (configured !== undefined && configured !== '') return configured;
  if (origin === undefined) return 'ws://localhost:8081/ws';
  const proto = origin.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${proto}//${origin.host}/ws`;
};

export const BRIDGE_URL = resolveBridgeUrl(
  import.meta.env.VITE_BRIDGE_URL as string | undefined,
  typeof window === 'undefined' ? undefined : window.location,
);

export const connectBridge = (
  h: RelayHandlers,
  policy: ReconnectPolicy = DEFAULT_RECONNECT,
): RelayHandle => {
  let state: RelayState = 'connecting';
  const queue: string[] = [];
  /** Subscription id to filter, so a redial replays what the dead socket held. */
  const subs = new Map<string, FilterSpec>();
  let attempts = 0;
  /** Set on any scheduled or manual redial; `onopen` replays exactly then. */
  let redial = false;
  let retryTimer: ReturnType<typeof setTimeout> | undefined;
  /** True once `close()` runs: a closed handle never redials. */
  let userClosed = false;

  const set = (s: RelayState, detail?: string) => {
    state = s;
    h.onState(s, detail);
  };

  const failCounts = (): void => {
    for (const [, waiter] of counting) waiter.reject(new Error('connection lost'));
    counting.clear();
  };

  const scheduleRedial = (): void => {
    if (userClosed || retryTimer !== undefined) return;
    attempts += 1;
    if (attempts > policy.maxAttempts) {
      set('closed', 'reconnect budget exhausted');
      return;
    }
    const delay = backoffMs(attempts, policy);
    set('connecting', `reconnecting in ${Math.round(delay / 1000)}s (attempt ${attempts}/${policy.maxAttempts})`);
    redial = true;
    retryTimer = setTimeout(() => {
      retryTimer = undefined;
      dial();
    }, delay);
  };

  let ws!: WebSocket;
  const dial = (): void => {
    ws = new WebSocket(BRIDGE_URL);

    ws.onopen = () => {
      const replay = redial;
      redial = false;
      attempts = 0;
      if (replay) {
        for (const [id, f] of subs) ws.send(JSON.stringify(['REQ', id, toWire(f)]));
      }
      set('open');
      while (queue.length) ws.send(queue.shift()!);
    };
    ws.onclose = () => {
      failCounts();
      scheduleRedial();
    };
    ws.onerror = (e) => {
      set(state, `socket error: ${String(e)}`);
      failCounts();
      scheduleRedial();
    };
  };

  dial();

  /**
   * Outstanding COUNT requests by subscription id. A `Map`, not a plain
   * object: relay-controlled ids like `__proto__` must not resolve through
   * a prototype chain, and `Map` keys never do. The id format is still
   * checked at lookup so a foreign reply cannot settle a wait it was not
   * issued for.
   */
  const counting = new Map<string, { resolve: (n: number) => void; reject: (e: Error) => void }>();
  let countSeq = 0;

  ws.onmessage = (msg) => {
    try {
      const data = JSON.parse(msg.data) as unknown[];
      if (!Array.isArray(data)) return;
      if (data[0] === 'EVENT') {
        const ev = parseEvent(data[2]);
        if (ev._tag === 'Ok') h.onEvent(ev.value);
      } else if (data[0] === 'NOTICE') {
        h.onState('error', String(data[1]));
      } else if (data[0] === 'EOSE') {
        if (typeof data[1] === 'string') h.onEose?.(data[1]);
      } else if (data[0] === 'COUNT') {
        const subId = typeof data[1] === 'string' && /^count-\d+$/.test(data[1]) ? data[1] : undefined;
        const n =
          typeof data[2] === 'object' && data[2] !== null
            ? (data[2] as Record<string, unknown>).count
            : undefined;
        if (subId !== undefined && typeof n === 'number') {
          const waiter = counting.get(subId);
          if (waiter) {
            counting.delete(subId);
            waiter.resolve(n);
          }
        }
      }
    } catch (e) {
      h.onState('error', String(e));
    }
  };

  const send = (payload: unknown): void => {
    const json = JSON.stringify(payload);
    if (state === 'open') ws.send(json);
    else queue.push(json);
  };

  return {
    url: BRIDGE_URL,
    state: () => state,
    subscribe: (id, f) => {
      subs.set(id, f);
      send(['REQ', id, toWire(f)]);
    },
    unsubscribe: (id) => {
      if (subs.delete(id)) send(['CLOSE', id]);
    },
    count: (f) =>
      new Promise<number>((resolve, reject) => {
        const id = `count-${countSeq++}`;
        counting.set(id, { resolve, reject });
        setTimeout(() => {
          if (counting.delete(id)) reject(new Error('COUNT timed out'));
        }, 10_000);
        send(['COUNT', id, toWire(f)]);
      }),
    publish: (e) => send(['EVENT', e]),
    reconnect: () => {
      if (userClosed || state === 'open' || !redial) return;
      if (retryTimer !== undefined) {
        clearTimeout(retryTimer);
        retryTimer = undefined;
      }
      attempts = 0;
      set('connecting', 'retrying now');
      dial();
    },
    close: () => {
      userClosed = true;
      redial = false;
      if (retryTimer !== undefined) {
        clearTimeout(retryTimer);
        retryTimer = undefined;
      }
      for (const [, waiter] of counting) waiter.reject(new Error('connection closed'));
      counting.clear();
      ws.close();
      set('closed');
    },
  };
};

/**
 * Transport chooser: use bridge if `?transport=bridge` is present, or if
 * the environment variable `VITE_KRIVOSTR_TRANSPORT` is set to "bridge".
 * Otherwise, talk directly to relays.
 *
 * Kept separate from the module-level constant because Vite inlines
 * `import.meta.env` when it builds this file, which leaves nothing a test can
 * stub; the decision itself is worth testing on its own.
 */
export const decideTransport = (
  search: string | undefined,
  hostname: string | undefined,
  envTransport: string | undefined,
): 'bridge' | 'relay' => {
  // Explicit beats implicit, always: a URL param or a build-time choice wins
  // over any heuristic, so demos and debugging stay predictable.
  const param = search !== undefined ? new URLSearchParams(search).get('transport') : null;
  if (param === 'bridge') return 'bridge';
  if (param === 'relay') return 'relay';
  if (envTransport === 'bridge') return 'bridge';
  if (envTransport === 'relay') return 'relay';
  // Unset: a loopback page is almost certainly the bundled UI served by the
  // bridge itself (the release tarball, `krivostr serve`), so default to it
  // and let localhost just work. Anywhere else — the hosted demo, a LAN
  // address — stays relay-direct, exactly as before.
  if (hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '::1') {
    return 'bridge';
  }
  return 'relay';
};

export const chooseTransport = (): 'bridge' | 'relay' => {
  const search = typeof window !== 'undefined' ? window.location.search : undefined;
  const hostname = typeof window !== 'undefined' ? window.location.hostname : undefined;
  const env = (import.meta as unknown as { env?: Record<string, string> }).env;
  return decideTransport(search, hostname, env?.VITE_KRIVOSTR_TRANSPORT);
};
