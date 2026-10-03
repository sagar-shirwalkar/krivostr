/**
 * pipe / compose — the two primitives for point‑free composition.
 * pipe(a, f, g) === g(f(a)). compose(f, g)(a) === f(g(a)).
 */

export function pipe<A>(a: A): A;
export function pipe<A, B>(a: A, ab: (a: A) => B): B;
export function pipe<A, B, C>(a: A, ab: (a: A) => B, bc: (b: B) => C): C;
export function pipe<A, B, C, D>(
  a: A, ab: (a: A) => B, bc: (b: B) => C, cd: (c: C) => D,
): D;
export function pipe<A, B, C, D, E>(
  a: A, ab: (a: A) => B, bc: (b: B) => C, cd: (c: C) => D, de: (d: D) => E,
): E;
export function pipe(a: unknown, ...fns: Array<(x: unknown) => unknown>): unknown {
  return fns.reduce((acc, fn) => fn(acc), a);
}

export const compose = <A, B, C>(f: (b: B) => C, g: (a: A) => B) =>
  (a: A): C => f(g(a));

export const identity = <A>(a: A): A => a;

export const constant = <A>(a: A) => <B>(_: B): A => a;
