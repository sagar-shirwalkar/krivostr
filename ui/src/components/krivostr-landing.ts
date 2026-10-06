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
    h1 {
      font-size: var(--step-5); line-height: 0.98;
      letter-spacing: -0.035em; font-weight: 500; margin-bottom: var(--s-5);
    }
    h1 em { font-style: normal; color: var(--amber); font-family: var(--font-mono); font-weight: 400; }
    .lede {
      font-size: var(--step-2); color: var(--text); line-height: 1.5;
      max-width: 620px; margin-bottom: var(--s-4);
    }
    .sub {
      font-size: var(--step-1); color: var(--text-dim); line-height: 1.6;
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
    .stack-callout {
      border: 1px solid var(--border); border-radius: var(--radius-lg);
      padding: var(--s-4) var(--s-5); margin-bottom: var(--s-10);
      font-family: var(--font-mono); font-size: var(--step--1); color: var(--mute);
    }
    .stack-callout p { margin: 0; }
    .stack-callout strong { color: var(--amber); font-weight: 500; }
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
          Krivostr<span style="color:var(--mute)">/0.6.2</span>
        </div>
        <nav>
          <a href="https://github.com/nostr-protocol/nostr" target="_blank">protocol</a>
        </nav>
      </header>
      <section class="hero">
        <h1>krivostr</h1>
        <p class="lede">The local-first Nostr engine.</p>
        <p class="sub">
          An offline-capable archive, a multiplexing bridge, and a headless CLI.
          Built for researchers, bots, and people who follow way too many people.
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
          <span class="num">01 / vault</span>
          <h3>Relays forget. Your store does not.</h3>
          <p>Public relays drop old events and rate-limit your history. krivostr ingests your firehose into a local SQLite vault with FTS5 indexing. Search millions of cryptographically verified notes in milliseconds, read your timeline on a flight, and keep your state—follows, mutes, and DMs—forever.</p>
        </article>
        <article class="feature">
          <span class="num">02 / core</span>
          <h3>Pure by construction.</h3>
          <p>Your private keys shouldn't live in a chaotic browser runtime. The cryptographic core is pure Haskell—zero I/O, zero side effects. From BIP-340 Schnorr signatures to NIP-44 v2 encrypted payloads, every byte is deterministic and mathematically verified before it ever touches your disk.</p>
        </article>
        <article class="feature">
          <span class="num">03 / bridge</span>
          <h3>More than a client.</h3>
          <p>Run it headless as a team caching proxy, an algorithmic trading bot, or an offline daemon. The local bridge multiplexes upstream relays, silently answers NIP-42 auth challenges, and queues your NIP-17 gift-wrapped messages when you go off-grid. Query your archive via SQL or the CLI.</p>
        </article>
      </section>
      <div class="stack-callout">
        <p><strong>The Stack:</strong> Pure Haskell Core • SQLite + FTS5 Vault • Warp WebSocket Bridge • Lit 3 UI • NIP-01/17/42/44/59 Compliant</p>
      </div>
      <footer>
        <span>AGPL-3.0 · built in the open</span>
        <span>K = Y (λM. λ⟨t,π,ρ⟩. t ρ @ π ▷ M)</span>
      </footer>
    `;
  }
}
