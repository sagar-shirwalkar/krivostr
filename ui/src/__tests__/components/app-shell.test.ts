import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { page } from 'vitest/browser';
import '../../components/app-shell';
import type { KrivostrApp } from '../../components/app-shell';
import { localSigner } from '../../nostr/signer';

describe('<krivostr-app>', () => {
  let el: KrivostrApp;

  beforeEach(() => {
    el = document.createElement('krivostr-app') as KrivostrApp;
    document.body.appendChild(el);
  });

  afterEach(() => el.remove());

  it('renders landing page initially', async () => {
    await el.updateComplete;
    await expect.element(page.getByText('The local-first Nostr engine.')).toBeVisible();
  });

  it('switches to app view on enter', async () => {
    await el.updateComplete;
    const landing = el.shadowRoot!.querySelector('krivostr-landing')!;
    landing.dispatchEvent(new CustomEvent('enter', { bubbles: true, composed: true }));
    await el.updateComplete;
    expect(el.shadowRoot!.querySelector('krivostr-signer-picker')).toBeTruthy();
  });

  it('echoes published events into the feed without waiting for echo', async () => {
    await el.updateComplete;
    const landing = el.shadowRoot!.querySelector('krivostr-landing')!;
    landing.dispatchEvent(new CustomEvent('enter', { bubbles: true, composed: true }));
    await el.updateComplete;
    const view = el.shadowRoot!.querySelector('.view')!;
    // Choose a signer through the real event contract.
    view.dispatchEvent(
      new CustomEvent('signer-chosen', {
        detail: { signer: localSigner('11'.repeat(32)) },
        bubbles: true,
        composed: true,
      }),
    );
    await el.updateComplete;
    // Publish through the real event contract; no relay echo needed.
    view.dispatchEvent(
      new CustomEvent('publish-request', {
        detail: { content: 'hello optimistic', kind: 1, tags: [] },
        bubbles: true,
        composed: true,
      }),
    );
    await expect.element(page.getByText('hello optimistic')).toBeVisible();
  });
});
