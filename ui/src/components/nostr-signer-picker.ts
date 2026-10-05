import { LitElement, html, css } from 'lit';
import { customElement, state } from 'lit/decorators.js';
import { Signer, SignerType, localSigner, nip07Signer, isNip07Available, nip46Signer, parseBunkerUrl } from '../nostr/signer';
import { nip44Transport } from '../nostr/nip46';
import { bytesToHex } from '@noble/hashes/utils';
import { nsecDecode } from '../nostr/bech32';

@customElement('krivostr-signer-picker')
export class KrivostrSignerPicker extends LitElement {
  static override styles = css`
    :host { display: block; }
    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      padding: var(--s-5);
    }
    h3 { font-size: var(--step-1); margin-bottom: var(--s-4); }
    .row { display: flex; gap: var(--s-3); margin-bottom: var(--s-3); }
    .opt {
      flex: 1;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: var(--s-3);
      cursor: pointer;
      transition: all var(--dur) var(--ease);
      background: var(--ink-2);
      color: var(--text);
      text-align: left;
      font-family: var(--font-mono);
      font-size: var(--step--1);
    }
    .opt:hover { border-color: var(--amber); }
    .opt[aria-pressed='true'] { border-color: var(--amber); background: var(--graphite-2); }
    input {
      width: 100%;
      background: var(--ink-2);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: var(--s-3);
      color: var(--text);
      font-family: var(--font-mono);
      font-size: var(--step--1);
    }
    button.go {
      margin-top: var(--s-4);
      background: var(--amber);
      color: var(--ink);
      border: none;
      border-radius: var(--radius);
      padding: var(--s-3) var(--s-5);
      font-family: var(--font-mono);
      cursor: pointer;
    }
    .err { color: var(--coral); font-size: var(--step--1); margin-top: var(--s-2); }
    .hint { font-size: var(--step--2); color: var(--text-dim); margin-top: var(--s-2); }
    .hint a { color: var(--amber); }
    /* Modal */
    .modal-overlay {
      position: fixed; inset: 0; background: rgba(0,0,0,0.6);
      display: flex; align-items: center; justify-content: center;
      z-index: 1000; animation: fadeIn 0.15s ease;
    }
    .modal {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      padding: var(--s-6);
      max-width: 480px; width: 90%;
      box-shadow: 0 20px 40px rgba(0,0,0,0.3);
      animation: slideUp 0.2s ease;
    }
    @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
    @keyframes slideUp { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }
    .modal h3 { margin-bottom: var(--s-3); }
    .modal .ext-list { display: flex; flex-direction: column; gap: var(--s-3); margin: var(--s-4) 0; }
    .modal .ext {
      display: flex; align-items: center; gap: var(--s-3);
      padding: var(--s-3); background: var(--ink-2);
      border: 1px solid var(--border); border-radius: var(--radius);
      text-decoration: none; color: var(--text);
      transition: all var(--dur) var(--ease);
    }
    .modal .ext:hover { border-color: var(--amber); background: var(--graphite-2); }
    .modal .ext .icon { font-size: var(--step-2); }
    .modal .ext .name { font-family: var(--font-mono); font-size: var(--step-0); font-weight: 500; }
    .modal .ext .desc { font-size: var(--step--1); color: var(--text-dim); margin-left: auto; }
    .modal .close { margin-top: var(--s-4); background: var(--ink-2); color: var(--text); border: 1px solid var(--border); }
    .modal .close:hover { border-color: var(--amber); }
  `;

  @state() private choice: SignerType = 'local';
  @state() private nsecInput = '';
  @state() private bunkerInput = '';
  @state() private error = '';
  @state() private nip07Available = false;
  @state() private showNip07Modal = false;

  override connectedCallback() {
    super.connectedCallback();
    this.nip07Available = isNip07Available();
  }

  private openNip07Modal() {
    this.showNip07Modal = true;
  }

  private closeNip07Modal() {
    this.showNip07Modal = false;
  }

  private async confirmNip46(remotePubkey: string, relay: string, secret: string | undefined) {
    try {
      const localSecret = bytesToHex(crypto.getRandomValues(new Uint8Array(32)));
      const signer = await nip46Signer(
        { remotePubkey, relay, secret },
        localSecret,
        nip44Transport(localSecret, remotePubkey),
      );
      this.dispatchEvent(
        new CustomEvent('signer-chosen', { detail: { signer }, bubbles: true, composed: true }),
      );
    } catch (e) {
      this.error = `bunker connect failed: ${String(e)}`;
    }
  }

