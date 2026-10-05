import { describe, it, expect } from 'vitest';
import { parseRelayInfo, decodeRelayInfo, supportsNip } from '../nostr/nip11';

describe('parseRelayInfo', () => {
  it('parses a full document with snake_case mapped to camelCase', () => {
    const r = parseRelayInfo({
      name: 'example',
      supported_nips: [1, 11, 42],
      limitation: { max_message_length: 16384, auth_required: true },
    });
    expect(r._tag).toBe('Ok');
    if (r._tag !== 'Ok') return;
    expect(r.value.name).toBe('example');
    expect(r.value.supportedNips).toEqual([1, 11, 42]);
    expect(r.value.limitation).toEqual({ maxMessageLength: 16384, authRequired: true });
  });
  it('accepts an empty document — every field is optional', () => {
    expect(parseRelayInfo({})).toEqual({ _tag: 'Ok', value: {} });
  });
  it('drops mistyped fields instead of failing the document', () => {
    const r = parseRelayInfo({ name: 42, supported_nips: 'nope' });
    expect(r).toEqual({ _tag: 'Ok', value: {} });
  });
  it('rejects a non-object', () => {
    expect(parseRelayInfo(null)._tag).toBe('Err');
    expect(parseRelayInfo([])._tag).toBe('Err');
  });
});

describe('decodeRelayInfo', () => {
  it('parses JSON text', () => {
    const r = decodeRelayInfo('{"name":"r","supported_nips":[11]}');
    expect(r._tag).toBe('Ok');
  });
  it('rejects invalid JSON', () => {
    expect(decodeRelayInfo('not json')._tag).toBe('Err');
  });
});

describe('supportsNip', () => {
  it('is true only for listed NIPs', () => {
    const r = decodeRelayInfo('{"supported_nips":[1,42]}');
    if (r._tag !== 'Ok') throw new Error('fixture failed');
    expect(supportsNip(42, r.value)).toBe(true);
    expect(supportsNip(11, r.value)).toBe(false);
  });
  it('is false when the relay lists nothing', () => {
    const r = parseRelayInfo({});
    if (r._tag !== 'Ok') throw new Error('fixture failed');
    expect(supportsNip(1, r.value)).toBe(false);
  });
});
