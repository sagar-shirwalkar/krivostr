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

encodeClient :: ClientMessage -> Value
encodeClient (CEvent e)     = toJSON (["EVENT", toJSON e] :: [Value])
encodeClient (CReq sid fs)  = toJSON (["REQ", toJSON sid, toJSON fs] :: [Value])
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
