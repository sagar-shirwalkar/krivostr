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
import { parseNostrUri, resolveTarget } from '../nostr/nip21';
import {
  buildZapRequestTags,
  fetchPayParams,
  lnurlPayUrl,
  profileLud,
  requestInvoice,
} from '../nostr/zap';
import { parseWalletUri, walletCall } from '../nostr/nip47';
import { articleAddress } from '../nostr/article';

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
    .reader {
      position: fixed;
      inset: 0;
      background: color-mix(in oklab, var(--bg) 70%, transparent);
      backdrop-filter: blur(4px);
      z-index: 50;
      display: flex;
      justify-content: center;
      padding: var(--s-6) var(--s-5);
      overflow-y: auto;
    }
    .sheet {
      max-width: 720px;
      width: 100%;
      height: fit-content;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      padding: var(--s-5);
    }
    .sheet .close {
      background: transparent;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      color: var(--mute);
      font-family: var(--font-mono);
      font-size: var(--step--1);
      padding: var(--s-1) var(--s-3);
      cursor: pointer;
      margin-bottom: var(--s-4);
    }
    .sheet .empty {
      text-align: center;
      color: var(--mute);
      font-family: var(--font-mono);
      padding: var(--s-6);
    }
    .zaphead {
      font-family: var(--font-mono);
      color: var(--text);
      margin-bottom: var(--s-4);
    }
    .sheet label {
      display: block;
      font-family: var(--font-mono);
      font-size: var(--step--1);
      color: var(--mute);
      margin-bottom: var(--s-3);
    }
    .sheet input {
      display: block;
      width: 100%;
      margin-top: var(--s-1);
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      color: var(--text);
      font-family: var(--font-mono);
      padding: var(--s-2) var(--s-3);
      outline: none;
    }
    .sheet .row { margin-top: var(--s-3); }
    .sheet .row button,
    .sheet .warn + div button {
      background: var(--amber);
      color: var(--ink);
      border: none;
      border-radius: var(--radius);
      padding: var(--s-2) var(--s-5);
      font-family: var(--font-mono);
      cursor: pointer;
    }
    .sheet .warn {
      margin-top: var(--s-3);
      font-family: var(--font-mono);
      font-size: var(--step--1);
      color: var(--amber);
    }
    .invoice {
      word-break: break-all;
      font-family: var(--font-mono);
      font-size: var(--step--1);
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: var(--s-3);
      margin: var(--s-3) 0;
    }
    .sheet .body { margin: var(--s-3) 0; color: var(--text); }
  `;

  @state() private view: 'landing' | 'app' = 'landing';
  @state() private signer: Signer | null = null;
  @state() private searching = '';
  /** "N results…" line under the search box; empty when not searching. */
  @state() private resultLine = '';
  /**
   * Open entity (NIP-21 reader overlay). An array renders; `'missing'`
   * renders the not-found note; null hides the overlay.
   */
  @state() private reading: NostrEvent[] | 'missing' | null = null;

  /** In-progress zap (NIP-57). Null when no zap dialog is open. */
  @state() private zapping: {
    target: NostrEvent;
    lud: string;
    sats: string;
    comment: string;
    callback?: string;
    minSats: number;
    maxSats: number;
    invoice?: string;
    /** Pasted wallet-connect URI, session-only: never stored anywhere. */
    nwc: string;
    paidPreimage?: string;
    error?: string;
    busy: boolean;
  } | null = null;
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

  private mainFeed(): (HTMLElement & { push: (ev: NostrEvent) => void; muted: string[] }) | null {
    return this.renderRoot.querySelector('#mainfeed') as
      | (HTMLElement & { push: (ev: NostrEvent) => void; muted: string[] })
      | null;
  }

  private handleFeedEvent(e: CustomEvent<NostrEvent>) {
    const feed = this.mainFeed();
    if (!feed) return;
    // My own mute list updates the filter; list events never render.
    if (e.detail.kind === 10000 && this.myPubkey !== null && e.detail.pubkey === this.myPubkey) {
      feed.muted = mutedPubkeys(e.detail);
      return;
    }
    feed.push(e.detail);
  }

  private feedEl(): (HTMLElement & { clear: () => void }) | null {
    return this.renderRoot.querySelector('#mainfeed') as
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
    this.reading = null;
    if (q === '') {
      status.clearSearch();
      status.clearAuthor();
      return;
    }
    status.clearAuthor();
    status.searchAll(q);
    const counted = status.countBridge({ search: q, limit: 1 });
    if (counted) {
      void counted.then(
        (n) => (this.resultLine = `${n} result${n === 1 ? '' : 's'} in local store`),
        () => undefined,
      );
    }
  }

  /**
   * Open a clicked mention in the client (NIP-21). Notes and addresses
   * fetch into the reader overlay; authors replace the feed with their
   * notes. Anything unresolvable closes nothing and opens nothing — the
   * span was inert by construction.
   */
  private async handleMentionOpen(e: CustomEvent<{ raw: string }>) {
    const mention = parseNostrUri(e.detail.raw);
    if (!mention) return;
    const target = resolveTarget(mention);
    if (!target) return;
    const status = this.relayStatus();
    if (!status) return;
    if (target.view === 'author') {
      this.feedEl()?.clear();
      this.reading = null;
      this.resultLine = `showing notes by @${target.pubkey.slice(0, 8)}…`;
      status.clearSearch();
      status.showAuthor(target.pubkey);
      return;
    }
    if (target.view === 'event') {
      const found = await status.fetchOnce({ ids: [target.id], limit: 1 });
      this.reading = found.length > 0 ? found : 'missing';
      return;
    }
    const [kindRaw, pubkey, ...dParts] = target.coordinate.split(':');
    const kind = /^\d+$/.test(kindRaw) ? parseInt(kindRaw, 10) : NaN;
    if (!Number.isInteger(kind) || pubkey === '' || dParts.length === 0) {
      this.reading = 'missing';
      return;
    }
    const found = await status.fetchOnce({
      kinds: [kind],
      authors: [pubkey],
      tags: { d: [dParts.join(':')] },
      limit: 5,
    });
    const newest = found.sort((a, b) => b.created_at - a.created_at)[0];
    this.reading = newest ? [newest] : 'missing';
  }

  private closeReading() {
    this.reading = null;
  }

  /**
   * Open the zap dialog for a note or article. The recipient's lightning
   * address comes from their kind-0 profile when the relays have it;
   * otherwise the field waits for a pasted address. Bounds come from the
   * LNURL endpoint; until they load, sane defaults stand in.
   */
  private async handleZapOf(e: CustomEvent<{ event: NostrEvent }>) {
    if (!this.signer) return;
    const target = e.detail.event;
    this.zapping = {
      target, lud: '', sats: '21', comment: '', nwc: '',
      minSats: 1, maxSats: 21_000_000, busy: true,
    };
    const status = this.relayStatus();
    try {
      const profiles = status ? await status.fetchOnce({ kinds: [0], authors: [target.pubkey], limit: 1 }) : [];
      const lud = profiles.length > 0 ? profileLud(profiles[0].content) : undefined;
      if (!lud) {
        this.zapping = { ...this.zapping!, busy: false, error: 'no lightning address found — paste one below' };
        return;
      }
      const url = lnurlPayUrl(lud);
      if (url._tag === 'Err') {
        this.zapping = { ...this.zapping!, lud, busy: false, error: url.error };
        return;
      }
      const params = await fetchPayParams(url.value);
      if (params._tag === 'Err') {
        this.zapping = { ...this.zapping!, lud, busy: false, error: params.error };
        return;
      }
      this.zapping = {
        ...this.zapping!,
        lud,
        callback: params.value.callback,
        minSats: Math.max(1, Math.ceil(params.value.minSendable / 1000)),
        maxSats: Math.floor(params.value.maxSendable / 1000),
        busy: false,
      };
    } catch (err) {
      this.zapping = { ...this.zapping!, busy: false, error: String(err) };
    }
  }

  private closeZap() {
    this.zapping = null;
  }

  /**
   * Sign the zap request and ask the LNURL callback for an invoice. The
   * request is sent, never published; the invoice renders for the wallet
   * to pay, and the receipt arrives later as a kind 9735.
   */
  private async confirmZap() {
    const draft = this.zapping;
    if (!draft || !this.signer || !this.myPubkey || draft.busy) return;
    const sats = /^\d+$/.test(draft.sats) ? parseInt(draft.sats, 10) : NaN;
    if (!Number.isInteger(sats) || sats < draft.minSats || sats > draft.maxSats) {
      this.zapping = { ...draft, error: `amount must be ${draft.minSats}–${draft.maxSats} sats` };
      return;
    }
    const url = lnurlPayUrl(draft.lud.trim());
    if (url._tag === 'Err') {
      this.zapping = { ...draft, error: url.error };
      return;
    }
    this.zapping = { ...draft, busy: true, error: undefined };
    try {
      const params = await fetchPayParams(url.value);
      if (params._tag === 'Err') throw new Error(params.error);
      const msats = sats * 1000;
      if (msats < params.value.minSendable || msats > params.value.maxSendable) {
        throw new Error(`endpoint allows ${Math.ceil(params.value.minSendable / 1000)}–${Math.floor(params.value.maxSendable / 1000)} sats`);
      }
      const addr = draft.target.kind >= 30000 && draft.target.kind <= 39999
        ? articleAddress(draft.target)
        : undefined;
      const unsigned = {
        pubkey: this.myPubkey,
        created_at: Math.floor(Date.now() / 1000),
        kind: 9734,
        tags: buildZapRequestTags(
          draft.target.pubkey,
          msats,
          (this.relayStatus()?.connectedUrls ?? []).filter((u) => u.startsWith('wss://')),
          draft.lud.trim().startsWith('lnurl') ? draft.lud.trim() : undefined,
          draft.target.kind === 1 ? draft.target.id : undefined,
          addr,
        ),
        content: draft.comment,
      };
      const signed = await this.signer.signEvent(unsigned);
      if (signed._tag === 'Err') throw new Error(signed.error);
      const invoice = await requestInvoice(params.value.callback, msats, JSON.stringify(signed.value));
      if (invoice._tag === 'Err') throw new Error(invoice.error);
      this.zapping = { ...this.zapping!, busy: false, invoice: invoice.value };
    } catch (err) {
      this.zapping = { ...this.zapping!, busy: false, error: String(err) };
    }
  }

  private copyInvoice() {
    if (this.zapping?.invoice) void navigator.clipboard.writeText(this.zapping.invoice);
  }

  /**
   * Pay the displayed invoice through a wallet-connect connection (NIP-47).
   * The URI is pasted per session and never stored — not in state that
   * survives, not in storage, nowhere. The wallet pays; the preimage ends
   * the dialog.
   */
  private async payWithWallet() {
    const draft = this.zapping;
    if (!draft || !draft.invoice || draft.busy) return;
    const conn = parseWalletUri(draft.nwc.trim());
    if (conn._tag === 'Err') {
      this.zapping = { ...draft, error: conn.error };
      return;
    }
    this.zapping = { ...draft, busy: true, error: undefined };
    const res = await walletCall(conn.value, 'pay_invoice', { invoice: draft.invoice });
    if (res._tag === 'Err') {
      this.zapping = { ...this.zapping!, busy: false, error: res.error };
      return;
    }
    const preimage = (res.value.result as Record<string, unknown> | undefined)?.preimage;
    this.zapping = {
      ...this.zapping!,
      busy: false,
      paidPreimage: typeof preimage === 'string' ? preimage : 'paid',
    };
  }

  private renderZap() {
    const z = this.zapping;
    if (!z) return '';
    const set = (k: 'lud' | 'sats' | 'comment' | 'nwc') => (e: Event) => {
      this.zapping = { ...z, [k]: (e.target as HTMLInputElement).value };
    };
    return html`
      <div class="reader" @click=${this.closeZap}>
        <div class="sheet" @click=${(e: Event) => e.stopPropagation()}>
          <button class="close" @click=${this.closeZap}>close ×</button>
          <div class="zaphead">⚡ zap ${z.target.pubkey.slice(0, 8)}…</div>
          ${z.busy && !z.invoice
            ? html`<div class="empty">contacting lightning endpoint…</div>`
            : z.paidPreimage
              ? html`<div class="body">paid ✓</div>
                <div class="invoice">${z.paidPreimage}</div>`
              : z.invoice
                ? html`<div class="body">pay this invoice in your wallet:</div>
                  <div class="invoice">${z.invoice}</div>
                  <div class="row"><button @click=${this.copyInvoice}>copy invoice</button></div>
                  <label>or pay now with wallet connect (NIP-47, never stored)
                    <input .value=${z.nwc} @input=${set('nwc')} placeholder="nostr+walletconnect://…" /></label>
                  <div class="row"><button @click=${() => void this.payWithWallet()}>pay with wallet</button></div>`
                : html`
                  <label>to (lightning address)<input .value=${z.lud} @input=${set('lud')} placeholder="name@domain" /></label>
                  <label>amount (sats, ${z.minSats}–${z.maxSats})
                    <input .value=${z.sats} @input=${set('sats')} inputmode="numeric" /></label>
                  <label>comment (optional)<input .value=${z.comment} @input=${set('comment')} /></label>
                  <div class="row"><button @click=${() => void this.confirmZap()}>get invoice</button></div>`}
          ${z.error ? html`<div class="warn">${z.error}</div>` : ''}
        </div>
      </div>
    `;
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
    this.reading = null;
    if (q === '') {
      status.clearSearch();
      status.clearAuthor();
      return;
    }
    status.clearAuthor();
    status.searchAll(q);
    const counted = status.countBridge({ search: q, limit: 1 });
    if (counted) {
      void counted.then(
        (n) => (this.resultLine = `${n} result${n === 1 ? '' : 's'} in local store`),
        () => undefined,
      );
    }
  }

  /**
   * Open a clicked mention in the client (NIP-21). Notes and addresses
   * fetch into the reader overlay; authors replace the feed with their
   * notes. Anything unresolvable closes nothing and opens nothing — the
   * span was inert by construction.
   */
  private async handleMentionOpen(e: CustomEvent<{ raw: string }>) {
    const mention = parseNostrUri(e.detail.raw);
    if (!mention) return;
    const target = resolveTarget(mention);
    if (!target) return;
    const status = this.relayStatus();
    if (!status) return;
    if (target.view === 'author') {
      this.feedEl()?.clear();
      this.reading = null;
      this.resultLine = `showing notes by @${target.pubkey.slice(0, 8)}…`;
      status.clearSearch();
      status.showAuthor(target.pubkey);
      return;
    }
    if (target.view === 'event') {
      const found = await status.fetchOnce({ ids: [target.id], limit: 1 });
      this.reading = found.length > 0 ? found : 'missing';
      return;
    }
    const [kindRaw, pubkey, ...dParts] = target.coordinate.split(':');
    const kind = /^\d+$/.test(kindRaw) ? parseInt(kindRaw, 10) : NaN;
    if (!Number.isInteger(kind) || pubkey === '' || dParts.length === 0) {
      this.reading = 'missing';
      return;
    }
    const found = await status.fetchOnce({
      kinds: [kind],
      authors: [pubkey],
      tags: { d: [dParts.join(':')] },
      limit: 5,
    });
    const newest = found.sort((a, b) => b.created_at - a.created_at)[0];
    this.reading = newest ? [newest] : 'missing';
  }

  private closeReading() {
    this.reading = null;
  }

  /**
   * Open the zap dialog for a note or article. The recipient's lightning
   * address comes from their kind-0 profile when the relays have it;
   * otherwise the field waits for a pasted address. Bounds come from the
   * LNURL endpoint; until they load, sane defaults stand in.
   */
  private async handleZapOf(e: CustomEvent<{ event: NostrEvent }>) {
    if (!this.signer) return;
    const target = e.detail.event;
    this.zapping = {
      target, lud: '', sats: '21', comment: '',
      minSats: 1, maxSats: 21_000_000, busy: true,
    };
    const status = this.relayStatus();
    try {
      const profiles = status ? await status.fetchOnce({ kinds: [0], authors: [target.pubkey], limit: 1 }) : [];
      const lud = profiles.length > 0 ? profileLud(profiles[0].content) : undefined;
      if (!lud) {
        this.zapping = { ...this.zapping!, busy: false, error: 'no lightning address found — paste one below' };
        return;
      }
      const url = lnurlPayUrl(lud);
      if (url._tag === 'Err') {
        this.zapping = { ...this.zapping!, lud, busy: false, error: url.error };
        return;
      }
      const params = await fetchPayParams(url.value);
      if (params._tag === 'Err') {
        this.zapping = { ...this.zapping!, lud, busy: false, error: params.error };
        return;
      }
      this.zapping = {
        ...this.zapping!,
        lud,
        callback: params.value.callback,
        minSats: Math.max(1, Math.ceil(params.value.minSendable / 1000)),
        maxSats: Math.floor(params.value.maxSendable / 1000),
        busy: false,
      };
    } catch (err) {
      this.zapping = { ...this.zapping!, busy: false, error: String(err) };
    }
  }

  private closeZap() {
    this.zapping = null;
  }

  /**
   * Sign the zap request and ask the LNURL callback for an invoice. The
   * request is sent, never published; the invoice renders for the wallet
   * to pay, and the receipt arrives later as a kind 9735.
   */
  private async confirmZap() {
    const draft = this.zapping;
    if (!draft || !this.signer || !this.myPubkey || draft.busy) return;
    const sats = /^\d+$/.test(draft.sats) ? parseInt(draft.sats, 10) : NaN;
    if (!Number.isInteger(sats) || sats < draft.minSats || sats > draft.maxSats) {
      this.zapping = { ...draft, error: `amount must be ${draft.minSats}–${draft.maxSats} sats` };
      return;
    }
    const url = lnurlPayUrl(draft.lud.trim());
    if (url._tag === 'Err') {
      this.zapping = { ...draft, error: url.error };
      return;
    }
    this.zapping = { ...draft, busy: true, error: undefined };
    try {
      const params = await fetchPayParams(url.value);
      if (params._tag === 'Err') throw new Error(params.error);
      const msats = sats * 1000;
      if (msats < params.value.minSendable || msats > params.value.maxSendable) {
        throw new Error(`endpoint allows ${Math.ceil(params.value.minSendable / 1000)}–${Math.floor(params.value.maxSendable / 1000)} sats`);
      }
      const addr = draft.target.kind >= 30000 && draft.target.kind <= 39999
        ? articleAddress(draft.target)
        : undefined;
      const unsigned = {
        pubkey: this.myPubkey,
        created_at: Math.floor(Date.now() / 1000),
        kind: 9734,
        tags: buildZapRequestTags(
          draft.target.pubkey,
          msats,
          (this.relayStatus()?.connectedUrls ?? []).filter((u) => u.startsWith('wss://')),
          draft.lud.trim().startsWith('lnurl') ? draft.lud.trim() : undefined,
          draft.target.kind === 1 ? draft.target.id : undefined,
          addr,
        ),
        content: draft.comment,
      };
      const signed = await this.signer.signEvent(unsigned);
      if (signed._tag === 'Err') throw new Error(signed.error);
      const invoice = await requestInvoice(params.value.callback, msats, JSON.stringify(signed.value));
      if (invoice._tag === 'Err') throw new Error(invoice.error);
      this.zapping = { ...this.zapping!, busy: false, invoice: invoice.value };
    } catch (err) {
      this.zapping = { ...this.zapping!, busy: false, error: String(err) };
    }
  }

  private copyInvoice() {
    if (this.zapping?.invoice) void navigator.clipboard.writeText(this.zapping.invoice);
  }

  private renderZap() {
    const z = this.zapping;
    if (!z) return '';
    const set = (k: 'lud' | 'sats' | 'comment') => (e: Event) => {
      this.zapping = { ...z, [k]: (e.target as HTMLInputElement).value };
    };
    return html`
      <div class="reader" @click=${this.closeZap}>
        <div class="sheet" @click=${(e: Event) => e.stopPropagation()}>
          <button class="close" @click=${this.closeZap}>close ×</button>
          <div class="zaphead">⚡ zap ${z.target.pubkey.slice(0, 8)}…</div>
          ${z.busy
            ? html`<div class="empty">contacting lightning endpoint…</div>`
            : z.invoice
              ? html`<div class="body">pay this invoice in your wallet:</div>
                <div class="invoice">${z.invoice}</div>
                <div class="row"><button @click=${this.copyInvoice}>copy invoice</button></div>`
              : html`
                <label>to (lightning address)<input .value=${z.lud} @input=${set('lud')} placeholder="name@domain" /></label>
                <label>amount (sats, ${z.minSats}–${z.maxSats})
                  <input .value=${z.sats} @input=${set('sats')} inputmode="numeric" /></label>
                <label>comment (optional)<input .value=${z.comment} @input=${set('comment')} /></label>
                <div class="row"><button @click=${() => void this.confirmZap()}>get invoice</button></div>`}
          ${z.error ? html`<div class="warn">${z.error}</div>` : ''}
        </div>
      </div>
    `;
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
           @zap-of=${this.handleZapOf}
           @react-to=${this.handleReactTo}
           @repost-of=${this.handleRepostOf}
           @delete-of=${this.handleDeleteOf}
           @mention-open=${this.handleMentionOpen}
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
          ${this.zapping ? this.renderZap() : ''}
          <nostr-feed id="mainfeed" .signer=${this.signer}></nostr-feed>
          ${this.reading !== null
            ? html`<div class="reader" @click=${this.closeReading}>
                <div class="sheet" @click=${(e: Event) => e.stopPropagation()}>
                  <button class="close" @click=${this.closeReading}>close ×</button>
                  ${this.reading === 'missing'
                    ? html`<div class="empty">// not found on connected relays</div>`
                    : html`<nostr-feed .signer=${this.signer} .events=${this.reading}></nostr-feed>`}
                </div>
              </div>`
            : ''}
        </main>
      </div>
    `;
  }
}
