import { describe, it, expect } from 'vitest';
import { contentWarningOf, isSensitive } from '../nostr/sensitive';

const tags = (t: string[][]) => ({ tags: t });

describe('contentWarningOf', () => {
  it('reads the reason', () => {
    expect(contentWarningOf(tags([['content-warning', 'nudity']]))).toBe('nudity');
  });
  it('treats a reasonless tag as still sensitive', () => {
    expect(contentWarningOf(tags([['content-warning']]))).toBe('');
  });
  it('finds no warning without the tag', () => {
    expect(contentWarningOf(tags([['t', 'x']]))).toBeUndefined();
    expect(contentWarningOf(tags([]))).toBeUndefined();
  });
});

describe('isSensitive', () => {
  it('is true with or without a reason', () => {
    expect(isSensitive(tags([['content-warning', 'x']]))).toBe(true);
    expect(isSensitive(tags([['content-warning']]))).toBe(true);
    expect(isSensitive(tags([]))).toBe(false);
  });
});
