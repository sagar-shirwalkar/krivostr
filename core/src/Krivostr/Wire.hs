{-# LANGUAGE OverloadedStrings #-}
module Krivostr.Wire
  ( ClientMessage(..)
  , RelayMessage(..)
  , encodeClient
  , decodeRelay
  ) where

import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.KeyMap as KM
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Krivostr.Event
import Krivostr.Filter

data ClientMessage
  = CEvent Event
  | CReq   Text [Filter]
  | CClose Text
  -- | NIP-45: ask how many stored events match, without fetching them.
  | CCount Text [Filter]
  deriving (Show, Eq)

data RelayMessage
  = REvent  Text Event
  | ROk     Text Bool Text
  | REose   Text
  | RNotice Text
  | RClosed Text Text
  -- | NIP-42: the relay is asking the client to prove who it is. The payload is
  -- the challenge string the client must echo inside a kind 22242 event.
  | RChallenge Text
  -- | NIP-45: the count answer. The object carries @"count"@; anything else
  -- in it is the relay's business and is ignored.
  | RCount  Text Int
  deriving (Show, Eq)

-- | Encode an outgoing client message.
--
-- NIP-01 spells a subscription @["REQ", <subscription_id>, <filters1>,
-- <filters2>, ...]@: the filters are trailing elements of the message array,
-- not one nested array. Relays answer the nested spelling with @provided
-- filter is not an object@, so the variadic form is what goes on the wire.
-- NIP-45 COUNT follows the same variadic shape.
encodeClient :: ClientMessage -> Value
encodeClient (CEvent e)     = toJSON (["EVENT", toJSON e] :: [Value])
encodeClient (CReq sid fs)  = toJSON (["REQ", toJSON sid] ++ map toJSON fs)
encodeClient (CClose sid)   = toJSON (["CLOSE", toJSON sid] :: [Value])
encodeClient (CCount sid fs) = toJSON (["COUNT", toJSON sid] ++ map toJSON fs)

decodeRelay :: Value -> Parser RelayMessage
decodeRelay = withArray "RelayMessage" $ \arr -> case toList arr of
  [String "EVENT", String sid, ev] -> REvent sid <$> parseJSON ev
  [String "OK", String sid, Bool ok, String msg] -> pure (ROk sid ok msg)
  [String "EOSE", String sid]      -> pure (REose sid)
  [String "NOTICE", String msg]    -> pure (RNotice msg)
  [String "CLOSED", String sid, String msg] -> pure (RClosed sid msg)
  [String "AUTH", String challenge]        -> pure (RChallenge challenge)
  [String "COUNT", String sid, Object o] -> case KM.lookup "count" o of
    Just (Number n) -> case floatingOrInteger n of
      Right i  -> pure (RCount sid (fromInteger i))
      Left _   -> fail "COUNT without a numeric count"
    _ -> fail "COUNT without a numeric count"
  _ -> fail "unknown relay message"
  where
    toList = foldr (:) []
