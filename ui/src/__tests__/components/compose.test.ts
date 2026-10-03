import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { page } from '@vitest/browser/context';
import '../../components/nostr-compose';
import type { NostrCompose } from '../../components/nostr-compose';
import { localSigner } from '../../nostr/signer';

const NSEC_HEX = '0000000000000000000000000000000000000000000000000000000000000001';

describe('<nostr-compose>', () => {
  let el: NostrCompose;

  beforeEach(() => {
    el = document.createElement('nostr-compose') as NostrCompose;
    document.body.appendChild(el);
  });

  afterEach(() => el.remove());

  it('disables submit when empty', async () => {
    el.signer = localSigner(NSEC_HEX);
    await el.updateComplete;
    const btn = el.shadowRoot!.querySelector('button')!;
    expect(btn.hasAttribute('disabled')).toBe(true);
  });

  it('emits publish-request on submit', async () => {
    el.signer = localSigner(NSEC_HEX);
    await el.updateComplete;
    const events: CustomEvent[] = [];
    el.addEventListener('publish-request', (e) => events.push(e as CustomEvent));
    const ta = el.shadowRoot!.querySelector('textarea')!;
    ta.value = 'hello';
    ta.dispatch
