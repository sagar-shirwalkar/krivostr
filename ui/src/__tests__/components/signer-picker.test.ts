import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { page } from 'vitest/browser';
import '../../components/nostr-signer-picker';
import type { KrivostrSignerPicker } from '../../components/nostr-signer-picker';
import { nsecEncode } from '../../nostr/bech32';

const NSEC = nsecEncode('01'.repeat(32));

describe('<krivostr-signer-picker>', () => {
  let el: KrivostrSignerPicker;

  beforeEach(() => {
    el = document.createElement('krivostr-signer-picker') as KrivostrSignerPicker;
    document.body.appendChild(el);
  });

  afterEach(() => el.remove());

  const typeNsec = async () => {
    const input = el.shadowRoot!.querySelector('input')!;
    input.value = NSEC;
    input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    await el.updateComplete;
  };

  const cont = () =>
    [...el.shadowRoot!.querySelectorAll('button')].find((b) => b.textContent === 'continue')!;

  it('asks for risk acknowledgment before using a pasted key', async () => {
    const chosen: CustomEvent[] = [];
    el.addEventListener('signer-chosen', (e) => chosen.push(e as CustomEvent));
    await typeNsec();
    cont().click();
    await el.updateComplete;
    await expect.element(page.getByText('Pasting a key decrypts it here')).toBeVisible();
    expect(chosen).toHaveLength(0);
  });

  it('proceeds after acknowledgment and cancels cleanly', async () => {
    const chosen: CustomEvent[] = [];
    el.addEventListener('signer-chosen', (e) => chosen.push(e as CustomEvent));
    await typeNsec();
    cont().click();
    await el.updateComplete;
    const ack = [...el.shadowRoot!.querySelectorAll('button')].find((b) =>
      b.textContent!.includes('I understand'),
    )!;
    ack.click();
    await el.updateComplete;
    expect(chosen).toHaveLength(1);
  });

  it('advises the bunker next to the heading', async () => {
    await el.updateComplete;
    const info = el.shadowRoot!.querySelector('.info')!;
    expect(info.getAttribute('title')).toMatch(/bunker/);
    const bunker = [...el.shadowRoot!.querySelectorAll('.opt')].find((b) =>
      b.textContent!.includes('bunker (NIP-46)'),
    )!;
    expect(bunker.getAttribute('title')).toMatch(/Amber/);
  });
});
