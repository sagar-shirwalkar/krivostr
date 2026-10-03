import { describe, it, expect, vi } from 'vitest';
import * as IO from '../fp/io';

describe('IO', () => {
  it('of is lazy', () => {
    const io = IO.of(1);
    expect(IO.unsafeRun(io)).toBe(1);
  });

  it('fromThunk runs once per unsafeRun', () => {
    const spy = vi.fn(() => 42);
    const io = IO.fromThunk(spy);
    expect(spy).not.toHaveBeenCalled();
    expect(IO.unsafeRun(io)).toBe(42);
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it('map applies the function', () => {
    const io = IO.map((n: number) => n * 2)(IO.of(3));
    expect(IO.unsafeRun(io)).toBe(6);
  });

  it('flatMap chains', () => {
    const io = IO.flatMap((n: number) => IO.of(n + 1))(IO.of(1));
    expect(IO.unsafeRun(io)).toBe(2);
  });

  it('sequence runs all', () => {
    const io = IO.sequence([IO.of(1), IO.of(2), IO.of(3)]);
    expect(IO.unsafeRun(io)).toEqual([1, 2, 3]);
  });

  it('tap runs side effects', () => {
    const spy = vi.fn();
    const io = IO.tap(spy)(IO.of(1));
    expect(spy).not.toHaveBeenCalled();
    IO.unsafeRun(io);
    expect(spy).toHaveBeenCalledWith(1);
  });
});
