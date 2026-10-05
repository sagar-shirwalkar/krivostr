{-# LANGUAGE OverloadedStrings #-}

-- | NIP-09 event deletion requests.
--
-- A deletion is a kind 5 event whose @e@ tags name event ids and whose @a@
-- tags name parameterized addresses (@kind:pubkey:d@). It takes effect only
-- against its author's own events: a kind 5 from anyone else citing your
-- note is graffiti, not authority, so every predicate here checks authorship
-- first and returns 'False' rather than a partial match.
--
-- Deletion on Nostr is advisory -- relays may keep serving the bytes and the
-- bridge only drops its own copy. Publishing the request is asking; removing
-- locally is the part we control.
module Krivostr.Nip.Nip09
  ( deletionKind
  , Deletion(..)
  , deletionOf
  , isDeletion
  , deletionTargets
  , parameterizedAddress
  , appliesTo
  , buildDeletionTags
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Krivostr.Event

-- | Kind 5.
deletionKind :: Int
deletionKind = 5

-- | A parsed deletion request: cited ids and cited addresses.
data Deletion = Deletion
  { dlEventIds  :: ![Text]
  , dlAddresses :: ![Text]
  } deriving (Show, Eq)

-- | Parse a kind 5 event. Any other kind is not a deletion, and a kind 5
-- citing nothing deletes nothing -- it is empty rather than universal.
deletionOf :: Event -> Maybe Deletion
deletionOf e
  | evKind e /= deletionKind = Nothing
  | otherwise =
      let ids = [v | ("e" : v : _) <- evTags e, not (T.null v)]
          addrs = [v | ("a" : v : _) <- evTags e, not (T.null v)]
      in Just Deletion { dlEventIds = ids, dlAddresses = addrs }

-- | Is the event a deletion request (of anything)?
isDeletion :: Event -> Bool
isDeletion e = case deletionOf e of
  Nothing -> False
  Just _  -> True

-- | The ids and addresses a deletion cites. Empty cites delete nothing.
deletionTargets :: Event -> ([Text], [Text])
deletionTargets e = case deletionOf e of
  Nothing -> ([], [])
  Just d  -> (dlEventIds d, dlAddresses d)

-- | The parameterized address of an event, if it has one: only kinds
-- 30000–39999 carry a @d@ tag, and only the first one counts. Anything else
-- is not addressable, so it cannot be deleted by address.
parameterizedAddress :: Event -> Maybe Text
parameterizedAddress e
  | evKind e < 30000 || evKind e > 39999 = Nothing
  | otherwise = case [v | ("d" : v : _) <- evTags e] of
      (d : _) -> Just (T.intercalate ":" [T.pack (show (evKind e)), evPubkey e, d])
      _       -> Nothing

-- | Does a deletion request remove the target? Same author, and the target
-- cited by id or by address. Either citation suffices because they name the
-- same event through different handles.
appliesTo :: Event -> Event -> Bool
appliesTo deletion target
  | evKind deletion /= deletionKind = False
  | evPubkey deletion /= evPubkey target = False
  | otherwise =
      let (ids, addrs) = deletionTargets deletion
      in evId target `elem` ids || maybe False (`elem` addrs) (parameterizedAddress target)

-- | The tags for deleting events: @e@ for ids, @a@ for addresses. Empty
-- inputs are dropped rather than emitted: an empty @e@ tag would cite
-- nothing and confuse readers that count tags.
buildDeletionTags :: [Text] -> [Text] -> [[Text]]
buildDeletionTags ids addrs =
  [["e", i] | i <- ids, not (T.null i)]
    ++ [["a", a] | a <- addrs, not (T.null a)]
