/**
 * IO<A> — a lazy, deferred computation. Nothing runs until `unsafeRun`.
 * We use it to keep side effects at the edges: parse, then build an IO,
 * then hand the IO to the runtime.
 */

export type IO<A> = () => A;

export const of = <A>(a: A): IO<A> => () => a;
export const fromThunk = <A>(f: () => A): IO<A> => f;

export const map = <A, B>(f: (a: A) => B) => (io: IO<A>): IO<B> =>
  () => f(io());

export const flatMap = <A, B>(f: (a: A) => IO<B>) => (io: IO<A>): IO<B> =>
  () => f(io())();

export const unsafeRun = <A>(io: IO<A>): A => io();

export const sequence = <A>(ios: IO<A>[]): IO<A[]> => () => ios.map((io) => io());

export const tap = <A>(f: (a: A) => void) => (io: IO<A>): IO<A> =>
  () => {
    const a = io();
    f(a);
    return a;
  };
