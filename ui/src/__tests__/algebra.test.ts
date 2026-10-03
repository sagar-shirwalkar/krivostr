import { describe, it, expect } from 'vitest';
import {
  ArrayMonoid, StringMonoid, rule, and, or, not, evaluate, allOf, anyOf, validate,
} from '../fp/algebra';
import { Ok, Err } from '../fp/result';

describe('Monoid', () => {
  it('ArrayMonoid concatenates', () => {
    const M = ArrayMonoid<number>();
    expect(M.concat([1], [2, 3])).toEqual([1, 2, 3]);
    expect(M.empty).toEqual([]);
  });

  it('ArrayMonoid obeys left identity', () => {
    const M = ArrayMonoid<number>();
    expect(M.concat(M.empty, [1, 2])).toEqual([1, 2]);
  });

  it('StringMonoid concatenates', () => {
    expect(StringMonoid.concat('a', 'b')).toBe('ab');
    expect(StringMonoid.empty).toBe('');
  });
});

describe('Rules', () => {
  const isPositive = rule<number>('pos', 'must be > 0', (n) => n > 0);
  const isEven = rule<number>('even', 'must be even', (n) => n % 2 === 0);

  it('evaluate returns Ok on pass', () => {
    expect(evaluate(isPositive)(1)).toEqual(Ok(1));
  });

  it('evaluate returns Err on fail', () => {
    const r = evaluate(isPositive)(-1);
    expect(r._tag).toBe('Err');
  });

  it('and requires both', () => {
    const r = and(isPositive, isEven);
    expect(r.test(2)).toBe(true);
    expect(r.test(3)).toBe(false);
    expect(r.test(-2)).toBe(false);
  });

  it('or requires either', () => {
    const r = or(isPositive, isEven);
    expect(r.test(2)).toBe(true);
    expect(r.test(3)).toBe(true);
    expect(r.test(-3)).toBe(false);
  });

  it('not inverts', () => {
    const r = not(isPositive);
    expect(r.test(-1)).toBe(true);
    expect(r.test(1)).toBe(false);
  });

  it('allOf combines names', () => {
    const r = allOf(isPositive, isEven);
    expect(r.name).toBe('pos ∧ even');
    expect(r.test(2)).toBe(true);
  });

  it('anyOf combines names', () => {
    const r = anyOf(isPositive, isEven);
    expect(r.name).toBe('pos ∨ even');
  });
});

describe('validate', () => {
  it('returns Ok when all checks pass', () => {
    const check = validate<Error, number>([
      (n) => (n > 0 ? Ok(n) : Err(new Error('neg'))),
      (n) => (n < 100 ? Ok(n) : Err(new Error('big'))),
    ]);
    const r = check(5);
    expect(r._tag).toBe('Ok');
  });

  it('returns Err when a check fails', () => {
    const check = validate<Error, number>([
      (n) => (n > 0 ? Ok(n) : Err(new Error('neg'))),
    ]);
    const r = check(-1);
    expect(r._tag).toBe('Err');
  });
});
