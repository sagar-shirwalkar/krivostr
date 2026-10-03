/**
 * The event algebra.
 * Instead of a grab‑bag of helpers, we define the two operations every
 * reducer in the app is built from: `fold` and `map`, and the laws they
 * must satisfy. Components consume the algebra, not ad‑hoc functions.
 */

import { Result, Ok, Err, flatMap, map } from './result';
import { Maybe, Just, Nothing, isJust } from './maybe';
import { pipe } from './pipe';

export interface Semigroup<A> {
  readonly concat: (a: A, b: A) => A;
}

export interface Monoid<A> extends Semigroup<A> {
  readonly empty: A;
}

export interface Functor<F> {
  readonly map: <A, B>(f: (a: A) => B) => (fa: F & { __a?: A }) => F & { __b?: B };
}

/** Array is our workhorse monoid for event streams. */
export const ArrayMonoid = <A>(): Monoid<A[]> => ({
  concat: (a, b) => a.concat(b),
  empty: [],
});

/** String is a monoid under concatenation. */
export const StringMonoid: Monoid<string> = {
  concat: (a, b) => a + b,
  empty: '',
};

/** A validated value: parse once, then trust. */
export type Validated<E, A> = Result<E[], A>;

export const validate = <E, A>(
  checks: Array<(a: A) => Result<E, A>>,
) => (a: A): Validated<E, A> =>
  checks.reduce<Validated<E, A>>(
    (acc, check) =>
      pipe(
        acc,
        flatMap((v) => pipe(check(v), map((x) => x))),
      ),
    Ok(a),
  );

/** The rule algebra: a predicate on A, composed with and/or/not. */
export interface Predicate<A> {
  readonly test: (a: A) => boolean;
}

export const and = <A>(p: Predicate<A>, q: Predicate<A>): Predicate<A> => ({
  test: (a) => p.test(a) && q.test(a),
});

export const or = <A>(p: Predicate<A>, q: Predicate<A>): Predicate<A> => ({
  test: (a) => p.test(a) || q.test(a),
});

export const not = <A>(p: Predicate<A>): Predicate<A> => ({
  test: (a) => !p.test(a),
});

/** A rule is a named predicate with a human‑readable description. */
export interface Rule<A> extends Predicate<A> {
  readonly name: string;
  readonly describe: string;
}

export const rule = <A>(
  name: string,
  describe: string,
  test: (a: A) => boolean,
): Rule<A> => ({ name, describe, test });

export const evaluate = <A>(r: Rule<A>) => (a: A): Result<string, A> =>
  r.test(a) ? Ok(a) : Err(`${r.name}: ${r.describe}`);

export const allOf = <A>(...rules: Rule<A>[]): Rule<A> =>
  rule(
    rules.map((r) => r.name).join(' ∧ '),
    rules.map((r) => r.describe).join('; '),
    (a) => rules.every((r) => r.test(a)),
  );

export const anyOf = <A>(...rules: Rule<A>[]): Rule<A> =>
  rule(
    rules.map((r) => r.name).join(' ∨ '),
    rules.map((r) => r.describe).join('; '),
    (a) => rules.some((r) => r.test(a)),
  );
