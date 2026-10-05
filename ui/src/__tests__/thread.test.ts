import { describe, it, expect } from 'vitest';
import {
  threadOf,
  isReply,
  replyRoot,
  replyTo,
  mentionedPubkeys,
  buildReplyTags,
  groupByThread,
} from '../nostr/thread';
import { NostrEvent } from '../nostr/event';

const ev = (tags: string[][], id = 'note'): NostrEvent => ({
  id, pubkey: 'author', created_at: 1700000000, kind: 1, tags, content: 'hi', sig: 's'.repeat(128),
});

describe('threadOf', () => {
  it('reads marked root and reply tags', () => {
    expect(threadOf(ev([['e', 'root-id', 'wss://r', 'root'], ['e', 'parent-id', '', 'reply']]))).toEqual({
      rootId: 'root-id', rootRelay: 'wss://r', replyId: 'parent-id', replyRelay: '',
    });
  });
  it('treats a lone root marker as a reply to the root', () => {
    expect(threadOf(ev([['e', 'root-id', '', 'root']]))?.replyId).toBe('root-id');
  });
  it('falls back to positional order without markers', () => {
    expect(threadOf(ev([['e', 'root-id', 'wss://a'], ['e', 'parent-id', 'wss://b']]))).toEqual({
      rootId: 'root-id', rootRelay: 'wss://a', replyId: 'parent-id', replyRelay: 'wss://b',
    });
  });
  it('finds no thread without e tags', () => {
    expect(threadOf(ev([]))).toBeUndefined();
    expect(isReply(ev([]))).toBe(false);
  });
});

describe('replyRoot / replyTo / mentionedPubkeys', () => {
  it('reports root, parent, and p tags', () => {
    const e = ev([['e', 'root-id', '', 'root'], ['e', 'parent-id', '', 'reply'], ['p', 'alice']]);
    expect(isReply(e)).toBe(true);
    expect(replyRoot(e)).toBe('root-id');
    expect(replyTo(e)).toBe('parent-id');
    expect(mentionedPubkeys(e)).toEqual(['alice']);
  });
});

describe('buildReplyTags', () => {
  it('emits one e tag when the parent is the root', () => {
    expect(buildReplyTags('root', 'wss://r', 'alice', 'root', 'wss://r', 'alice')).toEqual([
      ['e', 'root', 'wss://r', 'root'], ['p', 'alice'],
    ]);
  });
  it('emits both authors and round-trips through threadOf', () => {
    const tags = buildReplyTags('root', 'wss://a', 'alice', 'parent', 'wss://b', 'bob');
    expect(tags).toContainEqual(['p', 'bob']);
    expect(threadOf(ev(tags))?.replyId).toBe('parent');
  });
});

describe('groupByThread', () => {
  it('groups replies under their root', () => {
    const root = ev([], 'root-id');
    const reply = ev([['e', 'root-id', '', 'root']], 'reply-id');
    const groups = groupByThread([root, reply]);
    expect(groups.get('root-id')?.map((e) => e.id).sort()).toEqual(['reply-id', 'root-id']);
  });
});
