{-# LANGUAGE OverloadedStrings #-}
module Krivostr.Wire
  ( ClientMessage(..)
  , RelayMessage(..)
  , encodeClient
  , decodeRelay
  ) where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import Krivostr.Event
import Krivostr.Filter

data ClientMessage
  = CEvent Event
  | CReq   Text [Filter]
  | CClose Text
  deriving (Show, Eq)

data RelayMessage
  = REvent  Text Event
  | ROk     Text Bool Text
  | REose   Text
  | RNotice Text
  | RClosed Text Text
  deriving (Show, Eq)

-- | Encode an outgoing client message.
--
-- NIP-01 spells a subscription @[\"REQ\", <subscription_id>, <filters1>,
-- <filters2>, ...]@: the filters are trailing elements of the message array,
-- not one nested array. Relays answer the nested spelling with @provided
-- filter is not an object@, so the variadic form is what goes on the wire.
encodeClient :: ClientMessage -> Value
encodeClient (CEvent e)     = toJSON (["EVENT", toJSON e] :: [Value])
encodeClient (CReq sid fs)  = toJSON (["REQ", toJSON sid] ++ map toJSON fs)
encodeClient (CClose sid)   = toJSON (["CLOSE", toJSON sid] :: [Value])

decodeRelay :: Value -> Parser RelayMessage
decodeRelay = withArray "RelayMessage" $ \arr -> case toList arr of
  [String "EVENT", String sid, ev] -> REvent sid <$> parseJSON ev
  [String "OK", String sid, Bool ok, String msg] -> pure (ROk sid ok msg)
  [String "EOSE", String sid]      -> pure (REose sid)
  [String "NOTICE", String msg]    -> pure (RNotice msg)
  [String "CLOSED", String sid, String msg] -> pure (RClosed sid msg)
  _ -> fail "unknown relay message"
  where
    toList = foldr (:) []
