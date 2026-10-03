import { LitElement, html, css } from 'lit';
import { customElement, state } from 'lit/decorators.js';
import { NostrEvent, tagValue } from '../nostr/event';

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
  `;

  @state() events: NostrEvent[] = [];

  push(e: NostrEvent) {
    if (this.events.some((x) => x.id === e.id)) return;
    this.events = [e, ...this.events];
  }

  private renderEvent(e: NostrEvent) {
    const replyTo = tagValue(e, 'e');
    return html`
      <article>
        <div class="head">
          <span class="pub">${e.pubkey.slice(0, 8)}…${e.pubkey.slice(-4)}</span>
          <span class="kind">kind ${e.kind} · ${new Date(e.created_at * 1000).toLocaleTimeString()}</span>
        </div>
        <div class="body">${e.content || html`<em style="color:var(--mute)">(empty)</em>`}</div>
        ${replyTo
          ? html`<div class="reply">replying to ${replyTo.slice(0, 10)}…</div>`
          : ''}
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
