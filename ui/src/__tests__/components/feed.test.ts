import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { page } from 'vitest/browser';
import '../../components/nostr-feed';
import type { NostrFeed } from '../../components/nostr-feed';

const ev = (id: string, content: string) => ({
  id, pubkey: 'p'.repeat(64), created_at: 1700000000,
  kind: 1, tags: [], content, sig: 's'.repeat(128),
});

describe('<nostr-feed>', () => {
  let el: NostrFeed;

  beforeEach(() => {
    el = document.createElement('nostr-feed') as NostrFeed;
    document.body.appendChild(el);
  });

  afterEach(() => {
    el.remove();
  });

  it('shows empty state initially', async () => {
    await el.updateComplete;
    await expect.element(page.getByText('// no events yet')).toBeVisible();
  });

  it('renders pushed events', async () => {
    el.push(ev('1'.repeat(64), 'hello world'));
    await el.updateComplete;
    await expect.element(page.getByText('hello world')).toBeVisible();
  });

  it('deduplicates by id', async () => {
    el.push(ev('1'.repeat(64), 'once'));
    el.push(ev('1'.repeat(64), 'twice'));
    await el.updateComplete;
    const articles = el.shadowRoot!.querySelectorAll('article');
    expect(articles).toHaveLength(1);
  });

  it('prepends newest first', async () => {
    el.push(ev('1'.repeat(64), 'first'));
    el.push(ev('2'.repeat(64), 'second'));
    await el.updateComplete;
    const texts = [...el.shadowRoot!.querySelectorAll('.body')].map((n) => n.textContent);
    expect(texts[0]).toContain('second');
  });

  it('keys rows by event id', async () => {
    el.push(ev('1'.repeat(64), 'first'));
    el.push(ev('2'.repeat(64), 'second'));
    await el.updateComplete;
    const rows = [...el.shadowRoot!.querySelectorAll('.feedrow')].map((n) =>
      (n as HTMLElement).dataset.eid,
    );
    expect(rows).toEqual(['2'.repeat(64), '1'.repeat(64)]);
  });
});

describe('<nostr-feed> tombstones', () => {
  /**
   * Controllable stand-in for IntersectionObserver: tests drive visibility
   * by hand instead of scrolling a real viewport.
   */
  class FakeIO {
    els = new Set<Element>();
    constructor(private cb: IntersectionObserverCallback) {}
    observe = (el: Element): void => {
      this.els.add(el);
    };
    unobserve = (el: Element): void => {
      this.els.delete(el);
    };
    disconnect = (): void => {
      this.els.clear();
    };
    fire = (ids: string[], intersecting: boolean): void => {
      this.cb(
        [...this.els]
          .filter((el) => ids.includes((el as HTMLElement).dataset.eid ?? ''))
          .map(
            (el) =>
              ({ target: el, isIntersecting: intersecting }) as IntersectionObserverEntry,
          ),
        this as unknown as IntersectionObserver,
      );
    };
  }

  let el: NostrFeed;
  let io: FakeIO;

  beforeEach(async () => {
    vi.stubGlobal(
      'IntersectionObserver',
      class {
        constructor(cb: IntersectionObserverCallback) {
          io = new FakeIO(cb);
        }
        observe = (el: Element): void => io.observe(el);
        unobserve = (el: Element): void => io.unobserve(el);
        disconnect = (): void => io.disconnect();
      },
    );
    const { NostrFeed: Feed } = await import('../../components/nostr-feed');
    void Feed;
    el = document.createElement('nostr-feed') as NostrFeed;
    document.body.appendChild(el);
    await el.updateComplete;
  });

  afterEach(() => {
    el.remove();
    vi.unstubAllGlobals();
  });

  it('prunes far rows to measured-height tombstones and restores them', async () => {
    el.push(ev('1'.repeat(64), 'near'));
    el.push(ev('2'.repeat(64), 'far'));
    await el.updateComplete;
    // Both measured on screen first: tombstones need a real height.
    io.fire(['1'.repeat(64), '2'.repeat(64)], true);
    await el.updateComplete;
    expect(el.shadowRoot!.querySelectorAll('article')).toHaveLength(2);
    // The far row leaves: article out, same-height placeholder in.
    io.fire(['2'.repeat(64)], false);
    await el.updateComplete;
    expect(el.shadowRoot!.querySelectorAll('article')).toHaveLength(1);
    const tomb = el.shadowRoot!.querySelector('.tombstone') as HTMLElement;
    expect(tomb).toBeTruthy();
    expect(tomb.style.height).toMatch(/^\d+px$/);
    expect(tomb.style.height).not.toBe('0px');
    // Scrolling back restores the full note from the retained data.
    io.fire(['2'.repeat(64)], true);
    await el.updateComplete;
    expect(el.shadowRoot!.querySelectorAll('article')).toHaveLength(2);
  });
});
