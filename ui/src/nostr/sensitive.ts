/**
 * NIP-36 sensitive content: the `content-warning` tag.
 *
 * Presence is the signal; the reason is advisory. A tag with no reason
 * still marks the event sensitive — treating a reasonless tag as unmarked
 * would unblur exactly the events whose authors were most cautious.
 *
 * Hiding is a display decision: the feed blurs sensitive notes behind a
 * click, which works identically against the bridge and third-party relays
 * because the rule is local.
 *
 * Mirrors `Krivostr.Nip.Nip36` on the Haskell side.
 */

import { NostrEvent } from './event';

/** The tag name. */
export const warningTagName = 'content-warning';

/**
 * The warning reason, or `undefined` when untagged. `""` means flagged
 * without a reason — still sensitive.
 */
export const contentWarningOf = (e: Pick<NostrEvent, 'tags'>): string | undefined => {
  const t = e.tags.find((x) => x[0] === warningTagName);
  if (!t) return undefined;
  return t.length > 1 ? t[1] : '';
};

/** Does the event carry a content warning? */
export const isSensitive = (e: Pick<NostrEvent, 'tags'>): boolean => contentWarningOf(e) !== undefined;
