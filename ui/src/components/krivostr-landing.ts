import { LitElement, html, css } from 'lit';
import { customElement } from 'lit/decorators.js';

@customElement('krivostr-landing')
export class KrivostrLanding extends LitElement {
  static override styles = css`
    :host {
      display: block;
      min-height: 100vh;
      padding: var(--s-8) var(--s-5);
      max-width: 1120px;
      margin: 0 auto;
    }
    .nav {
      display: flex; justify-content: space-between; align-items: center;
      margin-bottom: var(--s-10);
      font-size: var(--step--1); color: var(--text-dim);
      font-family: var(--font-mono);
    }
    .nav .mark { color: var(--text); letter-spacing: 0.05em; display: flex; align-items: center; gap: var(--s-2); }
    .nav .mark::before {
      content: ''; width: 8px; height: 8px; border-radius: 50%;
      background: var(--amber); box-shadow: 0 0 12px var(--amber);
    }
    .nav nav a { margin-left: var(--s-5); color: var(--text-dim); }
    .nav nav a:hover { color: var(--text); border-bottom-color: var(--amber); }
    .hero { max-width: 780px; }
    .eyebrow {
      font-family: var(--font-mono); font-size: var(--step--1);
      color: var(--amber); letter-spacing: 0.15em; text-transform: uppercase;
      margin-bottom: var(--s-4); display: block;
    }
    h1 {
      font-size: var(--step-5); line-height: 0.98;
      letter-spacing: -0.035em; font-weight: 500; margin-bottom: var(--s-5);
    }
    h1 em { font-style: normal; color: var(--amber); font-family: var(--font-mono); font-weight: 400; }
    .lede {
      font-size: var(--step-2); color: var(--text-dim); line-height: 1.5;
      max-width: 620px; margin-bottom: var(--s-7);
    }
    .cta { display: flex; gap: var(--s-4); align-items: center; margin-bottom: var(--s-10); }
    .btn {
      font-family: var(--font-mono); font-size: var(--step-0);
      padding: var(--s-3) var(--s-5); border-radius: var(--radius);
      border: 1px solid var(--border); background: var(--surface); color: var(--text);
      cursor: pointer; transition: all var(--dur) var(--ease); text-decoration: none;
    }
    .btn:hover { border-color: var(--amber); color: var(--amber); }
    .btn.primary { background: var(--amber); color: var(--ink); border-color: var(--amber); }
    .btn.primary:hover { background: var(--amber-dim); color: var(--ink); }
    .demo {
      background: var(--ink-2); border: 1px solid var(--border);
      border-radius: var(--radius-lg); padding: var(--s-5);
      font-family: var(--font-mono); font-size: var(--step--1);
      color: var(--paper-2); line-height: 1.8; margin-bottom: var(--s-10); overflow-x: auto;
    }
    .demo .prompt { color: var(--sage); }
    .demo .comment { color: var(--mute); }
    .demo .ok { color: var(--amber); }
    .demo .cursor {
      display: inline-block; width: 8px; height: 14px; background: var(--amber);
      vertical-align: middle; animation: blink 1s steps(1) infinite;
    }
    .features {
      display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
      gap: var(--s-1); border-top: 1px solid var(--border);
      border-left: 1px solid var(--border); margin-bottom: var(--s-10);
    }
    .feature {
      padding: var(--s-6); border-right: 1px solid var(--border);
      border-bottom: 1px solid var(--border); transition: background var(--dur) var(--ease);
    }
    .feature:hover { background: var(--surface); }
    .feature .num { font-family: var(--font-mono); font-size: var(--step--1); color: var(--mute); display: block; margin-bottom: var(--s-4); }
    .feature h3 { font-size: var(--step-1); margin-bottom: var(--s-3); color: var(--text); }
    .feature p { color: var(--text-dim); font-size: var(--step-0); margin: 0; }
    footer {
      border-top: 1px solid var(--border); padding-top: var(--s-5);
      font-family: var(--font-mono); font-size: var(--step--1); color: var(--mute);
      display: flex; justify-content: space-between;
    }
  `;

  private enter() {
    this.dispatchEvent(new CustomEvent('enter', { bubbles: true, composed: true }));
  }

  override render() {
    return html`
      <header class="nav">
        <div class="mark" @click=${this.enter} style="cursor: pointer;">krivostr<span style="color:var(--mute)">/0.3</span></div>
        <nav>
          <a href="https://github.com/nostr-protocol/nostr" target="_blank">protocol</a>
          <a href="#" @click=${(e: Event) => { e.preventDefault(); this.enter(); }}>open app →</a>
        </nav>
      </header>
      <section class="hero">
        <span class="eyebrow">a pure nostr client</span>
        <h1>
          A closed term language<br />
          for the open social web.<br />
          <em>reduce(relay) → feed</em>
        </h1>
        <p class="lede">
          krivostr is a Nostr client built like a Krivine machine: a small set of
          immutable terms, a rewriting relation, and nothing else. Events are
          values. Filters are predicates. The world touches the edges.
        </p>
        <div class="cta">
          <button class="btn primary" @click=${this.enter}>Open the client</button>
          <a class="btn" href="https://github.com/sagar-shirwalkar/krivostr" target="_blank">Read the source</a>
        </div>
      </section>
      <div class="demo" aria-hidden="true">
        <div><span class="prompt">λ&gt;</span> connect <span class="comment">-- relays</span></div>
        <div><span class="ok">✓</span> wss://relay.damus.io</div>
        <div><span class="ok">✓</span> wss://nos.lol</div>
        <div><span class="ok">✓</span> wss://relay.primal.net</div>
        <div><span class="prompt">λ&gt;</span> subscribe { kinds: [1], limit: 50 }</div>
        <div><span class="ok">←</span> 50 events reduced <span class="cursor"></span></div>
      </div>
      <section class="features">
        <article class="feature">
          <span class="num">01 / core</span>
          <h3>Pure by construction</h3>
          <p>The Haskell core has no I/O. Signing is a function. Filtering is a predicate. The canonical NIP‑01 bytes are a pure projection of the event term.</p>
        </article>
        <article class="feature">
          <span class="num">02 / algebra</span>
          <h3>Rules, not branches</h3>
          <p>Filters compose with <code>and</code>/<code>or</code>/<code>not</code> — no ad-hoc if/else chains. The same pure logic runs in Haskell and TypeScript, so what the bridge accepts is exactly what the UI sends.</p>
        </article>
        <article class="feature">
          <span class="num">03 / history</span>
          <h3>Yours to keep</h3>
          <p>Relays forget. krivostr caches a month of public events in IndexedDB, and keeps DMs, follows, and relay lists forever — on your device.</p>
        </article>
      </section>
      <footer>
        <span>AGPL-3.0 · built in the open</span>
        <span>λ (λx.x) (λx.x)</span>
      </footer>
    `;
  }
}
