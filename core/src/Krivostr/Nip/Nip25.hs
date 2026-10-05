{-# LANGUAGE OverloadedStrings #-}

-- | NIP-25 user reactions.
--
-- A reaction is a kind 7 event whose content is an emoji (or @+@/@-@ for
-- like/dislike) and whose tags point at what it answers: the @e@ tag names
-- the reacted event, the @p@ tag its author, and a @k@ tag records the
-- reacted kind so a reader can tell a like on a note from a like on an
-- article without fetching the target.
--
-- The content is advisory, not load-bearing: clients that cannot render an
-- emoji fall back to the @+@/@-@ reading, and counting reactions is counting
-- kind 7 events per @e@ tag, not parsing their content.
module Krivostr.Nip.Nip25
  ( reactionKind
  , Reaction(..)
  , reactionOf
  , isReaction
  , isLike
  , isDislike
  , buildReactionTags
  , countReactions
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Krivostr.Event

-- | Kind 7.
reactionKind :: Int
reactionKind = 7

-- | A parsed reaction: what it answers and what it says.
data Reaction = Reaction
  { reEventId :: !Text
  , reAuthor  :: !Text
  , reKind    :: !(Maybe Int)
  , reContent :: !Text
  } deriving (Show, Eq)

-- | Parse a kind 7 event. Anything else is not a reaction, and a kind 7
-- without an @e@ tag answers nothing -- it is malformed rather than
-- universal, so it parses to 'Nothing' instead of matching everything.
reactionOf :: Event -> Maybe Reaction
reactionOf e
  | evKind e /= reactionKind = Nothing
  | otherwise = case [rest | ("e" : rest) <- evTags e] of
      ((eid : _) : _) -> Just Reaction
        { reEventId = eid
        , reAuthor  = authorOf e
        , reKind    = kindOf e
        , reContent = evContent e
        }
      _ -> Nothing
  where
    authorOf ev = case [v | ("p" : v : _) <- evTags ev] of
      (v : _) -> v
      _       -> ""

    kindOf ev = case [v | ("k" : v : _) <- evTags ev] of
      (v : _) -> case reads (T.unpack v) of
        [(n, "")] -> Just n
        _         -> Nothing
      _ -> Nothing

-- | Is the event a well-formed reaction?
isReaction :: Event -> Bool
isReaction e = case reactionOf e of
  Nothing -> False
  Just _  -> True

-- | The content is @+@ or a single emoji presentation: the spec's own rule is
-- that anything that is not @-@ reads as a like to a client that cannot
-- render it, so only @-@ (and the empty string, which says nothing) is not a
-- like.
isLike :: Event -> Bool
isLike e = evKind e == reactionKind && evContent e /= "-" && not (T.null (evContent e))

-- | An explicit dislike.
isDislike :: Event -> Bool
isDislike e = evKind e == reactionKind && evContent e == "-"

-- | The tags for reacting to an event: @e@ for the event, @p@ for its
-- author, @k@ for its kind. The relay hint travels on the @e@ tag because the
-- reactor knows where it saw the note and the reader may not.
buildReactionTags :: Text -> Text -> Text -> Int -> [[Text]]
buildReactionTags eventId relayHint author eventKind =
  [ ["e", eventId, relayHint]
  , ["p", author]
  , ["k", T.pack (show eventKind)]
  ]

-- | Count reactions per reacted event id, in first-seen order. Likes and
-- dislikes are counted separately because the content is the vote; the @k@
-- tag is ignored because one event id names one event.
countReactions :: [Event] -> [(Text, Int, Int)]
countReactions es = foldl add [] (mapMaybe reactionOf es)
  where
    add [] r = [(reEventId r, like r, dislike r)]
    add ((eid, likes, dislikes) : rest) r
      | eid == reEventId r = (eid, likes + like r, dislikes + dislike r) : rest
      | otherwise = (eid, likes, dislikes) : add rest r

    like r = if reContent r == "-" || T.null (reContent r) then 0 else 1
    dislike r = if reContent r == "-" then 1 else 0

    mapMaybe _ [] = []
    mapMaybe f (x : xs) = case f x of
      Nothing -> mapMaybe f xs
      Just y  -> y : mapMaybe f xs
