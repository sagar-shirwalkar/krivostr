import { describe, it, expect } from 'vitest';
import * as M from '../fp/maybe';

describe('Maybe', () => {
  it('constructs Just and Nothing', () => {
    expect(M.isJust(M.Just(1))).toBe(true);
    expect(M.isNothing(M.Nothing())).toBe(true);
  });

  it('maps over Just', () => {
    expect(M.map((x: number) => x * 2)(M.Just(2))).toEqual(M.Just(4));
  });

  it('does not map over Nothing', () => {
    expect(M.map((x: number) => x * 2)(M.Nothing())).toEqual(M.Nothing());
  });

  it('flatMaps', () => {
    expect(M.flatMap((x: number) => M.Just(x + 1))(M.Just(1))).toEqual(M.Just(2));
    expect(M.flatMap((_: number) => M.Nothing())(M.Just(1))).toEqual(M.Nothing());
    expect(M.flatMap((x: number) => M.Just(x))(M.Nothing())).toEqual(M.Nothing());
  });

  it('getOrElse', () => {
    expect(M.getOrElse(0)(M.Just(5))).toBe(5);
    expect(M.getOrElse(0)(M.Nothing())).toBe(0);
  });

  it('fromNullable', () => {
    expect(M.fromNullable(null)).toEqual(M.Nothing());
    expect(M.fromNullable(undefined)).toEqual(M.Nothing());
    expect(M.fromNullable(3)).toEqual(M.Just(3));
  });

  it('match', () => {
    const f = M.match(() => 'none', (n: number) => `n=${n}`);
    expect(f(M.Just(2))).toBe('n=2');
    expect(f(M.Nothing())).toBe('none');
  });
});
