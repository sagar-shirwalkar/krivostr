/**
 * Bridge transport. When `KRIVOSTR_BRIDGE` is set (or by default in
 * production), the UI talks to the local Haskell bridge at /ws instead
 * of connecting to upstream relays directly. This gives us:
 *
 *   - a durable local cache the browser can't lose
 *   - one connection instead of N
 *   - server-side eviction policy we control
 *
 * The bridge speaks the same Nostr wire protocol as a relay, so this is
 * a drop-in replacement at the transport layer.
 */

import { parseEvent } from './event';
import { toWire } from './filter';
import { RelayHandle, RelayState, RelayHandlers } from './relay';

export const BRIDGE_URL = (() => {
  if (typeof window === 'undefined') return 'ws://localhost:8081/ws';
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${proto}//${window.location.host}/ws`;
})();

export const connectBridge = (h: RelayHandlers): RelayHandle => {
  let state: RelayState = 'connecting';
  const ws = new WebSocket(BRIDGE_URL);
  const queue: string[] = [];

  const set = (s: RelayState, detail?: string) => {
    state = s;
    h.onState(s, detail);
  };

  ws.onopen = () => {
    set('open');
    while (queue.length) ws.send(queue.shift()!);
  };
  ws.onclose = () => set('closed');
  ws.onerror = (e) => set('error', String(e));

  ws.onmessage = (msg) => {
    try {
      const data = JSON.parse(msg.data) as unknown[];
      if (!Array.isArray(data)) return;
      if (data[0] === 'EVENT') {
        const ev = parseEvent(data[2]);
        if (ev._tag === 'Ok') h.onEvent(ev.value);
      } else if (data[0] === 'NOTICE') {
        h.onState('error', String(data[1]));
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
    subscribe: (id, f) => send(['REQ', id, toWire(f)]),
    publish: (e) => send(['EVENT', e]),
    close: () => ws.close(),
  };
};

/**
 * Transport chooser: use bridge if `?transport=bridge` is present, or if
 * the environment variable `VITE_KRIVOSTR_TRANSPORT` is set to "bridge".
 * Otherwise, talk directly to relays.
 */
export const chooseTransport = (): 'bridge' | 'relay' => {
  if (typeof window !== 'undefined') {
    const p = new URLSearchParams(window.location.search);
    if (p.get('transport') === 'bridge') return 'bridge';
  }
  const env = (import.meta as unknown as { env?: Record<string, string> }).env;
  return env?.VITE_KRIVOSTR_TRANSPORT === 'bridge' ? 'bridge' : 'relay';
};
