import { LitElement, html, css } from 'lit';
import { customElement, state } from 'lit/decorators.js';
import { Signer, SignerType, localSigner, nip07Signer, isNip07Available } from '../nostr/signer';
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
    .opt:disabled {
      opacity: 0.5;
      cursor: not-allowed;
      border-color: var(--border-dim);
    }
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
  `;

  @state() private choice: SignerType = 'local';
  @state() private nsecInput = '';
  @state() private bunkerInput = '';
  @state() private error = '';
  @state() private nip07Available = false;

  override connectedCallback() {
    super.connectedCallback();
    this.nip07Available = isNip07Available();
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
        this.error = 'no NIP-07 extension detected';
        return;
      }
      signer = nip07Signer();
    } else if (this.choice === 'nip46') {
      this.error = 'NIP-46 setup is a follow-up; see docs/signers.md';
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
        <h3>Choose a signer</h3>
        <div class="row">
          <button class="opt" aria-pressed=${this.choice === 'local'}
                  @click=${() => (this.choice = 'local')}>
            local nsec
          </button>
          <button class="opt" aria-pressed=${this.choice === 'nip07'}
                  @click=${() => { if (this.nip07Available) this.choice = 'nip07'; }}
                  ?disabled=${!this.nip07Available}>
            extension (NIP-07)
          </button>
          <button class="opt" aria-pressed=${this.choice === 'nip46'}
                  @click=${() => (this.choice = 'nip46')}>
            bunker (NIP-46)
          </button>
        </div>
        ${!this.nip07Available
          ? html`<div class="hint">
              NIP-07 requires a browser extension (e.g. <a href="https://getalby.com/" target="_blank" rel="noopener">Alby</a>, <a href="https://nos2x.org/" target="_blank" rel="noopener">nos2x</a>, <a href="https://flamingo.nostr.rocks/" target="_blank" rel="noopener">Flamingo</a>). Install one to enable this option.
            </div>`
          : ''}
        ${this.choice === 'local'
          ? html`<input placeholder="nsec1..." .value=${this.nsecInput}
                         @input=${(e: Event) => (this.nsecInput = (e.target as HTMLInputElement).value)} />`
          : ''}
        ${this.choice === 'nip46'
          ? html`<input placeholder="bunker://..." .value=${this.bunkerInput}
                         @input=${(e: Event) => (this.bunkerInput = (e.target as HTMLInputElement).value)} />`
          : ''}
        ${this.error ? html`<div class="err">${this.error}</div>` : ''}
        <button class="go" @click=${this.confirm}>continue</button>
      </div>
    `;
  }
}
