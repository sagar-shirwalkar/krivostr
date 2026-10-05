{-# LANGUAGE OverloadedStrings #-}

-- | NIP-22 comments: threading for anything that is not a kind 1 note.
--
-- A comment is a kind 1111 event with plaintext content. The root scope uses
-- UPPERCASE tags and the parent scope lowercase ones; @K@/@k@ name the two
-- kinds and @P@/@p@ their authors. A top-level comment points root and
-- parent at the same item; a reply to a comment keeps the root and moves
-- the parent to the comment being answered.
--
-- Which tag names the item depends on what it is: @E@/@e@ for plain events
-- by id, @A@/@a@ for addressable events by @kind:pubkey:d@ coordinate, with
-- an @E@ alongside when the exact version commented on is known. Regular
-- notes are never commented on this way -- answering a kind 1 is NIP-10's
-- job, and a kind 1111 citing one is a protocol error readers ignore.
module Krivostr.Nip.Nip22
  ( commentKind
  , ItemRef(..)
  , Comment(..)
  , commentOf
  , isComment
  , commentRoot
  , commentParent
  , buildCommentTags
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Krivostr.Event

-- | Kind 1111.
commentKind :: Int
commentKind = 1111

-- | One end of a comment: the item referenced, however it is addressed.
data ItemRef = ItemRef
  { refId      :: !(Maybe Text)
  , refAddress :: !(Maybe Text)
  , refKind    :: !Int
  , refAuthor  :: !Text
  , refRelay   :: !Text
  } deriving (Show, Eq)

-- | A parsed comment: its root scope and its parent scope.
data Comment = Comment
  { cmRoot   :: !ItemRef
  , cmParent :: !ItemRef
  } deriving (Show, Eq)

-- | Parse a kind 1111 event. Anything else is not a comment. A comment
-- needs a root scope (one of @E@/@A@/@I@), a parent scope (one of
-- @e@/@a@/@i@), and both kind tags -- without them the thread cannot be
-- reconstructed, so the event is malformed rather than rootless.
commentOf :: Event -> Maybe Comment
commentOf e
  | evKind e /= commentKind = Nothing
  | otherwise = do
      root <- scopeOf "E" "A" "I" "K" "P"
      parent <- scopeOf "e" "a" "i" "k" "p"
      pure (Comment root parent)
  where
    scopeOf upperE upperA _ kindTag authorTag = do
      let eid = firstOf upperE
          addr = firstOf upperA
      guard (eid /= Nothing || addr /= Nothing)
      kind <- firstOf kindTag >>= readKind
      pure ItemRef
        { refId = eid
        , refAddress = addr
        , refKind = kind
        , refAuthor = firstOrEmpty authorTag
        , refRelay = hintOf upperE `orElse` hintOf upperA
        }

    firstOf name = case [v | (t : v : _) <- evTags e, t == name] of
      (v : _) -> Just v
      _       -> Nothing

    hintOf name = case [rest | (t : _ : rest) <- evTags e, t == name] of
      ((h : _) : _) -> h
      _             -> ""

    orElse "" b = b
    orElse a _  = a

    firstOrEmpty name = case firstOf name of
      Just v  -> v
      Nothing -> ""

    readKind t = case reads (T.unpack t) of
      [(n, "")] -> Just n
      _         -> Nothing

    guard True  = Just ()
    guard False = Nothing

-- | Is the event a well-formed comment?
isComment :: Event -> Bool
isComment e = case commentOf e of
  Nothing -> False
  Just _  -> True

-- | The root scope of a comment.
commentRoot :: Event -> Maybe ItemRef
commentRoot e = cmRoot <$> commentOf e

-- | The parent scope of a comment.
commentParent :: Event -> Maybe ItemRef
commentParent e = cmParent <$> commentOf e

-- | The tags for commenting on @root@, optionally answering @parent@.
-- 'Nothing' for the parent means a top-level comment: root and parent
-- reference the same item.
--
-- Addressable items get @A@/@a@ plus @E@/@e@ when the exact version is
-- known, because the coordinate names the article and the id names the
-- version commented on. Plain events get @E@/@e@ alone.
buildCommentTags :: ItemRef -> Maybe ItemRef -> [[Text]]
buildCommentTags root Nothing = scopeTags True root ++ scopeTags False root
buildCommentTags root (Just parent) = scopeTags True root ++ scopeTags False parent

-- | One scope's tags: the address or id, the kind, and the author.
scopeTags :: Bool -> ItemRef -> [[Text]]
scopeTags upper r =
  addrTags ++ kindTag ++ authorTag
  where
    (eTag, aTag, kTag, pTag)
      | upper     = ("E", "A", "K", "P")
      | otherwise = ("e", "a", "k", "p")
    addrTags = case (refAddress r, refId r) of
      (Just a, Just i) -> [[aTag, a, refRelay r], [eTag, i, refRelay r, refAuthor r]]
      (Just a, Nothing) -> [[aTag, a, refRelay r]]
      (Nothing, Just i) -> [[eTag, i, refRelay r, refAuthor r]]
      (Nothing, Nothing) -> []
    kindTag = [[kTag, T.pack (show (refKind r))]]
    authorTag
      | T.null (refAuthor r) = []
      | otherwise = [[pTag, refAuthor r, refRelay r]]
