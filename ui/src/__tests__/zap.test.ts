import { describe, it, expect, vi, afterEach } from 'vitest';
import {
  zapRequestOf,
  buildZapRequestTags,
  zapReceiptOf,
  isZapReceipt,
  invoiceAmountMsats,
  invoiceAmountSats,
  lnurlPayUrl,
  fetchPayParams,
  requestInvoice,
  profileLud,
} from '../nostr/zap';
import { NostrEvent } from '../nostr/event';

afterEach(() => vi.unstubAllGlobals());

const ev = (over: Partial<NostrEvent> = {}): NostrEvent => ({
  id: 'a'.repeat(64), pubkey: 'sender', created_at: 1700000000,
  kind: 9734, tags: [], content: 'Zap!', sig: 'c'.repeat(128),
  ...over,
});

const request = ev({
  pubkey: 'd'.repeat(64),
  tags: [['relays', 'wss://r'], ['amount', '21000'], ['p', 'recipient'], ['e', 'note-1']],
});

const receipt = (desc: string): NostrEvent =>
  ev({
    kind: 9735,
    tags: [['p', 'recipient'], ['P', 'sender'], ['e', 'note-1'], ['bolt11', 'lnbc210n1pwhatever'], ['description', desc]],
    content: '',
  });

describe('zapRequestOf / buildZapRequestTags', () => {
  it('parses relays, amount, recipient, event, and comment', () => {
    expect(zapRequestOf(request)).toEqual({
      recipient: 'recipient', amountMsats: 21000, relays: ['wss://r'],
      lnurl: undefined, event: 'note-1', address: undefined, comment: 'Zap!',
    });
  });
  it('rejects other kinds, missing p, and bad amounts', () => {
    expect(zapRequestOf(ev({ kind: 1, tags: [['p', 'r']] }))).toBeUndefined();
    expect(zapRequestOf(ev({ tags: [['amount', '1']] }))).toBeUndefined();
    expect(zapRequestOf(ev({ tags: [['p', 'r'], ['amount', 'many']] }))).toBeUndefined();
  });
  it('builds request tags', () => {
    expect(buildZapRequestTags('r', 21000, ['wss://r'], undefined, 'note-1', undefined)).toEqual([
      ['relays', 'wss://r'], ['amount', '21000'], ['p', 'r'], ['e', 'note-1'],
    ]);
  });
});

describe('zapReceiptOf', () => {
  it('parses the receipt and its embedded request', () => {
    const r = zapReceiptOf(
      receipt(JSON.stringify({ ...request, id: 'a'.repeat(64), sig: 'c'.repeat(128) })),
    );
    expect(r?.recipient).toBe('recipient');
    expect(r?.sender).toBe('sender');
    expect(r?.bolt11).toBe('lnbc210n1pwhatever');
    expect(r?.request?.comment).toBe('Zap!');
    expect(isZapReceipt(receipt('{}'))).toBe(true);
  });
  it('rejects other kinds and tagless receipts, keeps bad descriptions', () => {
    expect(zapReceiptOf(ev({ kind: 1, tags: [] }))).toBeUndefined();
    expect(zapReceiptOf(ev({ kind: 9735, tags: [['p', 'r']] }))).toBeUndefined();
    expect(zapReceiptOf(receipt('nope'))?.request).toBeUndefined();
  });
});

describe('invoice amounts', () => {
  it('decodes multipliers to millisats', () => {
    expect(invoiceAmountMsats('lnbc210n1pwhatever')).toBe(21000);
    expect(invoiceAmountMsats('lnbc1m1pwhatever')).toBe(1e8);
    expect(invoiceAmountMsats('lnbcrt500p1whatever')).toBe(50);
    expect(invoiceAmountMsats('lnbc1pwhatever')).toBeUndefined();
    expect(invoiceAmountMsats('not-an-invoice')).toBeUndefined();
  });
  it('divides whole amounts', () => {
    expect(invoiceAmountSats('lnbc210n1pwhatever')).toBe(21);
    expect(invoiceAmountSats('lnbc100p1pwhatever')).toBeUndefined();
  });
});

describe('lnurlPayUrl', () => {
  it('maps lightning addresses to the well-known path', () => {
    expect(lnurlPayUrl('alice@example.com')).toEqual({
      _tag: 'Ok',
      value: 'https://example.com/.well-known/lnurlp/alice',
    });
  });
  it('rejects non-addresses', () => {
    expect(lnurlPayUrl('not-an-address')._tag).toBe('Err');
  });
});

describe('fetchPayParams / requestInvoice', () => {
  it('fetches and validates pay params', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({
      ok: true,
      json: async () => ({ callback: 'https://x/cb', minSendable: 1000, maxSendable: 1e9, metadata: '[]' }),
    })));
    const r = await fetchPayParams('https://x/.well-known/lnurlp/a');
    expect(r._tag).toBe('Ok');
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 404 })));
    expect((await fetchPayParams('https://x'))._tag).toBe('Err');
  });
  it('requests an invoice and surfaces refusals', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, json: async () => ({ pr: 'lnbc...' }) })));
    expect(await requestInvoice('https://x/cb', 21000, '{}')).toEqual({ _tag: 'Ok', value: 'lnbc...' });
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, json: async () => ({ reason: 'nope' }) })));
    expect((await requestInvoice('https://x/cb', 1, '{}'))._tag).toBe('Err');
  });
});

describe('profileLud', () => {
  it('prefers lud16 and tolerates garbage', () => {
    expect(profileLud(JSON.stringify({ lud16: 'a@b.c', lud06: 'lnurl1x' }))).toBe('a@b.c');
    expect(profileLud(JSON.stringify({ lud06: 'lnurl1x' }))).toBe('lnurl1x');
    expect(profileLud('not json')).toBeUndefined();
    expect(profileLud('{}')).toBeUndefined();
  });
});
