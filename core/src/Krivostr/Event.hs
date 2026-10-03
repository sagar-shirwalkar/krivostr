{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
module Krivostr.Event
  ( Event(..)
  , UnsignedEvent(..)
  , mkEvent
  , kindText
  ) where

import Data.Aeson
import Data.Text (Text)
import Data.Time.Clock.POSIX (POSIXTime)
import GHC.Generics (Generic)

-- | A signed Nostr event, immutable by construction.
data Event = Event
  { evId        :: !Text
  , evPubkey    :: !Text
  , evCreatedAt :: !POSIXTime
  , evKind      :: !Int
  , evTags      :: ![[Text]]
  , evContent   :: !Text
  , evSig       :: !Text
  } deriving (Show, Eq, Generic)

-- | An event before signing. No id, no sig.
data UnsignedEvent = UnsignedEvent
  { uePubkey    :: !Text
  , ueCreatedAt :: !POSIXTime
  , ueKind      :: !Int
  , ueTags      :: ![[Text]]
  , ueContent   :: !Text
  } deriving (Show, Eq, Generic)

instance ToJSON Event where
  toJSON e = object
    [ "id"         .= evId e
    , "pubkey"     .= evPubkey e
    , "created_at" .= evCreatedAt e
    , "kind"       .= evKind e
    , "tags"       .= evTags e
    , "content"    .= evContent e
    , "sig"        .= evSig e
    ]

instance FromJSON Event where
  parseJSON = withObject "Event" $ \o -> Event
    <$> o .: "id"
    <*> o .: "pubkey"
    <*> o .: "created_at"
    <*> o .: "kind"
    <*> o .: "tags"
    <*> o .: "content"
    <*> o .: "sig"

instance ToJSON UnsignedEvent where
  toJSON e = object
    [ "pubkey"     .= uePubkey e
    , "created_at" .= ueCreatedAt e
    , "kind"       .= ueKind e
    , "tags"       .= ueTags e
    , "content"    .= ueContent e
    ]

-- | Lift an unsigned event into an empty shell (id and sig to be filled).
mkEvent :: UnsignedEvent -> Event
mkEvent u = Event
  { evId        = ""
  , evPubkey    = uePubkey u
  , evCreatedAt = ueCreatedAt u
  , evKind      = ueKind u
  , evTags      = ueTags u
  , evContent   = ueContent u
  , evSig       = ""
  }

-- | Human label for common event kinds.
kindText :: Int -> Text
kindText 0    = "metadata"
kindText 1    = "text note"
kindText 3    = "follow list"
kindText 4    = "encrypted DM"
kindText 5    = "deletion"
kindText 6    = "repost"
kindText 7    = "reaction"
kindText 40   = "channel create"
kindText 42   = "channel message"
kindText 1059 = "gift wrap"
kindText 10002 = "relay list"
kindText _    = "unknown"
