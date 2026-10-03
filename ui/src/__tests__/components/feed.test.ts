import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { page } from '@vitest/browser/context';
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
});
