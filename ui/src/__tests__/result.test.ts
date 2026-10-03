import { describe, it, expect } from 'vitest';
import * as R from '../fp/result';

describe('Result', () => {
  it('constructs Ok and Err', () => {
    expect(R.isOk(R.Ok(1))).toBe(true);
    expect(R.isErr(R.Err('x'))).toBe(true);
  });

  it('maps over Ok', () => {
    expect(R.map((n: number) => n + 1)(R.Ok(1))).toEqual(R.Ok(2));
    expect(R.map((n: number) => n + 1)(R.Err('e'))).toEqual(R.Err('e'));
  });

  it('maps error', () => {
    expect(R.mapErr((s: string) => s.toUpperCase())(R.Err('e'))).toEqual(R.Err('E'));
    expect(R.mapErr((s: string) => s.toUpperCase())(R.Ok(1))).toEqual(R.Ok(1));
  });

  it('flatMaps', () => {
    const f = (n: number) => (n > 0 ? R.Ok(n * 2) : R.Err('neg'));
    expect(R.flatMap(f)(R.Ok(2))).toEqual(R.Ok(4));
    expect(R.flatMap(f)(R.Ok(-1))).toEqual(R.Err('neg'));
    expect(R.flatMap(f)(R.Err('x'))).toEqual(R.Err('x'));
  });

  it('getOrElse', () => {
    expect(R.getOrElse(0)(R.Ok(5))).toBe(5);
    expect(R.getOrElse(0)(R.Err('e'))).toBe(0);
  });

  it('match', () => {
    const f = R.match((e: string) => `err:${e}`, (n: number) => `ok:${n}`);
    expect(f(R.Ok(1))).toBe('ok:1');
    expect(f(R.Err('bad'))).toBe('err:bad');
  });

  it('fromPromise resolves Ok on success', async () => {
    const r = await R.fromPromise(Promise.resolve(3), String);
    expect(r).toEqual(R.Ok(3));
  });

  it('fromPromise resolves Err on failure', async () => {
    const r = await R.fromPromise(Promise.reject(new Error('nope')), (e) => String(e));
    expect(R.isErr(r)).toBe(true);
  });
});
