{-# LANGUAGE OverloadedStrings #-}
module Krivostr.Relay
  ( RelayHandle(..)
  , connect
  , sendClient
  , close
  ) where

import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Monad (forever)
import Data.Aeson (Value, encode, eitherDecode)
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Krivostr.Event
import Krivostr.Filter
import Krivostr.Logging
import Krivostr.Wire
import Network.WebSockets
import Wuss (runSecureClient)

data RelayHandle = RelayHandle
  { rhUrl    :: !Text
  , rhConn   :: !Connection
  , rhInbox  :: !(TQueue RelayMessage)
  , rhOutbox :: !(TQueue ClientMessage)
  , rhLogger :: !Logger
  }

-- | Connect, spawn a reader thread, return a handle.
connect :: Logger -> Text -> IO RelayHandle
connect lg url = do
  let (host, port, path) = parseUrl url
  conn <- runSecureClient (T.unpack host) port (T.unpack path) $ \c -> do
    inbox  <- newTQueueIO
    outbox <- newTQueueIO
    let rh = RelayHandle url c inbox outbox lg
    _ <- async (readerLoop rh)
    _ <- async (writerLoop rh)
    pure rh
  pure conn

readerLoop :: RelayHandle -> IO ()
readerLoop rh = forever $ do
  msg <- receiveData (rhConn rh)
  case eitherDecode msg of
    Left err  -> emit (rhLogger rh) Warn ("decode: " <> T.pack err)
    Right val -> emit (rhLogger rh) Debug "relay message received"

writerLoop :: RelayHandle -> IO ()
writerLoop rh = forever $ do
  cm <- atomically $ readTQueue (rhOutbox rh)
  sendData (rhConn rh) (encode (encodeClient cm))

sendClient :: RelayHandle -> ClientMessage -> IO ()
sendClient rh cm = atomically $ writeTQueue (rhOutbox rh) cm

close :: RelayHandle -> IO ()
close rh = sendClose (rhConn rh) ("bye" :: Text)

parseUrl :: Text -> (Text, Int, Text)
parseUrl url =
  let noScheme = T.replace "wss://" "" (T.replace "ws://" "" url)
      (hostPort, path) = T.breakOn "/" noScheme
      path' = if T.null path then "/" else path
      (host, port) = case T.splitOn ":" hostPort of
        [h, p] -> (h, read (T.unpack p))
        [h]    -> (h, 443)
        _      -> (hostPort, 443)
  in (host, port, path')
