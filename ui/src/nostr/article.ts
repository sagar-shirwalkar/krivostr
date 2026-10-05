/**
 * NIP-23 long-form content.
 *
 * An article is a kind-30023 parameterized-replaceable event: the `d` tag
 * holds the slug, and `30023:pubkey:slug` addresses it, so republishing the
 * same slug replaces the article instead of adding a second one. The body is
 * Markdown; `title`, `summary`, `image`, and `published_at` are the header a
 * reader shows without parsing the body.
 *
 * No Markdown renderer here: the feed shows the header and the raw body as
 * text. Rendering Markdown is a display decision for a richer component.
 *
 * Mirrors `Krivostr.Nip.Nip23` on the Haskell side.
 */

import { NostrEvent } from './event';

/** Kind 30023. */
export const articleKind = 30023;

/** A parsed article header plus body. */
export interface Article {
  slug: string;
  title: string;
  summary: string;
  image: string;
  publishedAt: number | undefined;
  content: string;
  author: string;
}

const tagValue = (e: Pick<NostrEvent, 'tags'>, name: string): string | undefined => {
  const t = e.tags.find((x) => x[0] === name && x.length > 1);
  return t?.[1];
};

/**
 * Parse a kind-30023 event. Any other kind is not an article, and an article
 * without a `d` tag has no address — unreferenceable rather than untitled.
 */
export const articleOf = (e: NostrEvent): Article | undefined => {
  if (e.kind !== articleKind) return undefined;
  const slug = tagValue(e, 'd');
  if (slug === undefined) return undefined;
  const published = tagValue(e, 'published_at');
  return {
    slug,
    title: tagValue(e, 'title') ?? '',
    summary: tagValue(e, 'summary') ?? '',
    image: tagValue(e, 'image') ?? '',
    publishedAt: published !== undefined && /^\d+$/.test(published) ? parseInt(published, 10) : undefined,
    content: e.content,
    author: e.pubkey,
  };
};

/** Is the event a well-formed article? */
export const isArticle = (e: NostrEvent): boolean => articleOf(e) !== undefined;

/** The `a`-tag address: `30023:pubkey:slug`. */
export const articleAddress = (e: NostrEvent): string | undefined => {
  const a = articleOf(e);
  return a ? `30023:${e.pubkey}:${a.slug}` : undefined;
};

/** The header tags for an article. Empty fields are dropped, not emitted. */
export const buildArticleTags = (
  slug: string,
  title: string,
  summary: string,
  image: string,
  publishedAt?: number,
): string[][] => {
  const tags: string[][] = [['d', slug]];
  if (title !== '') tags.push(['title', title]);
  if (summary !== '') tags.push(['summary', summary]);
  if (image !== '') tags.push(['image', image]);
  if (publishedAt !== undefined) tags.push(['published_at', String(Math.floor(publishedAt))]);
  return tags;
};

/**
 * Turn a title into a slug: lowercase, spaces to dashes, punctuation
 * dropped. Slugs address articles, so they must be stable and URL-safe.
 */
export const slugify = (title: string): string =>
  title
    .toLowerCase()
    .replace(/[^a-z0-9 \-]/g, '')
    .split(/\s+/)
    .filter((w) => w !== '')
    .join('-');
