import { describe, it, expect } from 'vitest';
import { parseEvent, canonicalBytes, tagValue, isReply, ageSeconds } from '../nostr/event';

const valid = {
  id: 'a'.repeat(64),
  pubkey: 'b'.repeat(64),
  created_at: 1700000000,
  kind: 1,
  tags: [],
  content: 'hello',
  sig: 'c'.repeat(128),
};

describe('parseEvent', () => {
  it('accepts a valid event', () => {
    const r = parseEvent(valid);
    expect(r._tag).toBe('Ok');
  });

  it('rejects null', () => {
    expect(parseEvent(null)._tag).toBe('Err');
  });

  it('rejects a missing field', () => {
    const { id, ...rest } = valid;
    expect(parseEvent(rest)._tag).toBe('Err');
  });

  it('rejects wrong types', () => {
    expect(parseEvent({ ...valid, created_at: 'nope' })._tag).toBe('Err');
    expect(parseEvent({ ...valid, tags: 'x' })._tag).toBe('Err');
  });
});

describe('canonicalBytes', () => {
  it('produces the NIP-01 array serialization', () => {
    const bytes = canonicalBytes({
      pubkey: 'p', created_at: 0, kind: 1, tags: [], content: '',
    });
    expect(new TextDecoder().decode(bytes)).toBe('[0,"p",0,1,[],""]');
  });
});

describe('tagValue', () => {
  it('finds the first tag with the given name', () => {
    const e = { ...valid, tags: [['e', 'root'], ['e', 'reply'], ['p', 'x']] };
    expect(tagValue(e, 'e')).toBe('root');
    expect(tagValue(e, 'p')).toBe('x');
    expect(tagValue(e, 'z')).toBeUndefined();
  });
});

describe('isReply', () => {
  it('detects e tags', () => {
    expect(isReply({ ...valid, tags: [['e', 'x']] })).toBe(true);
    expect(isReply(valid)).toBe(false);
  });
});

describe('ageSeconds', () => {
  it('computes age', () => {
    expect(ageSeconds(valid, 1700000100)).toBe(100);
  });
});