  private confirm() {
    this.error = '';
    let signer: Signer | null = null;

    if (this.choice === 'local') {
      try {
        const hex = nsecDecode(this.nsecInput.trim());
        signer = localSigner(hex);
      } catch (e) {
        this.error = `invalid nsec: ${String(e)}`;
        return;
      }
    } else if (this.choice === 'nip07') {
      if (!this.nip07Available) {
        this.openNip07Modal();
        return;
      }
      signer = nip07Signer();
    } else if (this.choice === 'nip46') {
      // Async path: parse the bunker URL, then connect over NIP-44. The
      // local secret is a fresh one-time key identifying this session to the
      // bunker — it is not the user's key, which never leaves the bunker.
      const cfg = parseBunkerUrl(this.bunkerInput.trim());
      if (cfg._tag === 'Err') {
        this.error = `invalid bunker URL: ${cfg.error}`;
        return;
      }
      this.confirmNip46(cfg.value.remotePubkey, cfg.value.relay, cfg.value.secret);
      return;
    }

    this.dispatchEvent(
      new CustomEvent('signer-chosen', {
        detail: { signer },
        bubbles: true,
        composed: true,
      }),
    );
  }

  override render() {
    return html`
      <div class="card">
        <h3>Choose a signer to publish</h3>
        <div class="row">
          <button class="opt" aria-pressed=${this.choice === 'local'}
                  @click=${() => (this.choice = 'local')}>
            local nsec
          </button>
          <button class="opt" aria-pressed=${this.choice === 'nip07'}
                  @click=${() => { if (this.nip07Available) this.choice = 'nip07'; else this.openNip07Modal(); }}>
            extension (NIP-07)
          </button>
          <button class="opt" aria-pressed=${this.choice === 'nip46'}
                  @click=${() => (this.choice = 'nip46')}>
            bunker (NIP-46)
          </button>
        </div>
        ${this.choice === 'local'
          ? html`<input placeholder="nsec1... (e.g. nsec1abc2def3...)" .value=${this.nsecInput}
                         @input=${(e: Event) => (this.nsecInput = (e.target as HTMLInputElement).value)} />`
          : ''}
        ${this.choice === 'nip46'
          ? html`<input placeholder="bunker://..." .value=${this.bunkerInput}
                         @input=${(e: Event) => (this.bunkerInput = (e.target as HTMLInputElement).value)} />`
          : ''}
        ${this.error ? html`<div class="err">${this.error}</div>` : ''}
        <button class="go" @click=${this.confirm}>continue</button>

        ${this.showNip07Modal
          ? html`
            <div class="modal-overlay" @click=${this.closeNip07Modal}>
              <div class="modal" @click=${(e: Event) => e.stopPropagation()}>
                <h3>NIP-07 extension required</h3>
                <p style="color: var(--text-dim); margin-bottom: var(--s-4);">
                  No browser extension detected. Install one of these to sign with NIP-07:
                </p>
                <div class="ext-list">
                  <a class="ext" href="https://getalby.com/" target="_blank" rel="noopener">
                    <span class="icon" style="color: var(--amber);">◈</span>
                    <span class="name">Alby</span>
                    <span class="desc">Popular, multi-account, web & mobile</span>
                  </a>
                  <a class="ext" href="https://nos2x.org/" target="_blank" rel="noopener">
                    <span class="icon" style="color: var(--amber);">▸</span>
                    <span class="name">nos2x</span>
                    <span class="desc">Lightweight, open source, Firefox/Chrome</span>
                  </a>
                  <a class="ext" href="https://flamingo.nostr.rocks/" target="_blank" rel="noopener">
                    <span class="icon" style="color: var(--amber);">◆</span>
                    <span class="name">Flamingo</span>
                    <span class="desc">Clean UI, NIP-46 bunker support</span>
                  </a>
                </div>
                <button class="go close" @click=${this.closeNip07Modal} style="width: 100%;">Got it</button>
              </div>
            </div>
          `
          : ''}
      </div>
    `;
  }
}
