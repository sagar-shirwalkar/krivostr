import { LitElement, html, css } from 'lit';
import { customElement, state } from 'lit/decorators.js';
import { RelayHandle, RelayState, connect } from '../nostr/relay';
import { connectBridge, chooseTransport } from '../nostr/bridge';
import { DEFAULT_RELAYS, outboxFor, parseRelayList, RelayHint } from '../nostr/nip65';
import { NostrEvent } from '../nostr/event';

interface Slot {
  url: string;
  handle: RelayHandle;
  state: RelayState;
}

/**
 * Owns the relay transport.
 *
 * This element is the single place in the UI that opens sockets. `app-shell`
 * used to declare its own `relay` field, never assigned it, and so silently
 * dropped every publish on the floor; it now goes through `publish` below
 * instead of keeping a second, dead reference.
 */

@customElement('krivostr-relay-status')
export class NostrRelayStatus extends LitElement {
  static override styles = css`
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

  override connectedCallback(): void {
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

  /**
   * Send a signed event to every connected transport.
   *
   * Returns false when nothing is connected, so the caller can tell the user
   * rather than appearing to have published.
   */
  publish(e: NostrEvent): boolean {
    if (this.slots.length === 0) return false;
    for (const slot of this.slots) slot.handle.publish(e);
    return true;
  }

  /** Relay addresses currently connected, for display and diagnostics. */
  get connectedUrls(): string[] {
    return this.slots.map((s) => s.url);
  }

  /**
   * Search everywhere the global feed reads from. The bridge answers from
   * SQLite FTS5 (instant, ranked); upstream relays answer from their own
   * index when they support NIP-50, and ignore the `search` key when they
   * do not — in which case the feed simply shows what matches locally.
   */
  searchAll(query: string): void {
    for (const slot of this.slots) {
      slot.handle.unsubscribe('global');
      slot.handle.subscribe('search', { search: query, limit: 50 });
    }
  }

  /** Drop the search subscription and reopen the global feed. */
  clearSearch(): void {
    for (const slot of this.slots) {
      slot.handle.unsubscribe('search');
      slot.handle.subscribe('global', { kinds: [1], limit: 50 });
    }
  }

  private emit(e: NostrEvent) {
    this.dispatchEvent(
      new CustomEvent('relay-event', { detail: e, bubbles: true, composed: true }),
    );
  }

  private learnHints(e: NostrEvent) {
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

  override disconnectedCallback(): void {
    this.slots.forEach((s) => s.handle.close());
    super.disconnectedCallback();
  }

  private cls(s: RelayState): string {
    if (s === 'open') return 'ok';
    if (s === 'connecting') return 'wait';
    return 'bad';
  }

  override render() {
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
