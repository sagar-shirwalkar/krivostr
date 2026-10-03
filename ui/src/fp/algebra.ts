/**
 * The event algebra.
 * Instead of a grab‑bag of helpers, we define the two operations every
 * reducer in the app is built from: `fold` and `map`, and the laws they
 * must satisfy. Components consume the algebra, not ad‑hoc functions.
 */

import { Result, Ok, Err } from './result';

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

/**
 * A validated value: parse once, then trust.
 *
 * The error is a *list* because validation accumulates rather than
 * short-circuits: the caller can report every problem at once instead of
 * making the user rediscover them one at a time.
 */
export type Validated<E, A> = Result<E[], A>;

/**
 * Run every check, collecting all failures.
 *
 * A check may also transform the value, so each one receives the last
 * successful result. A failing check contributes its error and leaves the
 * running value alone, which is what lets the remaining checks still report
 * instead of the whole thing stopping at the first problem.
 */
export const validate = <E, A>(
  checks: Array<(a: A) => Result<E, A>>,
) => (a: A): Validated<E, A> => {
  const errors: E[] = [];
  let value = a;
  for (const check of checks) {
    const result = check(value);
    if (result._tag === 'Err') errors.push(result.error);
    else value = result.value;
  }
  return errors.length > 0 ? Err(errors) : Ok(value);
};

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
