import { LitElement, html, css } from 'lit';
import { customElement, state } from 'lit/decorators.js';
import './krivostr-landing';
import './nostr-feed';
import './nostr-compose';
import './nostr-relay-status';
import './nostr-signer-picker';
import { Signer } from '../nostr/signer';
import { NostrRelayStatus } from './nostr-relay-status';
import { NostrCompose } from './nostr-compose';
import { NostrEvent } from '../nostr/event';
import { buildReactionTags } from '../nostr/reaction';
import { buildRepostTags, embedOriginal } from '../nostr/repost';
import { buildDeletionTags, parameterizedAddress } from '../nostr/nip09';
import { mutedPubkeys } from '../nostr/lists';

@customElement('krivostr-app')
export class KrivostrApp extends LitElement {
  static override styles = css`
    :host { display: block; min-height: 100vh; }
    .view { animation: fade-up var(--dur-slow) var(--ease); }
    .topbar {
      position: sticky;
      top: 0;
      z-index: 10;
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: var(--s-4) var(--s-5);
      background: color-mix(in oklab, var(--bg) 85%, transparent);
      backdrop-filter: blur(12px);
      border-bottom: 1px solid var(--border);
      font-family: var(--font-mono);
      font-size: var(--step--1);
    }
    .brand { color: var(--text); display: flex; gap: var(--s-2); align-items: center; }
    .brand::before {
      content: '';
      width: 8px; height: 8px; border-radius: 50%;
      background: var(--amber);
      box-shadow: 0 0 12px var(--amber);
    }
    main {
      max-width: 720px;
      margin: 0 auto;
      padding: var(--s-6) var(--s-5);
    }
    .search {
      display: flex;
      gap: var(--s-3);
      margin-bottom: var(--s-5);
    }
    .search input {
      flex: 1;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      color: var(--text);
      font-family: var(--font-mono);
      font-size: var(--step--1);
      padding: var(--s-2) var(--s-3);
      outline: none;
    }
    .search input:focus { border-color: var(--amber-dim); }
    .search button {
      background: transparent;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      color: var(--mute);
      font-family: var(--font-mono);
      font-size: var(--step--1);
      padding: var(--s-2) var(--s-4);
      cursor: pointer;
    }
    .search button:hover { color: var(--text); border-color: var(--amber-dim); }
    .resultline {
      font-family: var(--font-mono);
      font-size: var(--step--1);
      color: var(--mute);
      margin-bottom: var(--s-4);
    }
  `;

  @state() private view: 'landing' | 'app' = 'landing';
  @state() private signer: Signer | null = null;
  @state() private searching = '';
  /** "N results…" line under the search box; empty when not searching. */
  @state() private resultLine = '';
  /** My own pubkey, once the signer reveals it. Gates mute-list updates. */
  private myPubkey: string | null = null;

  /**
   * The relay transport belongs to <krivostr-relay-status>, which is the only
   * component that opens sockets. Reaching it through the shadow root keeps a
   * single owner instead of racing it with a second connection here.
   */
  private relayStatus(): NostrRelayStatus | null {
    return this.renderRoot.querySelector('krivostr-relay-status');
  }

  private handleEnter() {
    this.view = 'app';
  }

  private async handleSigner(e: CustomEvent<{ signer: Signer }>) {
    this.signer = e.detail.signer;
    const pk = await this.signer.pubkey();
    this.myPubkey = pk._tag === 'Ok' ? pk.value : null;
    if (this.myPubkey) this.relayStatus()?.subscribeOwn(this.myPubkey);
  }

  private async handlePublish(e: CustomEvent<{ content: string; kind: number; tags?: string[][] }>) {
    if (!this.signer) return;
    const status = this.relayStatus();
    if (!status) return;
    const pk = await this.signer.pubkey();
    if (pk._tag === 'Err') {
      // eslint-disable-next-line no-console
      console.error('publish failed: no pubkey', pk.error);
      return;
    }
    const unsigned = {
      pubkey: pk.value,
      created_at: Math.floor(Date.now() / 1000),
      kind: e.detail.kind,
      tags: e.detail.tags ?? ([] as string[][]),
      content: e.detail.content,
    };
    const signed = await this.signer.signEvent(unsigned);
    if (signed._tag === 'Err') {
      // eslint-disable-next-line no-console
      console.error('publish failed', signed.error);
      return;
    }
    if (!status.publish(signed.value)) {
      // eslint-disable-next-line no-console
      console.error('publish failed: no relay connected');
    }
  }

  /** The feed's reply button parks its target on the compose box. */
  private handleReplyTo(e: CustomEvent<{ event: NostrEvent }>) {
    const compose = this.renderRoot.querySelector('nostr-compose') as NostrCompose | null;
    if (compose) {
      compose.replyTo = e.detail.event;
      compose.commentOn = null;
      compose.focus();
    }
  }

