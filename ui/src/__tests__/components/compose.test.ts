import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import '../../components/nostr-compose';
import type { NostrCompose } from '../../components/nostr-compose';
import { localSigner } from '../../nostr/signer';

const NSEC_HEX =
  '0000000000000000000000000000000000000000000000000000000000000001';

describe('<nostr-compose>', () => {
  let el: NostrCompose;

  beforeEach(() => {
    el = document.createElement('nostr-compose') as NostrCompose;
    document.body.appendChild(el);
  });

  afterEach(() => el.remove());

  /**
   * Type into the textarea the way a person would.
   *
   * Assigning `value` does not notify Lit: the component only learns about text
   * through its `@input` listener, so a bare `ta.value = 'x'` leaves `text`
   * empty and the submit button stays disabled. The event has to be
   * `composed` as well as bubbling so it crosses the shadow root.
   */
  const type = async (text: string): Promise<HTMLTextAreaElement> => {
    const ta = el.shadowRoot!.querySelector('textarea')!;
    ta.value = text;
    ta.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    await el.updateComplete;
    return ta;
  };

  const button = (): HTMLButtonElement =>
    el.shadowRoot!.querySelector('button[type="submit"]')!;

  const collect = (): CustomEvent[] => {
    const events: CustomEvent[] = [];
    el.addEventListener('publish-request', (e) => events.push(e as CustomEvent));
    return events;
  };

  it('disables submit when empty', async () => {
    el.signer = localSigner(NSEC_HEX);
    await el.updateComplete;
    expect(button().hasAttribute('disabled')).toBe(true);
  });

  it('disables submit without a signer', async () => {
    el.signer = null;
    await type('hello');
    expect(button().hasAttribute('disabled')).toBe(true);
  });

  it('enables submit once there is text', async () => {
    el.signer = localSigner(NSEC_HEX);
    await type('hello');
    expect(button().hasAttribute('disabled')).toBe(false);
  });

  it('treats whitespace-only text as empty', async () => {
    el.signer = localSigner(NSEC_HEX);
    await type('   \n  ');
    expect(button().hasAttribute('disabled')).toBe(true);
  });

  it('emits publish-request on submit', async () => {
    el.signer = localSigner(NSEC_HEX);
    const events = collect();
    await type('hello');
    button().click();
    await el.updateComplete;

    expect(events).toHaveLength(1);
    expect(events[0].detail).toEqual({ content: 'hello', kind: 1, tags: [] });
  });

  it('includes NIP-10 tags when replying', async () => {
    el.signer = localSigner(NSEC_HEX);
    el.replyTo = {
      id: 'p'.repeat(64), pubkey: 'q'.repeat(64), created_at: 1700000000,
      kind: 1, tags: [], content: 'parent', sig: 'r'.repeat(128),
    };
    const events = collect();
    await type('answer');
    button().click();
    await el.updateComplete;

    expect(events).toHaveLength(1);
    expect(events[0].detail.tags).toEqual([
      ['e', 'p'.repeat(64), '', 'root'],
      ['p', 'q'.repeat(64)],
    ]);
  });

  it('trims the content it publishes', async () => {
    el.signer = localSigner(NSEC_HEX);
    const events = collect();
    await type('  hello  ');
    button().click();
    await el.updateComplete;

    expect(events[0].detail.content).toBe('hello');
  });

  it('clears the textarea after publishing', async () => {
    el.signer = localSigner(NSEC_HEX);
    await type('hello');
    button().click();
    await el.updateComplete;

    expect(el.shadowRoot!.querySelector('textarea')!.value).toBe('');
    expect(button().hasAttribute('disabled')).toBe(true);
  });

  it('does not publish without a signer', async () => {
    el.signer = null;
    const events = collect();
    await type('hello');
    // Bypass the disabled state to prove the handler itself also refuses.
    el.shadowRoot!.querySelector('form')!.dispatchEvent(
      new Event('submit', { bubbles: true, composed: true, cancelable: true }),
    );
    await el.updateComplete;

    expect(events).toHaveLength(0);
  });
});
