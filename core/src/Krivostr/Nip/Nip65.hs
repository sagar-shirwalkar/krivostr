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
import qualified Data.Text as T
import Krivostr.Event

data RelayMode = Read | Write | Both
  deriving (Show, Eq)

data RelayHint = RelayHint
  { rhUrl  :: !Text
  , rhMode :: !RelayMode
  } deriving (Show, Eq)

-- | Parse tags like ["r", "wss://...", "read"] into a list.
-- Missing third element means Both.
--
-- The previous version used a @case@ expression as a comprehension guard,
-- which cannot bind the pattern variable into the result expression, so @url@
-- was never in scope. A pattern-match generator filters the same way and does
-- bind.
parseRelayList :: Event -> [RelayHint]
parseRelayList e =
  [ RelayHint url (decodeMode rest)
  | t <- evTags e
  , ("r" : url : rest) <- [t]
  , not (T.null url)
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
