import { LitElement, html, css } from 'lit';
import { customElement, state } from 'lit/decorators.js';
import { RelayHandle, RelayState, connect } from '../nostr/relay';
import { connectBridge, chooseTransport } from '../nostr/bridge';
import { DEFAULT_RELAYS, outboxFor, parseRelayList, RelayHint } from '../nostr/nip65';
import { FilterSpec, compile } from '../nostr/filter';
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
    .relay button {
      background: transparent; border: none; color: var(--mute);
      font-family: var(--font-mono); cursor: pointer; padding: 0 0 0 var(--s-1);
    }
    .relay button:hover { color: var(--coral); }
    form.relays { display: flex; gap: var(--s-2); align-items: center; }
    form.relays input {
      background: var(--surface); border: 1px solid var(--border);
      border-radius: var(--radius); color: var(--text);
      font-family: var(--font-mono); font-size: var(--step--1);
      padding: var(--s-1) var(--s-2); outline: none; width: 220px;
    }
    form.relays input:focus { border-color: var(--amber-dim); }
    form.relays button {
      background: transparent; border: 1px solid var(--border);
      border-radius: var(--radius); color: var(--mute);
      font-family: var(--font-mono); font-size: var(--step--1);
      padding: var(--s-1) var(--s-3); cursor: pointer;
    }
    form.relays button:hover { color: var(--text); border-color: var(--amber-dim); }
    .err { color: var(--coral); font-size: var(--step--1); font-family: var(--font-mono); }
  `;

  @state() private slots: Slot[] = [];
  @state() private userHints: RelayHint[] = [];
  @state() private transport: 'bridge' | 'relay' = chooseTransport();
  @state() private relayInput = '';
  @state() private relayError = '';
  /** Bridge-mode upstream list (persisted server-side). Direct mode has none. */
  @state() private upstreams: string[] = [];
  /** Subset currently connected, per the bridge. */
  @state() private connectedUp: string[] = [];
  /** Last pubkey passed to subscribeOwn, so late-added slots get it too. */
  private lastMutePubkey: string | null = null;

  override connectedCallback(): void {
    super.connectedCallback();
    const urls = this.userHints.length > 0
      ? outboxFor(this.userHints)
      : DEFAULT_RELAYS;

    if (this.transport === 'bridge') {
      const handle = connectBridge({
        onEvent: (e) => this.emit(e),
        onState: (s) => this.updateState('bridge', s),
        onEose: (id) => this.emitEose(id),
      });
      this.slots = [{ url: 'bridge', handle, state: 'connecting' }];
      handle.subscribe('global', { kinds: [1], limit: 50 });
      handle.subscribe('user-relay-list', { kinds: [10002], limit: 1 });
      void this.refreshUpstreams();
      return;
    }

    this.slots = urls.map((url) => {
      const handle = connect(url, {
        onEvent: (e) => {
          if (e.kind === 10002) this.learnHints(e);
          this.emit(e);
        },
        onState: (s) => this.updateState(url, s),
        onEose: (id) => this.emitEose(id),
      });
      return { url, handle, state: 'connecting' };
    });
    this.slots.forEach((s) => this.baseSubs(s.handle));
  }

  /**
   * The subscriptions every relay slot carries: the global feed, relay
   * lists, and the viewer's mute list once known. New slots — added by the
   * relay form mid-session — get the same set, so they join the feed rather
   * than sitting silent. (An active search/author view is not re-applied:
   * re-run it to include the new relay.)
   */
  private baseSubs(handle: RelayHandle): void {
    handle.subscribe('global', { kinds: [1], limit: 50 });
    handle.subscribe('user-relay-list', { kinds: [10002], limit: 1 });
    if (this.lastMutePubkey) {
      handle.subscribe('own-mute-list', { kinds: [10002], authors: [this.lastMutePubkey], limit: 1 });
    }
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
   * NIP-45 COUNT against the bridge slot only. Counts do not sum across
   * relays — one event on three relays is still one event — so only the
   * local store (which deduplicates by id) gets a number. Undefined on
   * direct-relay transport, where no honest total exists.
   */
  countBridge(filter: FilterSpec): Promise<number> | undefined {
    const bridge = this.slots.find((s) => s.url === 'bridge');
    if (!bridge) return undefined;
    return bridge.handle.count(filter);
  }

  /**
   * Subscribe to the viewer's own mute list (NIP-51 kind 10000). The feed
   * filters on it locally, so muting works against any relay. Called once
   * the signer reveals its pubkey.
   */
  subscribeOwn(pubkey: string): void {
    this.lastMutePubkey = pubkey;
    for (const slot of this.slots) {
      slot.handle.subscribe('own-mute-list', { kinds: [10002], authors: [pubkey], limit: 1 });
    }
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

  /** Show one author's notes instead of the global feed. */
  showAuthor(pubkey: string): void {
    for (const slot of this.slots) {
      slot.handle.unsubscribe('global');
      slot.handle.subscribe('author', { authors: [pubkey], limit: 50 });
    }
  }

  /** Drop the author view and reopen the global feed. */
  clearAuthor(): void {
    for (const slot of this.slots) {
      slot.handle.unsubscribe('author');
      slot.handle.subscribe('global', { kinds: [1], limit: 50 });
    }
  }

  /**
   * Acceptable relay URLs: wss anywhere, ws on loopback only (tests and
   * local relays). Anything else is a typo that would fail at connect with
   * a confusing error — same rule as `krivostr relay add`.
   */
  static validRelayUrl(url: string): boolean {
    return (
      url.startsWith('wss://') || url.startsWith('ws://localhost') || url.startsWith('ws://127.0.0.1')
    );
  }

  /** Bridge upstreams, persisted server-side. Fails quiet: the form stays. */
  private async refreshUpstreams(): Promise<void> {
    try {
      const res = await fetch('/relays');
      if (!res.ok) return;
      const doc = (await res.json()) as { configured?: unknown; connected?: unknown };
      if (Array.isArray(doc.configured)) {
        this.upstreams = (doc.configured as unknown[]).filter(
          (u): u is string => typeof u === 'string',
        );
      }
      if (Array.isArray(doc.connected)) {
        this.connectedUp = (doc.connected as unknown[]).filter(
          (u): u is string => typeof u === 'string',
        );
      }
    } catch {
      /* offline bridge or foreign host — the dots still tell the story */
    }
  }

  /**
   * Add a relay. Bridge transport persists through the bridge's own HTTP
   * API (same origin, so no CORS); direct transport opens a session-only
   * slot that dies with the page. Either way the new connection joins the
   * feed with the base subscriptions.
   */
  async addRelay(url: string): Promise<void> {
    const trimmed = url.trim();
    this.relayError = '';
    if (!NostrRelayStatus.validRelayUrl(trimmed)) {
      this.relayError = 'relay URL must be wss:// (ws:// only on localhost)';
      return;
    }
    if (this.transport === 'bridge') {
      try {
        const res = await fetch('/relays', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ url: trimmed }),
        });
        if (!res.ok) {
          this.relayError = `bridge refused: ${res.status}`;
          return;
        }
      } catch {
        this.relayError = 'bridge unreachable';
        return;
      }
      this.relayInput = '';
      await this.refreshUpstreams();
      return;
    }
    if (this.slots.some((s) => s.url === trimmed)) {
      this.relayError = 'already connected';
      return;
    }
    const handle = connect(trimmed, {
      onEvent: (e) => {
        if (e.kind === 10002) this.learnHints(e);
        this.emit(e);
      },
      onState: (s) => this.updateState(trimmed, s),
      onEose: (id) => this.emitEose(id),
    });
    this.slots = [...this.slots, { url: trimmed, handle, state: 'connecting' }];
    this.baseSubs(handle);
    this.relayInput = '';
  }

  /**
   * Drop a relay. Bridge transport forgets server-side too; direct
   * transport just closes the socket. The bridge slot itself and the last
   * direct slot stay: disconnecting everything strands the feed with no
   * way back except a reload.
   */
  async removeRelay(url: string): Promise<void> {
    this.relayError = '';
    if (this.transport === 'bridge') {
      try {
        const res = await fetch('/relays', {
          method: 'DELETE',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ url }),
        });
        if (!res.ok) this.relayError = `bridge refused: ${res.status}`;
      } catch {
        this.relayError = 'bridge unreachable';
      }
      await this.refreshUpstreams();
      return;
    }
    if (url === 'bridge' || this.slots.length <= 1) return;
    const slot = this.slots.find((s) => s.url === url);
    if (!slot) return;
    slot.handle.close();
    this.slots = this.slots.filter((s) => s.url !== url);
  }

  private emit(e: NostrEvent) {
    this.dispatchEvent(
      new CustomEvent('relay-event', { detail: e, bubbles: true, composed: true }),
    );
  }

  private emitEose(subId: string) {
    this.dispatchEvent(
      new CustomEvent('relay-eose', { detail: subId, bubbles: true, composed: true }),
    );
  }

  private onceSeq = 0;

  /**
   * One-shot fetch: subscribe everywhere, collect matches until every slot
   * says EOSE or the timeout fires, then unsubscribe. Resolves partial —
   * a relay that never says EOSE must not hang the UI. Matches are tested
   * locally, so a relay volunteering extra events cannot pollute the
   * result, and ids deduplicate across slots.
   */
  async fetchOnce(filter: FilterSpec, timeoutMs = 8000): Promise<NostrEvent[]> {
    const id = `once-${this.onceSeq++}`;
    const found = new Map<string, NostrEvent>();
    const eosed = new Set<string>();
    const test = compile(filter).test;
    const slots = this.slots.map((s) => s.handle);
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(timer);
        this.removeEventListener('relay-event', onEvent as EventListener);
        this.removeEventListener('relay-eose', onEose as EventListener);
        for (const h of slots) h.unsubscribe(id);
        resolve([...found.values()]);
      };
      const timer = setTimeout(done, timeoutMs);
      const onEvent = (e: Event) => {
        const ev = (e as CustomEvent<NostrEvent>).detail;
        if (ev && test(ev) && !found.has(ev.id)) found.set(ev.id, ev);
      };
      const onEose = (e: Event) => {
        eosed.add((e as CustomEvent<string>).detail);
        if (eosed.size >= slots.length) done();
      };
      this.addEventListener('relay-event', onEvent as EventListener);
      this.addEventListener('relay-eose', onEose as EventListener);
      for (const h of slots) h.subscribe(id, filter);
    });
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
    const removable = (url: string): boolean =>
      this.transport === 'relay' && url !== 'bridge' && this.slots.length > 1;
    return html`
      ${this.transport === 'bridge'
        ? html`<span class="hint">transport: bridge</span>`
        : ''}
      ${this.slots.map(
        (s) => html`
          <span class="relay">
            <span class="dot ${this.cls(s.state)}"></span>
            ${s.url === 'bridge' ? 'local bridge' : new URL(s.url).host}
            ${removable(s.url)
              ? html`<button title="disconnect" @click=${() => void this.removeRelay(s.url)}>×</button>`
              : ''}
          </span>
        `,
      )}
      ${this.transport === 'bridge'
        ? html`${this.upstreams.map(
            (u) => html`
              <span class="relay">
                <span class="dot ${this.upstreamState(u)}"></span>
                ${new URL(u).host}
                <button title="disconnect and forget" @click=${() => void this.removeRelay(u)}>×</button>
              </span>
            `,
          )}`
        : ''}
      <form class="relays" @submit=${(e: Event) => {
        e.preventDefault();
        void this.addRelay(this.relayInput);
      }}>
        <input
          placeholder="wss://…"
          .value=${this.relayInput}
          @input=${(e: Event) => (this.relayInput = (e.target as HTMLInputElement).value)}
        />
        <button type="submit">connect</button>
      </form>
      ${this.relayError ? html`<span class="err">${this.relayError}</span>` : ''}
    `;
  }

  /**
   * Dot state for a configured upstream, from the bridge's own connected
   * list: open when dialled, bad when configured but absent. (The UI has
   * no slot for these — the bridge owns those sockets, not the page.)
   */
  private upstreamState(url: string): string {
    return this.connectedUp.includes(url) ? 'ok' : 'bad';
  }
}
