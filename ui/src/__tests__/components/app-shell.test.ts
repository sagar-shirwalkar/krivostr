import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { page } from 'vitest/browser';
import '../../components/app-shell';
import type { KrivostrApp } from '../../components/app-shell';

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
});