  /** The feed's comment button parks a non-note target for NIP-22. */
  private handleCommentOn(e: CustomEvent<{ event: NostrEvent }>) {
    const compose = this.renderRoot.querySelector('nostr-compose') as NostrCompose | null;
    if (compose) {
      compose.commentOn = e.detail.event;
      compose.replyTo = null;
      compose.focus();
    }
  }

  /** One-click like: a kind-7 with the target's e/p/k tags, no text needed. */
  private handleReactTo(e: CustomEvent<{ event: NostrEvent }>) {
    const target = e.detail.event;
    void this.handlePublish(
      new CustomEvent('publish-request', {
        detail: {
          content: '+',
          kind: 7,
          tags: buildReactionTags(target.id, '', target.pubkey, target.kind),
        },
      }),
    );
  }

  /**
   * Delete-your-own: publishes a kind-5 citing the id (and the address,
   * for replaceable events) after confirming authorship. A click on
   * someone else's note fails here, not on the relay.
   */
  private async handleDeleteOf(e: CustomEvent<{ event: NostrEvent }>) {
    if (!this.signer) return;
    const pk = await this.signer.pubkey();
    if (pk._tag === 'Err') return;
    const target = e.detail.event;
    if (target.pubkey !== pk.value) {
      // eslint-disable-next-line no-console
      console.error('delete refused: not your event');
      return;
    }
    const addr = parameterizedAddress(target);
    void this.handlePublish(
      new CustomEvent('publish-request', {
        detail: {
          content: '',
          kind: 5,
          tags: buildDeletionTags([target.id], addr ? [addr] : []),
        },
      }),
    );
  }

  /** One-click repost: kind 6 for notes, kind 16 for anything else. */
  private handleRepostOf(e: CustomEvent<{ event: NostrEvent }>) {
    const target = e.detail.event;
    const kind = target.kind === 1 ? 6 : 16;
    void this.handlePublish(
      new CustomEvent('publish-request', {
        detail: {
          content: embedOriginal(target),
          kind,
          tags: buildRepostTags(target.id, '', target.pubkey, target.kind),
        },
      }),
    );
  }

  private handleFeedEvent(e: CustomEvent<NostrEvent>) {
    const feed = this.renderRoot.querySelector('nostr-feed') as
      | (HTMLElement & { push: (ev: NostrEvent) => void; muted: string[] })
      | null;
    if (!feed) return;
    // My own mute list updates the filter; list events never render.
    if (e.detail.kind === 10000 && this.myPubkey !== null && e.detail.pubkey === this.myPubkey) {
      feed.muted = mutedPubkeys(e.detail);
      return;
    }
    feed.push(e.detail);
  }

  private feedEl(): (HTMLElement & { clear: () => void }) | null {
    return this.renderRoot.querySelector('nostr-feed') as
      | (HTMLElement & { clear: () => void })
      | null;
  }

  /** Search submit: clear the feed and ask every transport for matches.
   * An empty query restores the global feed. The result count comes from
   * the bridge only — see `countBridge` for why relays are not summed. */
  private handleSearch(e: Event) {
    e.preventDefault();
    const status = this.relayStatus();
    if (!status) return;
    const q = this.searching.trim();
    this.feedEl()?.clear();
    this.resultLine = '';
    if (q === '') {
      status.clearSearch();
      return;
    }
    status.searchAll(q);
    const counted = status.countBridge({ search: q, limit: 1 });
    if (counted) {
      void counted.then(
        (n) => (this.resultLine = `${n} result${n === 1 ? '' : 's'} in local store`),
        () => undefined,
      );
    }
  }

  override render() {
    if (this.view === 'landing') {
      return html`
        <div class="view" @enter=${this.handleEnter}>
          <krivostr-landing></krivostr-landing>
        </div>
      `;
    }
    return html`
      <div class="view"
           @signer-chosen=${this.handleSigner}
           @publish-request=${this.handlePublish}
           @reply-to=${this.handleReplyTo}
           @comment-on=${this.handleCommentOn}
           @react-to=${this.handleReactTo}
           @repost-of=${this.handleRepostOf}
           @delete-of=${this.handleDeleteOf}
           @relay-event=${this.handleFeedEvent}>
        <header class="topbar">
          <div class="brand">krivostr</div>
          <krivostr-relay-status></krivostr-relay-status>
        </header>
        <main>
          ${!this.signer
            ? html`<krivostr-signer-picker></krivostr-signer-picker>`
            : ''}
          <nostr-compose .signer=${this.signer}></nostr-compose>
          <form class="search" @submit=${this.handleSearch}>
            <input
              placeholder="search notes…"
              .value=${this.searching}
              @input=${(e: Event) => (this.searching = (e.target as HTMLInputElement).value)}
            />
            <button type="submit">search</button>
          </form>
          ${this.resultLine ? html`<div class="resultline">${this.resultLine}</div>` : ''}
          <nostr-feed .signer=${this.signer}></nostr-feed>
        </main>
      </div>
    `;
  }
}
