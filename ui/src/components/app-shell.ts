import { LitElement, html, css } from 'lit';
import { customElement, state } from 'lit/decorators.js';
import './krivostr-landing';
import './nostr-feed';
import './nostr-compose';
import './nostr-relay-status';
import './nostr-signer-picker';
import { Signer } from '../nostr/signer';
import { publish } from '../nostr/signer';
import { RelayHandle } from '../nostr/relay';

@customElement('krivostr-app')
export class KrivostrApp extends LitElement {
  static styles = css`
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
  `;

  @state() private view: 'landing' | 'app' = 'landing';
  @state() private signer: Signer | null = null;
  private relay: RelayHandle | null = null;

  private handleEnter() {
    this.view = 'app';
  }

  private handleSigner(e: CustomEvent<{ signer: Signer }>) {
    this.signer = e.detail.signer;
  }

  private async handlePublish(e: CustomEvent<{ content: string; kind: number }>) {
    if (!this.signer) return;
    const relay = this.relay;
    if (!relay) return;
    const pk = await this.signer.pubkey();
    if (pk._tag === 'Err') return;
    const unsigned = {
      pubkey: pk.value,
      created_at: Math.floor(Date.now() / 1000),
      kind: e.detail.kind,
      tags: [] as string[][],
      content: e.detail.content,
    };
    const signed = await publish(this.signer, relay, unsigned);
    if (signed._tag === 'Err') {
      // eslint-disable-next-line no-console
      console.error('publish failed', signed.error);
    }
  }

  private handleRelayEvent(e: CustomEvent) {
    const feed = this.renderRoot.querySelector('nostr-feed') as
      | (HTMLElement & { push: (ev: unknown) => void })
      | null;
    feed?.push(e.detail);
  }

  render() {
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
           @relay-event=${this.handleRelayEvent}>
        <header class="topbar">
          <div class="brand">krivostr</div>
          <krivostr-relay-status></krivostr-relay-status>
        </header>
        <main>
          ${!this.signer
            ? html`<krivostr-signer-picker></krivostr-signer-picker>`
            : ''}
          <nostr-compose .signer=${this.signer}></nostr-compose>
          <nostr-feed></nostr-feed>
        </main>
      </div>
    `;
  }
}
