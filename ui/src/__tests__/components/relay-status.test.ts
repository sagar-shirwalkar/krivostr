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
});
