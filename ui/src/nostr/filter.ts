/**
 * NIP-01 filter algebra.
 *
 * `FilterSpec` is the ergonomic shape the UI uses (tag filters as a record,
 * camelCase names). `toWire` translates it to the wire form, where tag filters
 * are single-letter keys prefixed with `#`. `compile` turns it into a matcher
 * so a subscription's filter is walked once instead of on every event.
 *
 * Mirrors `Krivostr.Filter` on the Haskell side, including the NIP-01 rule
 * that a REQ matches when any of its filters matches.
 */

import { NostrEvent } from './event';

export interface FilterSpec {
  readonly ids?: readonly string[];
  readonly authors?: readonly string[];
  readonly kinds?: readonly number[];
  /** Unix seconds, inclusive. */
  readonly since?: number;
  /** Unix seconds, inclusive. */
  readonly until?: number;
  readonly limit?: number;
  /** Tag name to accepted values. The event matches if any tag with that name
   *  carries any of the listed values. */
  readonly tags?: Readonly<Record<string, readonly string[]>>;
  /**
   * NIP-50 full-text search. Goes on the wire as `search`; relays answer
   * from their own index. The local reading is a case-insensitive substring
   * on the content — same rule as the Haskell `matches`.
   */
  readonly search?: string;
}

/** Wire form: the tag record is flattened into `#name` keys. */
export const toWire = (f: FilterSpec): Record<string, unknown> => {
  const { tags, ...rest } = f;
  const wire: Record<string, unknown> = { ...rest };
  if (tags) {
    for (const [name, values] of Object.entries(tags)) {
      wire[`#${name}`] = values;
    }
  }
  return wire;
};

/** A filter that has been walked once and can be applied repeatedly. */
export interface CompiledFilter {
  readonly test: (e: NostrEvent) => boolean;
}

/**
 * Compile a spec into a predicate.
 *
 * Deliberately eager: an absent constraint compiles to `true` rather than being
 * tested at match time, so an empty spec costs one call and nothing else.
 */
export const compile = (f: FilterSpec): CompiledFilter => {
  const ids = f.ids ? new Set(f.ids) : null;
  const authors = f.authors ? new Set(f.authors) : null;
  const kinds = f.kinds ? new Set(f.kinds) : null;
  const tagTests = f.tags
    ? Object.entries(f.tags).map(
        ([name, values]) =>
          [
            name,
            new Set(values),
          ] as const,
      )
    : [];

  const test = (e: NostrEvent): boolean => {
    if (ids && !ids.has(e.id)) return false;
    if (authors && !authors.has(e.pubkey)) return false;
    if (kinds && !kinds.has(e.kind)) return false;
    if (f.since !== undefined && e.created_at < f.since) return false;
    if (f.until !== undefined && e.created_at > f.until) return false;
    if (f.search !== undefined && !e.content.toLowerCase().includes(f.search.toLowerCase())) return false;

    for (const [name, values] of tagTests) {
      const hit = e.tags.some(
        (tag) => tag[0] === name && tag.slice(1).some((v) => values.has(v)),
      );
      if (!hit) return false;
    }
    return true;
  };

  return { test };
};

/** Shorthand for `compile(f).test(e)`. */
export const matches = (f: FilterSpec, e: NostrEvent): boolean =>
  compile(f).test(e);

/**
 * Whether an event matches any filter in a REQ's filter list, which is what
 * NIP-01 requires of a multi-filter subscription.
 */
export const matchesAny = (fs: readonly FilterSpec[], e: NostrEvent): boolean =>
  fs.length === 0 || fs.some((f) => matches(f, e));
