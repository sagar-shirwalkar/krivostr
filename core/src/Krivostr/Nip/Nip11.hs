{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RecordWildCards #-}

-- | NIP-11: Relay Information Document.
--
-- Relays serve a JSON document at their WebSocket root path when the HTTP
-- request carries @Accept: application/nostr+json@. The document is metadata
-- about relay capabilities, limitations, and administrative contacts.
--
-- All fields are OPTIONAL - a relay may return any subset. The type makes
-- optionality explicit using 'Maybe' rather than inventing defaults.
module Krivostr.Nip.Nip11
  ( RelayInfo(..)
  , Limitation(..)
  , encodeRelayInfo
  , decodeRelayInfo
  , parseRelayInfo
  , supportsNip
  ) where

import Data.Aeson
import Data.Aeson.Types (Pair, parseEither)
import Data.Text (Text)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import GHC.Generics (Generic)

-- | Server limitations imposed by the relay on clients.
-- Each field is optional as per the spec.
data Limitation = Limitation
  { maxMessageLength      :: !(Maybe Int)
  , maxSubscriptions      :: !(Maybe Int)
  , maxFilters            :: !(Maybe Int)
  , maxLimit              :: !(Maybe Int)
  , maxSubidLength        :: !(Maybe Int)
  , minPrefix             :: !(Maybe Int)
  , maxEventTags          :: !(Maybe Int)
  , maxContentLength      :: !(Maybe Int)
  , minPowDifficulty      :: !(Maybe Int)
  , authRequired          :: !(Maybe Bool)
  , paymentRequired       :: !(Maybe Bool)
  , restrictedWrites      :: !(Maybe Bool)
  , createdAtLowerLimit   :: !(Maybe Int)
  , createdAtUpperLimit   :: !(Maybe Int)
  , defaultLimit          :: !(Maybe Int)
  } deriving (Show, Eq, Generic)

instance ToJSON Limitation where
  toJSON Limitation{..} = object $ concat
    [ field "max_message_length" maxMessageLength
    , field "max_subscriptions" maxSubscriptions
    , field "max_filters" maxFilters
    , field "max_limit" maxLimit
    , field "max_subid_length" maxSubidLength
    , field "min_prefix" minPrefix
    , field "max_event_tags" maxEventTags
    , field "max_content_length" maxContentLength
    , field "min_pow_difficulty" minPowDifficulty
    , field "auth_required" authRequired
    , field "payment_required" paymentRequired
    , field "restricted_writes" restrictedWrites
    , field "created_at_lower_limit" createdAtLowerLimit
    , field "created_at_upper_limit" createdAtUpperLimit
    , field "default_limit" defaultLimit
    ]
    where
      field k (Just v) = [k .= v]
      field _ Nothing  = []

instance FromJSON Limitation where
  parseJSON = withObject "Limitation" $ \o -> do
    Limitation
      <$> o .:? "max_message_length"
      <*> o .:? "max_subscriptions"
      <*> o .:? "max_filters"
      <*> o .:? "max_limit"
      <*> o .:? "max_subid_length"
      <*> o .:? "min_prefix"
      <*> o .:? "max_event_tags"
      <*> o .:? "max_content_length"
      <*> o .:? "min_pow_difficulty"
      <*> o .:? "auth_required"
      <*> o .:? "payment_required"
      <*> o .:? "restricted_writes"
      <*> o .:? "created_at_lower_limit"
      <*> o .:? "created_at_upper_limit"
      <*> o .:? "default_limit"

-- | Relay information document as defined by NIP-11.
-- All fields are optional.
data RelayInfo = RelayInfo
  { name           :: !(Maybe Text)
  , description    :: !(Maybe Text)
  , banner         :: !(Maybe Text)
  , icon           :: !(Maybe Text)
  , pubkey         :: !(Maybe Text)
  , self           :: !(Maybe Text)
  , contact        :: !(Maybe Text)
  , supportedNips  :: !(Maybe [Int])
  , software       :: !(Maybe Text)
  , version        :: !(Maybe Text)
  , termsOfService :: !(Maybe Text)
  , limitation     :: !(Maybe Limitation)
  } deriving (Show, Eq, Generic)

instance ToJSON RelayInfo where
  toJSON RelayInfo{..} = object $ concat
    [ f "name" name
    , f "description" description
    , f "banner" banner
    , f "icon" icon
    , f "pubkey" pubkey
    , f "self" self
    , f "contact" contact
    , f "supported_nips" supportedNips
    , f "software" software
    , f "version" version
    , f "terms_of_service" termsOfService
    , f "limitation" limitation
    ]
    where
      f k (Just v) = [k .= v]
      f _ Nothing  = []

instance FromJSON RelayInfo where
  parseJSON = withObject "RelayInfo" $ \o -> do
    RelayInfo
      <$> o .:? "name"
      <*> o .:? "description"
      <*> o .:? "banner"
      <*> o .:? "icon"
      <*> o .:? "pubkey"
      <*> o .:? "self"
      <*> o .:? "contact"
      <*> o .:? "supported_nips"
      <*> o .:? "software"
      <*> o .:? "version"
      <*> o .:? "terms_of_service"
      <*> o .:? "limitation"

-- | Encode a relay info document to a lazy bytestring.
encodeRelayInfo :: RelayInfo -> BL.ByteString
encodeRelayInfo = encode

-- | Parse a relay info document from a strict bytestring.
-- Returns 'Left' with an error message if parsing fails.
decodeRelayInfo :: BS.ByteString -> Either String RelayInfo
decodeRelayInfo = eitherDecodeStrict

-- | Parse a relay info document from a strict bytestring.
-- Synonym for 'decodeRelayInfo' to match naming conventions.
parseRelayInfo :: BS.ByteString -> Either String RelayInfo
parseRelayInfo = decodeRelayInfo

-- | Check if the relay supports a given NIP.
supportsNip :: Int -> RelayInfo -> Bool
supportsNip nip ri = case supportedNips ri of
  Just nips -> nip `elem` nips
  Nothing   -> False
