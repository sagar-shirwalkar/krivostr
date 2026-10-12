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
  /**
   * Dial now, resetting the reconnect budget. No-op when open or after
   * `close()` — a closed handle stays closed. The manual counterpart to
   * automatic redial: UI retry buttons call this.
   */
  readonly reconnect: () => void;
  readonly publish: (e: NostrEvent) => void;
}

/** Frames a relay sends that are not events. */
interface RelayNotice {
  readonly type: 'NOTICE' | 'EOSE' | 'OK' | 'CLOSED';
  readonly detail: string;
}

/**
 * Bounded redial policy. Six attempts at 1/2/4/8/16/32s cover a bridge
 * restart several times over (~63s total) without hammering a relay that is
 * down for real. The budget resets on every successful open, so a flappy
 * relay in hour one cannot steal hour five's reconnect.
 */
export interface ReconnectPolicy {
  readonly maxAttempts: number;
  readonly baseMs: number;
  readonly capMs: number;
}

export const DEFAULT_RECONNECT: ReconnectPolicy = { maxAttempts: 6, baseMs: 1000, capMs: 32000 };

/** Backoff for 1-based attempt n: base, doubling, capped. Pure, tested. */
export const backoffMs = (attempt: number, p: ReconnectPolicy): number =>
  Math.min(p.capMs, p.baseMs * 2 ** (attempt - 1));

export const connect = (
  url: string,
  handlers: RelayHandlers,
  policy: ReconnectPolicy = DEFAULT_RECONNECT,
): RelayHandle => {
  let state: RelayState = 'connecting';
  /** Subscription id to filter, so a redial replays what the dead socket held. */
  const subs = new Map<string, FilterSpec>();
  /**
   * Frames composed before the socket opened. A REQ sent into a half-open
   * socket throws, and the first subscription always happens during
   * construction, so this queue is load-bearing rather than defensive.
   */
  const pending: string[] = [];
  /** Attempts used in the current budget; reset on open and on `reconnect()`. */
  let attempts = 0;
  /**
   * True once a drop has been seen (scheduled redial or manual retry armed).
   * `onopen` replays subscriptions exactly when this is set, then clears it —
   * which is what keeps the initial open replay-free and every redial replayed.
   */
  let redial = false;
  let retryTimer: ReturnType<typeof setTimeout> | undefined;
  /** True once `close()` runs: a closed handle never redials. */
  let userClosed = false;

  const set = (s: RelayState, detail?: string): void => {
    state = s;
    handlers.onState(s, detail);
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

  const failCounts = (): void => {
    // A dropped socket settles its waiters now rather than hanging them to
    // their 10s timeout: the reply they wait for will never arrive on it.
    for (const [, waiter] of counting) waiter.reject(new Error('connection lost'));
    counting.clear();
  };

  const scheduleRedial = (): void => {
    // Browsers fire error and close for one drop; schedule once. A closed
    // handle and an exhausted budget both stay down.
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

  // `ws` is replaced on every redial; everything else (subs, pending,
  // counting) outlives any one socket, which is what makes the handle
  // transparent to callers across drops. Assigned by dial(), which always
  // runs before any use — hence the definite-assignment assertion.
  let ws!: WebSocket;
  const dial = (): void => {
    ws = new WebSocket(url);

    ws.onopen = () => {
      // A redial replays every tracked subscription before flushing what
      // queued during the outage. Re-sending an id the relay still holds is
      // harmless — re-subscribing replaces it — which is what makes the
      // replay unconditional rather than diffed.
      const replay = redial;
      redial = false;
      attempts = 0;
      if (replay) {
        for (const [id, f] of subs) ws.send(JSON.stringify(['REQ', id, toWire(f)]));
      }
      set('open');
      while (pending.length > 0) ws.send(pending.shift()!);
    };

    ws.onclose = () => {
      failCounts();
      scheduleRedial();
      // Every outcome is settled inside: scheduled (connecting), terminally
      // exhausted (closed), user-closed (already closed), or already
      // scheduled by a preceding error. Nothing left to do here by design.
    };
    ws.onerror = () => {
      // The close event follows and carries the decision; the error itself
      // is only a detail line, never a state, so one drop schedules once.
      handlers.onState(state, 'socket error');
      failCounts();
      scheduleRedial();
    };

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
  };

  const send = (payload: unknown): void => {
    const json = JSON.stringify(payload);
    if (state === 'open') ws.send(json);
    else pending.push(json);
  };

  dial();

  return {
    url,
    state: () => state,
    subscribe: (id: string, f: FilterSpec) => {
      subs.set(id, f);
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
    reconnect: () => {
      // Manual redial: only a dropped handle qualifies — one that already
      // scheduled (or exhausted) a budget. Open handles are already there,
      // closed handles were closed on purpose, and an initial dial still in
      // flight must not grow a twin.
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
      for (const id of subs.keys()) send(['CLOSE', id]);
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
