{-# LANGUAGE OverloadedStrings #-}
module Krivostr.Nip.Nip65
  ( RelayMode(..)
  , RelayHint(..)
  , parseRelayList
  , buildRelayListTags
  , readRelays
  , writeRelays
  ) where

import Data.Text (Text)
import Krivostr.Event

data RelayMode = Read | Write | Both
  deriving (Show, Eq)

data RelayHint = RelayHint
  { rhUrl  :: !Text
  , rhMode :: !RelayMode
  } deriving (Show, Eq)

-- | Parse tags like ["r", "wss://...", "read"] into a list.
-- Missing third element means Both.
parseRelayList :: Event -> [RelayHint]
parseRelayList e =
  [ RelayHint url (decodeMode (drop 2 t))
  | t <- evTags e
  , case t of
      ("r":url:_) -> not (null url)
      _           -> False
  ]
  where
    decodeMode xs = case xs of
      ("read":_)  -> Read
      ("write":_) -> Write
      _           -> Both

-- | Build the `r` tags for a kind 10002 event.
buildRelayListTags :: [RelayHint] -> [[Text]]
buildRelayListTags = map go
  where
    go (RelayHint url Both)  = ["r", url]
    go (RelayHint url Read)  = ["r", url, "read"]
    go (RelayHint url Write) = ["r", url, "write"]

readRelays :: [RelayHint] -> [Text]
readRelays = map rhUrl . filter (\h -> rhMode h == Read || rhMode h == Both)

writeRelays :: [RelayHint] -> [Text]
writeRelays = map rhUrl . filter (\h -> rhMode h == Write || rhMode h == Both)
