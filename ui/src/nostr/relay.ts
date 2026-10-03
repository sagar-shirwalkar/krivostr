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
}

export interface RelayHandle {
  readonly url: string;
  /** Current connection state. */
  readonly state: () => RelayState;
  /** Open (or replace) a subscription. */
  readonly subscribe: (id: string, f: FilterSpec) => void;
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
      case 'NOTICE':
      case 'EOSE':
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
    publish: (e: NostrEvent) => send(['EVENT', e]),
    close: () => {
      for (const id of subs) send(['CLOSE', id]);
      subs.clear();
      pending.length = 0;
      ws.close();
      set('closed');
    },
  };
};
