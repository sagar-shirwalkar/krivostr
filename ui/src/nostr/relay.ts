/**
 * One relay WebSocket connection.
 *
 * The handle is the only thing callers see: it owns the socket, the outbound
 * queue, and the subscription bookkeeping, and it is safe to call `subscribe`
 * before the socket finishes opening. Frames are parsed here and nowhere else,
 * so a malformed message can never reach a component as a half-built event.
 *
 * `Krivostr.Relay` is the server-side counterpart; both speak the same NIP-01
 * wire protocol, which is what lets `bridge.ts` substitute for this module.
 */

import { NostrEvent, parseEvent } from './event';
import { FilterSpec, toWire } from './filter';

export type RelayState = 'connecting' | 'open' | 'closed' | 'error';

export interface RelayHandlers {
  readonly onEvent: (e: NostrEvent) => void;
  readonly onState: (s: RelayState, detail?: string) => void;
  /** End of stored events for one subscription. Optional: only one-shot
   * fetches listen; the live feed learns nothing from it it did not know. */
  readonly onEose?: (subId: string) => void;
}

export interface RelayHandle {
  readonly url: string;
  /** Current connection state. */
  readonly state: () => RelayState;
  /** Open (or replace) a subscription. */
  readonly subscribe: (id: string, f: FilterSpec) => void;
  /** Revoke one subscription. Re-subscribing the same id replaces it. */
  readonly unsubscribe: (id: string) => void;
  /**
   * NIP-45 count: how many stored events match, without fetching them.
   * Rejects when the relay never answers (10s) or does not support COUNT.
   */
  readonly count: (f: FilterSpec) => Promise<number>;
  readonly close: () => void;
  readonly publish: (e: NostrEvent) => void;
}

/** Frames a relay sends that are not events. */
interface RelayNotice {
  readonly type: 'NOTICE' | 'EOSE' | 'OK' | 'CLOSED';
  readonly detail: string;
}

export const connect = (url: string, handlers: RelayHandlers): RelayHandle => {
  let state: RelayState = 'connecting';
  /** Subscription ids we have sent, so `close()` can revoke them cleanly. */
  const subs = new Set<string>();
  /**
   * Frames composed before the socket opened. A REQ sent into a half-open
   * socket throws, and the first subscription always happens during
   * construction, so this queue is load-bearing rather than defensive.
   */
  const pending: string[] = [];

  const set = (s: RelayState, detail?: string): void => {
    state = s;
    handlers.onState(s, detail);
  };

  const ws = new WebSocket(url);

  const send = (payload: unknown): void => {
    const json = JSON.stringify(payload);
    if (state === 'open') ws.send(json);
    else pending.push(json);
  };

  /**
   * Outstanding COUNT requests by subscription id. A `Map`, not a plain
   * object: relay-controlled ids like `__proto__` must not resolve through
   * a prototype chain, and `Map` keys never do. The id format is still
   * checked at lookup (see below) so a foreign reply cannot settle a wait
   * it was not issued for.
   */
  const counting = new Map<string, { resolve: (n: number) => void; reject: (e: Error) => void }>();
  let countSeq = 0;

  ws.onopen = () => {
    set('open');
    while (pending.length > 0) ws.send(pending.shift()!);
  };

  ws.onclose = () => set('closed');
  ws.onerror = () => set('error', 'socket error');

  ws.onmessage = (msg: MessageEvent<string>) => {
    let data: unknown;
    try {
      data = JSON.parse(msg.data);
    } catch (e) {
      set('error', `invalid json: ${String(e)}`);
      return;
    }
    if (!Array.isArray(data)) return;

    switch (data[0]) {
      case 'EVENT': {
        // A malformed EVENT is dropped, not surfaced: one bad frame from a
        // relay must not look like a transport failure.
        const parsed = parseEvent(data[2]);
        if (parsed._tag === 'Ok') handlers.onEvent(parsed.value);
        break;
      }
      case 'COUNT': {
        // NIP-45 answer: ["COUNT", <sub-id>, {"count": N}]. The id must be
        // one this connection issued (`count-N`): anything else — a late
        // reply, a foreign id, or a prototype-chain probe like
        // `__proto__` — is dropped, not surfaced.
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
        break;
      }
      case 'EOSE': {
        if (typeof data[1] === 'string') handlers.onEose?.(data[1]);
        handlers.onState('open', `EOSE ${typeof data[1] === 'string' ? data[1] : ''}`.trim());
        break;
      }
      case 'NOTICE':
      case 'OK':
      case 'CLOSED': {
        const note: RelayNotice = {
          type: data[0],
          detail: typeof data[1] === 'string' ? data[1] : '',
        };
        handlers.onState('open', `${note.type} ${note.detail}`.trim());
        break;
      }
      default:
        break;
    }
  };

  return {
    url,
    state: () => state,
    subscribe: (id: string, f: FilterSpec) => {
      subs.add(id);
      send(['REQ', id, toWire(f)]);
    },
    unsubscribe: (id: string) => {
      if (subs.delete(id)) send(['CLOSE', id]);
    },
    count: (f: FilterSpec) =>
      new Promise<number>((resolve, reject) => {
        const id = `count-${countSeq++}`;
        counting.set(id, { resolve, reject });
        setTimeout(() => {
          if (counting.delete(id)) reject(new Error('COUNT timed out'));
        }, 10_000);
        send(['COUNT', id, toWire(f)]);
      }),
    publish: (e: NostrEvent) => send(['EVENT', e]),
    close: () => {
      for (const id of subs) send(['CLOSE', id]);
      subs.clear();
      pending.length = 0;
      // Outstanding counts reject now rather than hanging until their
      // timeout: the socket they were waiting on is gone.
      for (const [, waiter] of counting) waiter.reject(new Error('connection closed'));
      counting.clear();
      ws.close();
      set('closed');
    },
  };
};
