import { describe, it, expect } from 'vitest';
import { pipe, compose, identity, constant } from '../fp/pipe';

describe('pipe', () => {
  it('returns the value for a single argument', () => {
    expect(pipe(1)).toBe(1);
  });

  it('chains unary functions', () => {
    const inc = (n: number) => n + 1;
    const double = (n: number) => n * 2;
    expect(pipe(1, inc, double)).toBe(4);
  });

  it('chains four functions', () => {
    const inc = (n: number) => n + 1;
    expect(pipe(1, inc, inc, inc, inc)).toBe(5);
  });
});

describe('compose', () => {
  it('is right-to-left', () => {
    const inc = (n: number) => n + 1;
    const double = (n: number) => n * 2;
    expect(compose(inc, double)(2)).toBe(5);
  });
});

describe('identity / constant', () => {
  it('identity returns its argument', () => {
    expect(identity(5)).toBe(5);
    expect(identity('x')).toBe('x');
  });

  it('constant ignores its argument', () => {
    expect(constant(1)(999)).toBe(1);
  });
});
