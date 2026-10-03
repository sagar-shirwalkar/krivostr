/**
 * Result<E, A> — either an error E or a value A.
 * Used for parsing, validation, and network responses.
 */

export type Result<E, A> = { _tag: 'Err'; error: E } | { _tag: 'Ok'; value: A };

export const Ok = <A, E = never>(value: A): Result<E, A> => ({ _tag: 'Ok', value });
export const Err = <E, A = never>(error: E): Result<E, A> => ({ _tag: 'Err', error });

export const isOk = <E, A>(r: Result<E, A>): r is { _tag: 'Ok'; value: A } =>
  r._tag === 'Ok';
export const isErr = <E, A>(r: Result<E, A>): r is { _tag: 'Err'; error: E } =>
  r._tag === 'Err';

export const map = <E, A, B>(f: (a: A) => B) => (r: Result<E, A>): Result<E, B> =>
  isOk(r) ? Ok(f(r.value)) : r;

export const mapErr = <E, F, A>(f: (e: E) => F) => (r: Result<E, A>): Result<F, A> =>
  isErr(r) ? Err(f(r.error)) : r;

export const flatMap = <E, A, B>(f: (a: A) => Result<E, B>) =>
  (r: Result<E, A>): Result<E, B> => (isOk(r) ? f(r.value) : r);

export const getOrElse = <E, A>(fallback: A) => (r: Result<E, A>): A =>
  isOk(r) ? r.value : fallback;

export const match = <E, A, B>(onErr: (e: E) => B, onOk: (a: A) => B) =>
  (r: Result<E, A>): B => (isOk(r) ? onOk(r.value) : onErr(r.error));

export const fromPromise = async <E, A>(
  p: Promise<A>,
  onErr: (e: unknown) => E,
): Promise<Result<E, A>> => {
  try {
    return Ok(await p);
  } catch (e) {
    return Err(onErr(e));
  }
};
