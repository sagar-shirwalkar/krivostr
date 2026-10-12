import { describe, it, expect } from 'vitest';
import { resolveBridgeUrl, BRIDGE_URL, decideTransport } from '../nostr/bridge';

const httpOrigin = { protocol: 'http:', host: 'localhost:3000' };
const httpsOrigin = { protocol: 'https:', host: 'krivostr.example' };

describe('resolveBridgeUrl', () => {
  it('uses the configured address when the UI is hosted separately', () => {
    expect(resolveBridgeUrl('wss://bridge.example.com/ws', httpsOrigin)).toBe(
      'wss://bridge.example.com/ws',
    );
  });

  it('falls back to the page origin when nothing is configured', () => {
    expect(resolveBridgeUrl(undefined, httpOrigin)).toBe('ws://localhost:3000/ws');
  });

  it('upgrades to wss on an https page, as a mixed-content socket would be blocked', () => {
    expect(resolveBridgeUrl(undefined, httpsOrigin)).toBe('wss://krivostr.example/ws');
  });

  it('treats an empty VITE_BRIDGE_URL as unset rather than as a broken address', () => {
    expect(resolveBridgeUrl('', httpOrigin)).toBe('ws://localhost:3000/ws');
  });

  it('assumes a local bridge when there is no window, as under server rendering', () => {
    expect(resolveBridgeUrl(undefined, undefined)).toBe('ws://localhost:8081/ws');
  });
});

describe('BRIDGE_URL', () => {
  it('is a ws address ending in /ws', () => {
    expect(BRIDGE_URL).toMatch(/^wss?:\/\/[^/]+\/ws$/);
  });
});

describe('decideTransport', () => {
  it('honours ?transport=bridge over everything', () => {
    expect(decideTransport('?transport=bridge', 'krivostr.example', 'relay')).toBe('bridge');
    expect(decideTransport('?transport=bridge', 'localhost', undefined)).toBe('bridge');
  });

  it('honours ?transport=relay over the loopback default', () => {
    expect(decideTransport('?transport=relay', 'localhost', undefined)).toBe('relay');
    expect(decideTransport('?transport=relay', 'localhost', 'bridge')).toBe('relay');
  });

  it('honours an explicit build-time choice in either direction', () => {
    expect(decideTransport('', 'localhost', 'bridge')).toBe('bridge');
    expect(decideTransport('', 'localhost', 'relay')).toBe('relay');
    expect(decideTransport('', 'krivostr.example', 'bridge')).toBe('bridge');
  });

  it('defaults loopback pages to the bridge, so the tarball just works', () => {
    for (const host of ['localhost', '127.0.0.1', '::1']) {
      expect(decideTransport('', host, undefined)).toBe('bridge');
    }
  });

  it('defaults anywhere else to relay-direct, so the hosted demo is unchanged', () => {
    expect(decideTransport('', 'krivostr-ui.pages.dev', undefined)).toBe('relay');
    expect(decideTransport('', '192.168.1.10', undefined)).toBe('relay');
    expect(decideTransport(undefined, undefined, undefined)).toBe('relay');
  });
});
