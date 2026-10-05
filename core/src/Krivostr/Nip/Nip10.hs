{-# LANGUAGE OverloadedStrings #-}

-- | NIP-10 reply conventions: how a text note says what it answers.
--
-- A reply carries @e@ tags for the thread and @p@ tags for the people. The
-- marked form is preferred -- @["e", id, relay, "root"|"reply"]@ -- and the
-- positional form (first @e@ is the root, last is the reply) is only the
-- fallback for old events, because a relay that reorders tags would silently
-- reparent the thread under the positional reading.
--
-- The builder always emits the marked form. Emitting both readings at once
-- (marked tags that also happen to be positional) is what keeps old clients
-- working: the first @e@ is the root and the last is the reply, with the
-- markers saying the same thing.
module Krivostr.Nip.Nip10
  ( ThreadRef(..)
  , threadOf
  , isReply
  , replyRoot
  , replyTo
  , mentionedPubkeys
  , buildReplyTags
  ) where

import Data.Text (Text)
import Krivostr.Event

-- | Where an event sits in a thread, if anywhere.
data ThreadRef = ThreadRef
  { trRootId     :: !Text
  , trRootRelay  :: !Text
  , trReplyId    :: !(Maybe Text)
  , trReplyRelay :: !Text
  } deriving (Show, Eq)

-- | The thread an event belongs to, if its @e@ tags say so.
--
-- Marked tags win: an @e@ tagged @root@ names the thread, one tagged @reply@
-- names the parent. A @mention@ tag is neither. With no markers, the
-- positional fallback applies -- one @e@ is both root and parent, several
-- makes the first the root and the last the parent. No @e@ tags means no
-- thread, not an empty one.
threadOf :: Event -> Maybe ThreadRef
threadOf e = case marked of
  refs | not (null refs) -> Just (fromMarked refs)
  _ -> fromPositional [rest | ("e" : rest) <- evTags e]
  where
    marked = [(rest, marker) | ("e" : rest) <- evTags e, marker <- take 1 (drop 2 rest)]

    fromMarked refs =
      let root = head ([r | (r, m) <- refs, m == "root"] ++ map fst refs)
          parent = head ([r | (r, m) <- refs, m == "reply"] ++ [root])
      in ThreadRef (head' root) (at 1 root) (Just (head' parent)) (at 1 parent)

    fromPositional [] = Nothing
    fromPositional [single] =
      Just (ThreadRef (head' single) (at 1 single) (Just (head' single)) (at 1 single))
    fromPositional rs =
      Just (ThreadRef (head' (head rs)) (at 1 (head rs)) (Just (head' (last rs))) (at 1 (last rs)))

    head' []    = ""
    head' (x:_) = x

    at _ []    = ""
    at 0 (x:_) = x
    at n (_:xs) = at (n - 1) xs

-- | Does the event answer something? A lone @e@ tag counts: it names both
-- the root and the parent, which is exactly what a reply to a top-level note
-- looks like.
isReply :: Event -> Bool
isReply e = case threadOf e of
  Nothing -> False
  Just _  -> True

-- | The thread root's event id, if the event is a reply.
replyRoot :: Event -> Maybe Text
replyRoot e = trRootId <$> threadOf e

-- | The parent event's id -- the note being directly answered.
replyTo :: Event -> Maybe Text
replyTo e = trReplyId =<< threadOf e

-- | Every pubkey the event addresses with a @p@ tag, in order.
--
-- Replies @p@-tag the people they answer (the parent author at minimum), so
-- this is the notify list, not the thread structure. Duplicates are kept:
-- the wire order is the author's, and deduplicating would rewrite it.
mentionedPubkeys :: Event -> [Text]
mentionedPubkeys e = [v | ("p" : v : _) <- evTags e]

-- | The @e@ and @p@ tags for answering @parent@ in @threadRoot@'s thread.
--
-- The marked form, arranged so the positional reading agrees: root first,
-- parent last, each author @p@-tagged once. When the parent *is* the root a
-- single @e@ does both jobs -- a second identical tag would make positional
-- readers see a two-note thread where there is one -- and when both notes
-- share an author one @p@ tag names them.
--
-- Relay hints travel on the tags because the replier knows where it saw the
-- notes and the reader may not.
buildReplyTags :: Text -> Text -> Text -> Text -> Text -> Text -> [[Text]]
buildReplyTags rootId rootRelayHint rootAuthor parentId parentRelayHint parentAuthor
  | rootId == parentId =
      [ ["e", rootId, rootRelayHint, "root"]
      , ["p", rootAuthor]
      ]
  | rootAuthor == parentAuthor =
      [ ["e", rootId, rootRelayHint, "root"]
      , ["p", rootAuthor]
      , ["e", parentId, parentRelayHint, "reply"]
      ]
  | otherwise =
      [ ["e", rootId, rootRelayHint, "root"]
      , ["p", rootAuthor]
      , ["e", parentId, parentRelayHint, "reply"]
      , ["p", parentAuthor]
      ]
