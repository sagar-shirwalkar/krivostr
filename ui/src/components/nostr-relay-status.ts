import { LitElement, html, css } from 'lit';
import { customElement, state } from 'lit/decorators.js';
import { RelayHandle, RelayState, connect } from '../nostr/relay';
import { connectBridge, chooseTransport } from '../nostr/bridge';
import { DEFAULT_RELAYS, outboxFor, parseRelayList, RelayHint } from '../nostr/nip65';

interface Slot {
  url: string;
  handle: RelayHandle;
  state: RelayState;
}

@customElement('krivostr-relay-status')
export class NostrRelayStatus extends LitElement {
  static styles = css`
    :host { display: flex; gap: var(--s-4); align-items: center; flex-wrap: wrap; }
    .dot {
      width: 6px; height: 6px; border-radius: 50%;
      display: inline-block; margin-right: var(--s-2);
      vertical-align: middle;
    }
    .ok   { background: var(--sage); box-shadow: 0 0 8px var(--sage); }
    .wait { background: var(--amber); animation: blink 1.2s infinite; }
    .bad  { background: var(--coral); }
    .relay { color: var(--text-dim); font-size: var(--step--1); font-family: var(--font-mono); }
    .hint { color: var(--mute); font-size: var(--step--1); }
  `;

  @state() private slots: Slot[] = [];
  @state() private userHints: RelayHint[] = [];
  @state() private transport: 'bridge' | 'relay' = chooseTransport();

  connectedCallback(): void {
    super.connectedCallback();
    const urls = this.userHints.length > 0
      ? outboxFor(this.userHints)
      : DEFAULT_RELAYS;

    if (this.transport === 'bridge') {
      const handle = connectBridge({
        onEvent: (e) => this.emit(e),
        onState: (s) => this.updateState('bridge', s),
      });
      this.slots = [{ url: 'bridge', handle, state: 'connecting' }];
      handle.subscribe('global', { kinds: [1], limit: 50 });
      handle.subscribe('user-relay-list', { kinds: [10002], limit: 1 });
      return;
    }

    this.slots = urls.map((url) => {
      const handle = connect(url, {
        onEvent: (e) => {
          if (e.kind === 10002) this.learnHints(e);
          this.emit(e);
        },
        onState: (s) => this.updateState(url, s),
      });
      return { url, handle, state: 'connecting' };
    });
    this.slots.forEach((s) => {
      s.handle.subscribe('global', { kinds: [1], limit: 50 });
      s.handle.subscribe('user-relay-list', { kinds: [10002], limit: 1 });
    });
  }

  private emit(e: import('../nostr/event').NostrEvent) {
    this.dispatchEvent(
      new CustomEvent('relay-event', { detail: e, bubbles: true, composed: true }),
    );
  }

  private learnHints(e: import('../nostr/event').NostrEvent) {
    const hints = parseRelayList(e);
    if (hints.length > 0 && this.userHints.length === 0) {
      this.userHints = hints;
    }
  }

  private updateState(url: string, s: RelayState) {
    this.slots = this.slots.map((slot) =>
      slot.url === url ? { ...slot, state: s } : slot,
    );
  }

  disconnectedCallback(): void {
    this.slots.forEach((s) => s.handle.close());
    super.disconnectedCallback();
  }

  private cls(s: RelayState): string {
    if (s === 'open') return 'ok';
    if (s === 'connecting') return 'wait';
    return 'bad';
  }

  render() {
    return html`
      ${this.transport === 'bridge'
        ? html`<span class="hint">transport: bridge</span>`
        : ''}
      ${this.slots.map(
        (s) => html`
          <span class="relay">
            <span class="dot ${this.cls(s.state)}"></span>
            ${s.url === 'bridge' ? 'local bridge' : new URL(s.url).host}
          </span>
        `,
      )}
    `;
  }
}
