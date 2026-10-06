import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import '../../components/nostr-relay-status';
import type { NostrRelayStatus } from '../../components/nostr-relay-status';

describe('<krivostr-relay-status>', () => {
  beforeEach(() => {
    // Stub WebSocket so the component can construct without a network.
    vi.stubGlobal(
      'WebSocket',
      class {
        onopen: (() => void) | null = null;
        onclose: (() => void) | null = null;
        onerror: ((e: unknown) => void) | null = null;
        onmessage: ((m: { data: string }) => void) | null = null;
        readyState = 0;
        constructor(public url: string) {}
        send() {}
        close() {
          this.onclose?.();
        }
      },
    );
  });

  afterEach(() => vi.unstubAllGlobals());

  it('renders one slot per default relay', async () => {
    const el = document.createElement('krivostr-relay-status') as NostrRelayStatus;
    document.body.appendChild(el);
    await el.updateComplete;
    const slots = el.shadowRoot!.querySelectorAll('.relay');
    expect(slots.length).toBeGreaterThan(0);
    el.remove();
  });

  it('renders the relay form', async () => {
    const el = document.createElement('krivostr-relay-status') as NostrRelayStatus;
    document.body.appendChild(el);
    await el.updateComplete;
    expect(el.shadowRoot!.querySelector('form.relays')).toBeTruthy();
    expect(el.shadowRoot!.querySelector('form.relays input')!.getAttribute('placeholder')).toBe('wss://…');
    el.remove();
  });

  it('rejects non-wss URLs without connecting', async () => {
    const el = document.createElement('krivostr-relay-status') as NostrRelayStatus;
    document.body.appendChild(el);
    await el.updateComplete;
    const before = el.shadowRoot!.querySelectorAll('.relay').length;
    await el.addRelay('http://not-a-relay');
    await el.updateComplete;
    expect(el.shadowRoot!.querySelectorAll('.relay')).toHaveLength(before);
    expect(el.shadowRoot!.querySelector('.err')).toBeTruthy();
    el.remove();
  });

  it('connects and disconnects a direct relay', async () => {
    const el = document.createElement('krivostr-relay-status') as NostrRelayStatus;
    document.body.appendChild(el);
    await el.updateComplete;
    const before = el.shadowRoot!.querySelectorAll('.relay').length;
    await el.addRelay('wss://added.example');
    await el.updateComplete;
    expect(el.shadowRoot!.querySelectorAll('.relay')).toHaveLength(before + 1);
    expect(el.connectedUrls).toContain('wss://added.example');
    await el.removeRelay('wss://added.example');
    await el.updateComplete;
    expect(el.connectedUrls).not.toContain('wss://added.example');
    el.remove();
  });

  it('refuses to add the same relay twice', async () => {
    const el = document.createElement('krivostr-relay-status') as NostrRelayStatus;
    document.body.appendChild(el);
    await el.updateComplete;
    await el.addRelay('wss://dup.example');
    await el.addRelay('wss://dup.example');
    await el.updateComplete;
    expect(el.connectedUrls.filter((u) => u === 'wss://dup.example')).toHaveLength(1);
    expect(el.shadowRoot!.querySelector('.err')).toBeTruthy();
    el.remove();
  });
});
