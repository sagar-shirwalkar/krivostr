import { LitElement, html, css } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { NostrEvent, tagValue } from '../nostr/event';
import { threadOf } from '../nostr/thread';
import { countReactions, isReaction, reactionOf } from '../nostr/reaction';
import { embeddedOriginal, isRepost, isQuote, quoteOf, repostOf } from '../nostr/repost';
import { articleOf } from '../nostr/article';
import { applyDeletions, deletionOf, isDeletion } from '../nostr/nip09';
import { contentWarningOf, isSensitive } from '../nostr/sensitive';
import { splitSegments, mentionLabel } from '../nostr/nip27';
import { commentOf, isComment } from '../nostr/comment';
import { isListEvent } from '../nostr/lists';
import { zapReceiptOf, invoiceAmountSats } from '../nostr/zap';
import { articleAddress } from '../nostr/article';
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
    .mention {
      color: var(--amber);
      font-family: var(--font-mono);
      font-size: 0.85em;
    }
    button.mention.link {
      background: none;
      border: none;
      padding: 0;
      cursor: pointer;
      text-decoration: underline;
      text-underline-offset: 2px;
    }
    button.mention.link:hover { color: var(--text); }
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
    .sensitive .body {
      filter: blur(6px);
      user-select: none;
    }
    .warn {
      margin-top: var(--s-3);
      font-family: var(--font-mono);
      font-size: var(--step--1);
      color: var(--amber);
    }
    .warn button {
      background: transparent;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      color: var(--mute);
      font-family: var(--font-mono);
      font-size: var(--step--1);
      padding: var(--s-1) var(--s-3);
      cursor: pointer;
      margin-left: var(--s-2);
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

  /** Ids the user chose to reveal despite a content warning. */
  @state() private revealed = new Set<string>();

  /** Pubkeys on the viewer's own mute list. Local rule, any transport. */
  @property({ attribute: false }) muted: string[] = [];

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

  /**
   * Events minus anything a valid deletion removes, anything muted, and
   * the list events themselves (protocol traffic, not posts). Deletion
   * requests stay visible as receipts.
   */
  private get visible(): NostrEvent[] {
    return applyDeletions(this.events).filter(
      (e) => !isListEvent(e) && !this.muted.includes(e.pubkey),
    );
  }

  /**
   * Body text with `nostr:` references as links that open in the client
   * (NIP-21). Opaque spans — `nsec`, unknown hrps — stay inert text: there
   * is nothing to open, and a dead link would be worse than none.
   */
  private renderBody(content: string) {
    if (content === '') return html`<em style="color:var(--mute)">(empty)</em>`;
    return html`${splitSegments(content).map((s) => {
      if ('text' in s) return html`${s.text}`;
      const openable = s.mention.kind.type !== 'opaque';
      return openable
        ? html`<button class="mention link" title=${s.mention.raw} @click=${this.openMention(s.mention.raw)}>${mentionLabel(s.mention)}</button>`
        : html`<span class="mention" title=${s.mention.raw}>${mentionLabel(s.mention)}</span>`;
    })}`;
  }

  private openMention(raw: string) {
    return (ev: Event) => {
      ev.stopPropagation();
      this.dispatchEvent(
        new CustomEvent('mention-open', { detail: { raw }, bubbles: true, composed: true }),
      );
    };
  }

  private countsFor(e: NostrEvent): string {
    const counts = countReactions(this.visible);
    const c = counts.find((x) => x.id === e.id);
    const parts: string[] = [];
    if (c) {
      if (c.likes > 0) parts.push(`♥ ${c.likes}`);
      if (c.dislikes > 0) parts.push(`− ${c.dislikes}`);
    }
    // Zapped totals ride the receipts: sum what invoices claim for this
    // note or its address. Claims, not settlements — the total says
    // "claimed", and an undecodable invoice adds nothing.
    const addr = articleAddress(e);
    const sats = this.visible
      .map((x) => zapReceiptOf(x))
      .filter(
        (r) => r !== undefined && (r.event === e.id || (addr !== undefined && r.address === addr)),
      )
      .map((r) => invoiceAmountSats(r!.bolt11) ?? 0)
      .reduce((a, b) => a + b, 0);
    if (sats > 0) parts.push(`⚡ ${sats}`);
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
    if (!this.signer) return '';
    // Notes get the NIP-10/25/18 row; anything else commentable (articles
    // today) gets the NIP-22 row. Kind 1 never takes kind 1111 — that is
    // NIP-10's job, and mixing them strands replies across two threads.
    if (e.kind === 1) {
      return html`
        <div class="actions">
          <button @click=${this.act('reply-to', e)}>reply</button>
          <button @click=${this.act('react-to', e)}>♥ react</button>
          <button @click=${this.act('repost-of', e)}>↻ repost</button>
          <button @click=${this.act('zap-of', e)}>⚡ zap</button>
          <button @click=${this.act('delete-of', e)}>delete</button>
        </div>
      `;
    }
    if (e.kind === 30023) {
      return html`
        <div class="actions">
          <button @click=${this.act('comment-on', e)}>💬 comment</button>
          <button @click=${this.act('zap-of', e)}>⚡ zap</button>
        </div>
      `;
    }
    return '';
  }

  private renderEvent(e: NostrEvent) {
    // Zap receipts render as claims: amount from the invoice, sender when
    // public, target when cited. "Claimed" because a receipt is trusted on
    // its author's word, not cryptographic proof of payment.
    const receipt = zapReceiptOf(e);
    if (receipt) {
      const sats = invoiceAmountSats(receipt.bolt11);
      const target = receipt.event ?? receipt.address ?? '';
      return html`
        <article>
          <div class="reaction">
            ⚡ ${sats !== undefined ? `${sats} sats` : 'zap'}${receipt.sender ? ` from ${short(receipt.sender)}` : ''}
            to ${short(receipt.recipient)}${target ? ` on ${short(target)}` : ''}${receipt.request ? ` — “${receipt.request.comment}”` : ''}
          </div>
        </article>
      `;
    }
    // Comments render with their root scope: what article or event the
    // thread hangs off, answered or top-level alike.
    if (isComment(e)) {
      const c = commentOf(e);
      const scope = c?.root.address ?? c?.root.id ?? '';
      return html`
        <article>
          <div class="head">
            <span class="pub">${short(e.pubkey)}</span>
            <span class="kind">comment · ${new Date(e.created_at * 1000).toLocaleTimeString()}</span>
          </div>
          <div class="body">${this.renderBody(e.content)}</div>
          ${scope ? html`<div class="reply">on ${short(scope)}</div>` : ''}
        </article>
      `;
    }
    // Deletion requests render as one compact line naming what they cite.
    // The cited targets are already gone from `visible`; this is the receipt.
    if (isDeletion(e)) {
      const d = deletionOf(e);
      const n = (d?.eventIds.length ?? 0) + (d?.addresses.length ?? 0);
      return html`
        <article>
          <div class="reaction">🗑 ${short(e.pubkey)} requested deletion of ${n} event${n === 1 ? '' : 's'}</div>
        </article>
      `;
    }
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
          <div class="body">${this.renderBody(e.content)}</div>
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
            ? html`              <div class="repost">
                <div class="head"><span class="pub">${short(inner.pubkey)}</span></div>
                <div class="body">${this.renderBody(inner.content)}</div>
              </div>`
            : html`<div class="reply">repost of ${short(rp?.eventId ?? '')} (original not readable)</div>`}
          ${this.actionRow(e)}
        </article>
      `;
    }
    const thread = threadOf(e);
    const quote = isQuote(e) ? quoteOf(e) : undefined;
    const counts = e.kind === 1 || e.kind === 30023 ? this.countsFor(e) : '';
    const replyTo = tagValue(e, 'e');
    // A warning blurs the body until the user opts in. Revealing is sticky
    // for the session but never persisted: a fresh load warns again.
    const warning = isSensitive(e) && !this.revealed.has(e.id) ? contentWarningOf(e) : undefined;
    const reveal = (ev: Event) => {
      ev.stopPropagation();
      this.revealed = new Set([...this.revealed, e.id]);
    };
    return html`
      <article class=${warning !== undefined ? 'sensitive' : ''}>
        <div class="head">
          <span class="pub">${e.pubkey.slice(0, 8)}…${e.pubkey.slice(-4)}</span>
          <span class="kind">kind ${e.kind} · ${new Date(e.created_at * 1000).toLocaleTimeString()}</span>
        </div>
        <div class="body">${this.renderBody(e.content)}</div>
        ${warning !== undefined
          ? html`<div class="warn">sensitive${warning ? `: ${warning}` : ''}
              <button @click=${reveal}>reveal</button></div>`
          : ''}
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
    const visible = this.visible;
    if (visible.length === 0) {
      return html`<div class="empty">// no events yet — waiting on relays</div>`;
    }
    return html`${visible.map((e) => this.renderEvent(e))}`;
  }
}
