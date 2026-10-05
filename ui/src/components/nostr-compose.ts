import { LitElement, html, css } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { Signer } from '../nostr/signer';
import { NostrEvent } from '../nostr/event';
import { buildReplyTags, replyRoot } from '../nostr/thread';
import { buildCommentTags } from '../nostr/comment';
import { articleAddress } from '../nostr/article';

@customElement('nostr-compose')
export class NostrCompose extends LitElement {
  static override styles = css`
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

  /** The note being answered, if any. Set by the feed's reply button. */
  @property({ attribute: false }) replyTo: NostrEvent | null = null;

  /**
   * The non-note item being commented on (NIP-22). Exclusive with
   * `replyTo`: notes take NIP-10, everything else takes kind 1111.
   */
  @property({ attribute: false }) commentOn: NostrEvent | null = null;

  @state() private text = '';

  private onInput(e: Event) {
    this.text = (e.target as HTMLTextAreaElement).value;
  }

  private cancelReply() {
    this.replyTo = null;
    this.commentOn = null;
  }

  /** NIP-22 tags for the commented item, top-level (root is parent). */
  private commentTags(target: NostrEvent) {
    const addr = target.kind >= 30000 && target.kind <= 39999 ? articleAddress(target) : undefined;
    return buildCommentTags({
      id: target.id,
      address: addr,
      kind: target.kind,
      author: target.pubkey,
      relay: '',
    });
  }

  private submit(e: Event) {
    e.preventDefault();
    const trimmed = this.text.trim();
    if (!trimmed || !this.signer) return;
    // A reply carries NIP-10 tags naming the thread root and the parent.
    // Hints the browser never saw stay empty rather than becoming junk tags.
    const rootId = this.replyTo ? (replyRoot(this.replyTo) ?? this.replyTo.id) : '';
    const tags: string[][] = this.replyTo
      ? buildReplyTags(
          rootId,
          '',
          // The root author is known only when the parent is the root; the
          // builder drops the p tag it cannot fill.
          rootId === this.replyTo.id ? this.replyTo.pubkey : '',
          this.replyTo.id,
          '',
          this.replyTo.pubkey,
        )
      : this.commentOn
        ? this.commentTags(this.commentOn)
        : [];
    const kind = this.replyTo ? 1 : this.commentOn ? 1111 : 1;
    this.dispatchEvent(
      new CustomEvent('publish-request', {
        detail: { content: trimmed, kind, tags },
        bubbles: true,
        composed: true,
      }),
    );
    this.text = '';
    this.replyTo = null;
    this.commentOn = null;
  }

  override render() {
    const disabled = !this.text.trim() || !this.signer;
    return html`
      <form @submit=${this.submit}>
        ${this.replyTo
          ? html`<div class="row">
              <span>↳ replying to ${this.replyTo.pubkey.slice(0, 8)}…</span>
              <button type="button" @click=${this.cancelReply}>cancel</button>
            </div>`
          : this.commentOn
            ? html`<div class="row">
                <span>💬 commenting on ${this.commentOn.pubkey.slice(0, 8)}…</span>
                <button type="button" @click=${this.cancelReply}>cancel</button>
              </div>`
            : ''}
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
