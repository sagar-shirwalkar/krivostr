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
    .nav .mark { color: var(--text); letter-spacing: 0.05em; display: flex; align-items: center; gap: var(--s-2); cursor: pointer; }
    .nav .mark:hover { color: var(--amber); }
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
      max-width: 620px; margin-bottom: var(--s-5);
    }
    .lede .nostr-link {
      color: var(--amber); text-decoration: underline; text-underline-offset: 2px;
      cursor: pointer; transition: color var(--dur) var(--ease);
    }
    .lede .nostr-link:hover { color: var(--amber-dim); }
    .synergy {
      font-size: var(--step-1); color: var(--text-dim); line-height: 1.6;
      max-width: 620px; margin-bottom: var(--s-7); padding-left: var(--s-4);
      border-left: 2px solid var(--amber);
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
    .revere {
      margin-bottom: var(--s-10); padding: var(--s-6);
      background: linear-gradient(135deg, var(--ink-2) 0%, var(--graphite-2) 100%);
      border: 1px solid var(--border); border-radius: var(--radius-lg);
      font-family: var(--font-mono); font-size: var(--step-0);
      color: var(--paper-2); line-height: 1.6; position: relative; overflow: hidden;
      cursor: pointer;
    }
    .revere::before {
      content: ''; position: absolute; inset: 0;
      background: radial-gradient(ellipse at center, var(--amber) 0%, transparent 70%);
      opacity: 0; transition: opacity var(--dur) var(--ease);
    }
    .revere:hover::before { opacity: 0.08; }
    .revere .quote { position: relative; z-index: 1; }
    .revere .quote mark { background: transparent; color: var(--amber); font-weight: 500; }
    .revere .cite { display: block; margin-top: var(--s-3); font-size: var(--step--1); color: var(--mute); }
    .revere .hint { position: absolute; bottom: var(--s-2); right: var(--s-3);
      font-size: var(--step--2); color: var(--mute); opacity: 0; transition: opacity var(--dur);
    }
    .revere:hover .hint { opacity: 1; }
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
        <div class="mark" @click=${this.enter}>
          KRIVOSTR<span style="color:var(--mute)">/0.4.2</span>
        </div>
        <nav>
          <a href="https://github.com/nostr-protocol/nostr" target="_blank">protocol</a>
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
          krivostr is a <span class="nostr-link" @click=${(e: Event) => { e.stopPropagation(); window.open('https://nostr.org/', '_blank'); }}>Nostr</span> client built like a Krivine machine: a small set of
          immutable terms, a rewriting relation, and nothing else. Events are
          values. Filters are predicates. The world touches the edges.
        </p>
        <p class="synergy">
          This pure functional approach is naturally synergistic with <span class="nostr-link" @click=${(e: Event) => { e.stopPropagation(); window.open('https://nostr.org/', '_blank'); }}>Nostr</span>'s objectives: 
          privacy and security through strong cryptography. 
          When your core logic is pure—no hidden state, no side effects—there's 
          no room for silent data leaks or supply-chain attacks. 
          What the bridge accepts is exactly what the UI sends; what you sign is 
          exactly what relays receive. Purity is the ultimate audit trail.
        </p>
        <div class="cta">
          <button class="btn primary" @click=${this.enter}>Open the client</button>
          <a class="btn" href="https://github.com/sagar-shirwalkar/krivostr" target="_blank">Read the source</a>
        </div>
      </section>
      <div class="demo" aria-hidden="true">
        <div><span class="prompt">λ></span> connect <span class="comment">-- relays</span></div>
        <div><span class="ok">✓</span> wss://relay.damus.io</div>
        <div><span class="ok">✓</span> wss://nos.lol</div>
        <div><span class="ok">✓</span> wss://relay.primal.net</div>
        <div><span class="prompt">λ></span> subscribe { kinds: [1], limit: 50 }</div>
        <div><span class="ok">←</span> 50 events reduced <span class="cursor"></span></div>
      </div>
      <section class="features">
        <article class="feature">
          <span class="num">01 / core</span>
          <h3>Pure by construction</h3>
          <p>Haskell's purity isn't academic—it's battle-tested. The same guarantees that secure 
          high-value banking operations (zero side effects, deterministic outputs) protect your 
          keys here. Signing is a pure function. Filtering is a pure predicate. The canonical 
          NIP‑01 bytes are a pure projection of the event term. No I/O. No hidden state. No surprises.</p>
        </article>
        <article class="feature">
          <span class="num">02 / algebra</span>
          <h3>Rules, not branches</h3>
          <p>Filters compose with <code>and</code>/<code>or</code>/<code>not</code> — no ad-hoc if/else chains. 
          The UI re‑expresses the same pure algebra in TypeScript with hand‑rolled <code>Maybe</code>, 
          <code>Result</code>, and <code>IO</code>. What the bridge accepts is exactly what the UI sends; 
          what the relay receives is exactly what you signed. Purity across the stack = high security.</p>
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
