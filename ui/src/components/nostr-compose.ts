import { LitElement, html, css } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { Signer } from '../nostr/signer';

@customElement('nostr-compose')
export class NostrCompose extends LitElement {
  static styles = css`
    :host { display: block; margin-bottom: var(--s-6); }
    form {
      display: flex;
      flex-direction: column;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      padding: var(--s-4);
      transition: border-color var(--dur) var(--ease);
    }
    form:focus-within { border-color: var(--amber-dim); }
    textarea {
      background: transparent;
      border: none;
      outline: none;
      color: var(--text);
      font-family: var(--font-sans);
      font-size: var(--step-1);
      resize: none;
      min-height: 80px;
      line-height: 1.5;
    }
    textarea::placeholder { color: var(--mute); }
    .row {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-top: var(--s-3);
      padding-top: var(--s-3);
      border-top: 1px solid var(--border);
      font-family: var(--font-mono);
      font-size: var(--step--1);
      color: var(--mute);
    }
    button {
      background: var(--amber);
      color: var(--ink);
      border: none;
      border-radius: var(--radius);
      padding: var(--s-2) var(--s-5);
      font-family: var(--font-mono);
      font-size: var(--step--1);
      cursor: pointer;
      transition: background var(--dur) var(--ease);
    }
    button:hover { background: var(--amber-dim); }
    button:disabled { opacity: 0.4; cursor: not-allowed; }
  `;

  @property({ attribute: false }) signer: Signer | null = null;
  @state() private text = '';

  private onInput(e: Event) {
    this.text = (e.target as HTMLTextAreaElement).value;
  }

  private submit(e: Event) {
    e.preventDefault();
    const trimmed = this.text.trim();
    if (!trimmed || !this.signer) return;
    this.dispatchEvent(
      new CustomEvent('publish-request', {
        detail: { content: trimmed, kind: 1 },
        bubbles: true,
        composed: true,
      }),
    );
    this.text = '';
  }

  render() {
    const disabled = !this.text.trim() || !this.signer;
    return html`
      <form @submit=${this.submit}>
        <textarea
          placeholder=${this.signer ? "What's reducing?" : 'Choose a signer to publish'}
          .value=${this.text}
          @input=${this.onInput}
        ></textarea>
        <div class="row">
          <span>kind 1 · ${this.text.length} chars</span>
          <button type="submit" ?disabled=${disabled}>sign &amp; send</button>
        </div>
      </form>
    `;
  }
}
