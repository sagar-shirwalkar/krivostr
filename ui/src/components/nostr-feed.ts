import { LitElement, html, css } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { NostrEvent, tagValue } from '../nostr/event';
import { threadOf } from '../nostr/thread';
import { countReactions, isReaction, reactionOf } from '../nostr/reaction';
import { embeddedOriginal, isRepost, isQuote, quoteOf, repostOf } from '../nostr/repost';
import { articleOf } from '../nostr/article';
import { Signer } from '../nostr/signer';

const short = (id: string): string => (id.length > 12 ? `${id.slice(0, 8)}…${id.slice(-4)}` : id);

@customElement('nostr-feed')
export class NostrFeed extends LitElement {
  static override styles = css`
    :host { display: block; }
    .empty {
      text-align: center;
      padding: var(--s-9) var(--s-5);
      color: var(--mute);
      font-family: var(--font-mono);
      font-size: var(--step--1);
    }
    article {
      border-top: 1px solid var(--border);
      padding: var(--s-5) 0;
      transition: background var(--dur) var(--ease);
    }
    article:hover { background: color-mix(in oklab, var(--surface) 50%, transparent); }
    .head {
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      margin-bottom: var(--s-3);
      font-family: var(--font-mono);
      font-size: var(--step--1);
      color: var(--text-dim);
    }
    .pub { color: var(--sage); }
    .kind { color: var(--mute); }
    .body {
      font-size: var(--step-1);
      line-height: 1.55;
      color: var(--text);
      white-space: pre-wrap;
      word-break: break-word;
    }
    .reply {
      margin-top: var(--s-3);
      font-family: var(--font-mono);
      font-size: var(--step--1);
      color: var(--mute);
    }
    .reply::before { content: '↳ '; color: var(--amber); }
    .repost {
      margin-top: var(--s-3);
      border-left: 2px solid var(--amber-dim);
      padding-left: var(--s-3);
      color: var(--text-dim);
    }
    .reaction {
      font-family: var(--font-mono);
      font-size: var(--step--1);
      color: var(--mute);
    }
    .counts {
      margin-top: var(--s-2);
      font-family: var(--font-mono);
      font-size: var(--step--1);
      color: var(--amber);
    }
    .actions {
      display: flex;
      gap: var(--s-3);
      margin-top: var(--s-3);
    }
    .actions button {
      background: transparent;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      color: var(--mute);
      font-family: var(--font-mono);
      font-size: var(--step--1);
      padding: var(--s-1) var(--s-3);
      cursor: pointer;
    }
    .actions button:hover:not(:disabled) { color: var(--text); border-color: var(--amber-dim); }
    .actions button:disabled { opacity: 0.4; cursor: not-allowed; }
  `;

  @state() events: NostrEvent[] = [];

  @property({ attribute: false }) signer: Signer | null = null;

  push(e: NostrEvent) {
    if (this.events.some((x) => x.id === e.id)) return;
    this.events = [e, ...this.events];
  }

  /** Empty the feed. Re-subscribing after a clear replays history, and
   * `push` deduplicates by id, so refilling is safe. */
  clear() {
    this.events = [];
  }

  private countsFor(id: string): string {
    const counts = countReactions(this.events);
    const c = counts.find((x) => x.id === id);
    if (!c || (c.likes === 0 && c.dislikes === 0)) return '';
    const parts: string[] = [];
    if (c.likes > 0) parts.push(`♥ ${c.likes}`);
    if (c.dislikes > 0) parts.push(`− ${c.dislikes}`);
    return parts.join(' · ');
  }

  private act(type: string, event: NostrEvent) {
    return (ev: Event) => {
      ev.stopPropagation();
      this.dispatchEvent(
        new CustomEvent(type, { detail: { event }, bubbles: true, composed: true }),
      );
    };
  }

  private actionRow(e: NostrEvent) {
    if (!this.signer || e.kind !== 1) return '';
    return html`
      <div class="actions">
        <button @click=${this.act('reply-to', e)}>reply</button>
        <button @click=${this.act('react-to', e)}>♥ react</button>
        <button @click=${this.act('repost-of', e)}>↻ repost</button>
      </div>
    `;
  }

  private renderEvent(e: NostrEvent) {
    // Articles render the header — title, summary, cover — over the body.
    // The body stays raw text: no Markdown renderer lives in this component.
    const article = articleOf(e);
    if (article) {
      return html`
        <article>
          <div class="head">
            <span class="pub">${short(e.pubkey)}</span>
            <span class="kind">article · ${new Date(e.created_at * 1000).toLocaleDateString()}</span>
          </div>
          ${article.image ? html`<div><a href=${article.image}>cover image</a></div>` : ''}
          <div class="body"><strong>${article.title || article.slug}</strong></div>
          ${article.summary ? html`<div class="reply">${article.summary}</div>` : ''}
          <div class="body">${e.content}</div>
        </article>
      `;
    }
    // Reactions render as one compact line: who reacted at what, with what.
    if (isReaction(e)) {
      const r = reactionOf(e);
      return html`
        <article>
          <div class="reaction">${short(e.pubkey)} reacted ${e.content} to ${short(r?.eventId ?? '')}</div>
        </article>
      `;
    }
    // Reposts render the embedded original; the wrapper carries no text.
    if (isRepost(e)) {
      const inner = embeddedOriginal(e.content);
      const rp = repostOf(e);
      return html`
        <article>
          <div class="head">
            <span class="pub">${short(e.pubkey)}</span>
            <span class="kind">repost · ${new Date(e.created_at * 1000).toLocaleTimeString()}</span>
          </div>
          ${inner
            ? html`<div class="repost">
                <div class="head"><span class="pub">${short(inner.pubkey)}</span></div>
                <div class="body">${inner.content}</div>
              </div>`
            : html`<div class="reply">repost of ${short(rp?.eventId ?? '')} (original not readable)</div>`}
          ${this.actionRow(e)}
        </article>
      `;
    }
    const thread = threadOf(e);
    const quote = isQuote(e) ? quoteOf(e) : undefined;
    const counts = e.kind === 1 ? this.countsFor(e.id) : '';
    const replyTo = tagValue(e, 'e');
    return html`
      <article>
        <div class="head">
          <span class="pub">${e.pubkey.slice(0, 8)}…${e.pubkey.slice(-4)}</span>
          <span class="kind">kind ${e.kind} · ${new Date(e.created_at * 1000).toLocaleTimeString()}</span>
        </div>
        <div class="body">${e.content || html`<em style="color:var(--mute)">(empty)</em>`}</div>
        ${thread && thread.rootId !== e.id
          ? html`<div class="reply">replying to ${short(thread.rootId)}</div>`
          : replyTo
            ? html`<div class="reply">replying to ${replyTo.slice(0, 10)}…</div>`
            : ''}
        ${quote ? html`<div class="reply">quoting ${short(quote.eventId)}</div>` : ''}
        ${counts ? html`<div class="counts">${counts}</div>` : ''}
        ${this.actionRow(e)}
      </article>
    `;
  }

  override render() {
    if (this.events.length === 0) {
      return html`<div class="empty">// no events yet — waiting on relays</div>`;
    }
    return html`${this.events.map((e) => this.renderEvent(e))}`;
  }
}
