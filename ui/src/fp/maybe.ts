/**
 * Maybe<A> — a hand‑rolled option type.
 * Left is Nothing (absence), Right is Just (presence).
 * Modelled as a tagged union so it pattern‑matches naturally.
 */

export type Maybe<A> = { _tag: 'Nothing' } | { _tag: 'Just'; value: A };

export const Nothing = <A = never>(): Maybe<A> => ({ _tag: 'Nothing' });
export const Just = <A>(value: A): Maybe<A> => ({ _tag: 'Just', value });

export const isJust = <A>(m: Maybe<A>): m is { _tag: 'Just'; value: A } =>
  m._tag === 'Just';

export const isNothing = <A>(m: Maybe<A>): m is { _tag: 'Nothing' } =>
  m._tag === 'Nothing';

export const map = <A, B>(f: (a: A) => B) => (m: Maybe<A>): Maybe<B> =>
  isJust(m) ? Just(f(m.value)) : Nothing();

export const flatMap = <A, B>(f: (a: A) => Maybe<B>) => (m: Maybe<A>): Maybe<B> =>
  isJust(m) ? f(m.value) : Nothing();

export const getOrElse = <A>(fallback: A) => (m: Maybe<A>): A =>
  isJust(m) ? m.value : fallback;

export const fromNullable = <A>(a: A | null | undefined): Maybe<A> =>
  a === null || a === undefined ? Nothing() : Just(a);

export const match = <A, B>(onNothing: () => B, onJust: (a: A) => B) =>
  (m: Maybe<A>): B => (isJust(m) ? onJust(m.value) : onNothing());
