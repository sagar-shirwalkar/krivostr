{-# LANGUAGE OverloadedStrings #-}

-- | NIP-51 lists: mute, pins, and bookmarks.
--
-- A list is a replaceable event whose tags are the entries: kind 10000
-- mutes @p@-tag pubkeys, kind 10001 pins @e@-tag event ids, kind 10003
-- bookmarks @e@ ids, @a@ addresses, @d@ identifiers, and @t@ hashtags.
-- The content is conventionally empty; everything lives in the tags, which
-- is what makes adding or removing an entry a pure tag-list operation.
--
-- Only the parsing and the tag algebra live here. Deciding *whose* list
-- applies (the viewer's own latest, never anyone else's) and persisting it
-- are caller concerns: the CLI reads its key and the store, the UI reads
-- the signer's pubkey and the feed.
module Krivostr.Nip.Nip51
  ( muteKind
  , pinKind
  , bookmarkKind
  , ListEntries(..)
  , listEntries
  , mutedPubkeys
  , pinnedIds
  , bookmarkedIds
  , bookmarkedAddresses
  , addEntry
  , removeEntry
  ) where

import Data.Text (Text)
import Krivostr.Event

-- | Kind 10000: muted pubkeys.
muteKind :: Int
muteKind = 10000

-- | Kind 10001: pinned event ids.
pinKind :: Int
pinKind = 10001

-- | Kind 10003: bookmarked ids, addresses, and hashtags.
bookmarkKind :: Int
bookmarkKind = 10003

-- | Every entry channel a list event can carry.
data ListEntries = ListEntries
  { lePubkeys   :: ![Text]
  , leEvents    :: ![Text]
  , leAddresses :: ![Text]
  , leTags      :: ![Text]
  } deriving (Show, Eq)

-- | Split a list event's tags into entries. Only the three list kinds
-- parse; anything else is not a list. Relay hints on @p@ entries live past
-- the first value, which is all that is read, so hints survive parsing.
listEntries :: Event -> Maybe ListEntries
listEntries e
  | evKind e == muteKind =
      Just (ListEntries (tagged "p") [] [] [])
  | evKind e == pinKind =
      Just (ListEntries [] (tagged "e") [] [])
  | evKind e == bookmarkKind =
      Just (ListEntries [] (tagged "e") (tagged "a") (tagged "d" ++ tagged "t"))
  | otherwise = Nothing
  where
    tagged name = [v | (t : v : _) <- evTags e, t == name]

-- | Muted pubkeys of a kind 10000, in wire order.
mutedPubkeys :: Event -> [Text]
mutedPubkeys e = case listEntries e of
  Just entries -> lePubkeys entries
  Nothing      -> []

-- | Pinned event ids of a kind 10001.
pinnedIds :: Event -> [Text]
pinnedIds e = case listEntries e of
  Just entries -> leEvents entries
  Nothing      -> []

-- | Bookmarked event ids of a kind 10003.
bookmarkedIds :: Event -> [Text]
bookmarkedIds e = case listEntries e of
  Just entries -> leEvents entries
  Nothing      -> []

-- | Bookmarked addresses of a kind 10003.
bookmarkedAddresses :: Event -> [Text]
bookmarkedAddresses e = case listEntries e of
  Just entries -> leAddresses entries
  Nothing      -> []

-- | Add an entry tag, idempotent: re-adding what is there changes nothing,
-- so publishing twice is safe and the list never grows duplicates.
addEntry :: Text -> Text -> [[Text]] -> [[Text]]
addEntry name value tags
  | [name, value] `elem` tags = tags
  | otherwise = tags ++ [[name, value]]

-- | Remove every entry tag with this name and value. Relay hints on @p@
-- entries live in later positions, so matching on the first two elements
-- removes the entry whichever hint it carries.
removeEntry :: Text -> Text -> [[Text]] -> [[Text]]
removeEntry name value = filter keep
  where
    keep (t : v : _) = not (t == name && v == value)
    keep _           = True
