import { describe, it, expect } from 'vitest';
import {
  parseWalletUri,
  methodFromText,
  allMethods,
  buildRequestTags,
  parseResponse,
  parseInfoMethods,
  requestEventKind,
  responseEventKind,
  infoEventKind,
} from '../nostr/nip47';

const URI =
  'nostr+walletconnect://' + 'a'.repeat(64) +
  '?relay=wss%3A%2F%2Fr1.example&relay=wss%3A%2F%2Fr2.example' +
  '&secret=' + 'b'.repeat(64) +
  '&lud16=me%40example.com';

describe('parseWalletUri', () => {
  it('parses pubkey, relays, secret, and lud16', () => {
    expect(parseWalletUri(URI)).toEqual({
      _tag: 'Ok',
      value: {
        walletPubkey: 'a'.repeat(64),
        relays: ['wss://r1.example', 'wss://r2.example'],
        secret: 'b'.repeat(64),
        lud16: 'me@example.com',
      },
    });
  });
  it('rejects wrong schemes, short keys, and missing secrets', () => {
    expect(parseWalletUri('https://example.com')._tag).toBe('Err');
    expect(parseWalletUri('nostr+walletconnect://abc?secret=def')._tag).toBe('Err');
    expect(parseWalletUri(`nostr+walletconnect://${'a'.repeat(64)}`)._tag).toBe('Err');
  });
});

describe('methods', () => {
  it('knows the core table and nothing else', () => {
    expect(allMethods).toHaveLength(9);
    expect(methodFromText('pay_invoice')).toEqual({ _tag: 'Ok', value: 'pay_invoice' });
    expect(methodFromText('zap_zap')._tag).toBe('Err');
  });
});

describe('buildRequestTags', () => {
  it('names NIP-44 mode and the service', () => {
    expect(buildRequestTags('a'.repeat(64))).toEqual([
      ['encryption', 'nip44_v2'],
      ['p', 'a'.repeat(64)],
    ]);
  });
});

describe('parseResponse', () => {
  it('decodes results and errors', () => {
    expect(parseResponse({ result_type: 'get_balance', result: { balance: 10000 }, error: null })).toEqual({
      _tag: 'Ok',
      value: { type: 'get_balance', result: { balance: 10000 }, error: undefined },
    });
    expect(
      parseResponse({ result_type: 'pay_invoice', error: { code: 'PAYMENT_FAILED', message: 'nope' } }),
    ).toEqual({
      _tag: 'Ok',
      value: {
        type: 'pay_invoice',
        result: undefined,
        error: { code: 'PAYMENT_FAILED', message: 'nope' },
      },
    });
  });
  it('rejects unknown methods and malformed errors', () => {
    expect(parseResponse({ result_type: 'zap_zap' })._tag).toBe('Err');
    expect(parseResponse({ result_type: 'get_balance', error: { code: 1 } })._tag).toBe('Err');
    expect(parseResponse(null)._tag).toBe('Err');
  });
});

describe('parseInfoMethods / kinds', () => {
  it('splits the capability advertisement', () => {
    expect(parseInfoMethods('pay_invoice get_balance  make_invoice')).toEqual([
      'pay_invoice',
      'get_balance',
      'make_invoice',
    ]);
  });
  it('uses 13194, 23194, and 23195', () => {
    expect([infoEventKind, requestEventKind, responseEventKind]).toEqual([13194, 23194, 23195]);
  });
});
