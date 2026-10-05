{-# LANGUAGE OverloadedStrings #-}

-- | One relay WebSocket connection, with a reader and a writer thread.
--
-- Two things were wrong here before. 'connect' used
-- 'Wuss.runSecureClient', whose connection only exists for the duration of its
-- callback, so the handle it returned pointed at an already-closed socket the
-- moment 'connect' returned; it now uses 'Wuss.newSecureClientConnection' and
-- keeps the close action. And the reader thread decoded every incoming frame
-- and then discarded it, so the pool's inbox was always empty and no event ever
-- reached the store.
module Krivostr.Relay
  ( RelayHandle(..)
  , connect
  , sendClient
  , close
  , parseUrl
  , sendAuth
  , currentChallenge
  ) where

import Control.Concurrent.Async (Async, async, cancel)
import Control.Concurrent.STM
import Control.Exception (SomeException, try)
import Control.Monad (void)
import qualified Data.ByteString.Lazy as BL
import Data.Aeson (Value, encode, eitherDecode)
import qualified Data.Aeson.Types as Aeson
import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as T
import Krivostr.Event
import Krivostr.Logging
import Krivostr.Wire
import Network.Socket (PortNumber)
import Network.WebSockets
import Wuss (newSecureClientConnection)

data RelayHandle = RelayHandle
  { rhUrl     :: !Text
  , rhConn    :: !Connection
  , rhInbox   :: !(TQueue RelayMessage)
  , rhOutbox  :: !(TQueue ClientMessage)
  , rhLogger  :: !Logger
  , rhCloser  :: !(IO ())
  -- | The worker threads. Held in a 'TVar' rather than directly in the record
  -- because the threads need the handle, so the handle cannot already contain
  -- them; 'connect' fills this in immediately after spawning them.
  , rhThreads :: !(TVar (Maybe (Async (), Async ())))
  -- | The newest NIP-42 challenge this relay has sent, if any.
  --
  -- Only the newest is kept. A relay may issue a fresh challenge at any time --
  -- on connect, or when a REQ is rejected -- and an older challenge is then
  -- worthless: signing it proves nothing about the current connection. Keeping
  -- the last one is what makes "sign whatever we are handed" safe.
  , rhChallenge :: !(TVar (Maybe Text))
  }

-- | Connect to a relay, start its reader and writer, and return a handle that
-- stays usable for as long as the caller keeps it.
connect :: Logger -> Text -> IO RelayHandle
connect lg url = do
  let (host, port, path) = parseUrl url
  emit lg Debug ("connecting: " <> url)
  (conn, closer) <-
    newSecureClientConnection (T.unpack host) port (T.unpack path)
  inbox   <- newTQueueIO
  outbox  <- newTQueueIO
  threads <- newTVarIO Nothing
  challenge <- newTVarIO Nothing
  let rh =
        RelayHandle
          { rhUrl = url
          , rhConn = conn
          , rhInbox = inbox
          , rhOutbox = outbox
          , rhLogger = lg
          , rhCloser = closer
          , rhThreads = threads
          , rhChallenge = challenge
          }
  reader <- async (readerLoop rh)
  writer <- async (writerLoop rh)
  atomically $ writeTVar threads (Just (reader, writer))
  -- Debug, not Info: the pool owns the authoritative "connected" line, and two
  -- Info lines per relay made a three-relay bridge look like six connections.
  emit lg Debug ("connected: " <> url)
  pure rh

-- | Read frames until the connection fails, decoding each one onto the inbox.
readerLoop :: RelayHandle -> IO ()
readerLoop rh = loop
  where
    lg = rhLogger rh
    loop = do
      outcome <- try (receiveData (rhConn rh)) :: IO (Either SomeException BL.ByteString)
      case outcome of
        Left err -> emit lg Warn (rhUrl rh <> ": receive failed: " <> T.pack (show err))
        Right raw -> case eitherDecode raw :: Either String Value of
          Left err -> emit lg Warn (rhUrl rh <> ": json: " <> T.pack err)
          -- RelayMessage is decoded by the bare Parser in Krivostr.Wire rather
          -- than a FromJSON instance, so it needs parseEither.
          Right val -> case Aeson.parseEither decodeRelay val of
            Left err -> emit lg Warn (rhUrl rh <> ": relay message: " <> T.pack err)
            Right msg -> do
              -- The delivery the old reader dropped.
              case msg of
                RChallenge c ->
                  -- Overwrite, never accumulate: a stale challenge is worse
                  -- than none, because it invites the client to sign something
                  -- the relay has already forgotten.
                  atomically $ writeTVar (rhChallenge rh) (Just c)
                _ -> pure ()
              atomically $ writeTQueue (rhInbox rh) msg
              loop

-- | Send queued client messages as text frames until the connection fails.
writerLoop :: RelayHandle -> IO ()
writerLoop rh = loop
  where
    lg = rhLogger rh
    loop = do
      cm <- atomically $ readTQueue (rhOutbox rh)
      -- Nostr carries JSON, so these go out as text frames, which is what the
      -- websockets API documents as the default for JSON protocols.
      outcome <-
        try (sendTextData (rhConn rh) (encode (encodeClient cm)))
          :: IO (Either SomeException ())
      case outcome of
        Left err -> emit lg Warn (rhUrl rh <> ": send failed: " <> T.pack (show err))
        Right () -> loop

sendClient :: RelayHandle -> ClientMessage -> IO ()
sendClient rh cm = atomically $ writeTQueue (rhOutbox rh) cm

-- | Answer the relay's outstanding NIP-42 challenge with a signed event.
--
-- The event is a kind 22242 with the relay's URL and the challenge string as
-- tags, which is what the relay checks. It is not stored and not published: it
-- exists only for the duration of this connection.
sendAuth :: RelayHandle -> Event -> IO ()
sendAuth rh ev = sendClient rh (CEvent ev)

-- | The relay's current challenge, if it has sent one.
currentChallenge :: RelayHandle -> IO (Maybe Text)
currentChallenge rh = readTVarIO (rhChallenge rh)

-- | Close the connection and stop the worker threads.
close :: RelayHandle -> IO ()
close rh = do
  void (try (sendClose (rhConn rh) ("bye" :: Text)) :: IO (Either SomeException ()))
  threads <- readTVarIO (rhThreads rh)
  case threads of
    Nothing -> pure ()
    Just (reader, writer) -> cancel reader >> cancel writer
  void (try (rhCloser rh) :: IO (Either SomeException ()))
  emit (rhLogger rh) Info ("closed: " <> rhUrl rh)

-- | Split a @wss://host:port/path@ URL into the parts 'connect' needs, defaulting
-- to port 443 and path @/@.
--
-- The port is a 'PortNumber' because that is what the socket API wants;
-- 'PortNumber' has a 'Num' instance, so callers can still write plain literals.
parseUrl :: Text -> (Text, PortNumber, Text)
parseUrl url =
  let noScheme = T.replace "wss://" "" (T.replace "ws://" "" url)
      (hostPort, path) = T.breakOn "/" noScheme
      path' = if T.null path then "/" else path
      (host, port) = case T.splitOn ":" hostPort of
        [h, p] -> (h, readPort p)
        [h] -> (h, 443)
        _ -> (hostPort, 443)
  in (host, port, path')
  where
    readPort :: Text -> PortNumber
    readPort p = case readDecimal (T.unpack p) of
      Just n -> fromIntegral n
      Nothing -> 443

-- | 'readMaybe' would accept leading @+@, @-@ and spaces; a port in a URL may
-- only be plain digits.
readDecimal :: String -> Maybe Int
readDecimal str
  | not (null str) && all isDigit str = Just (read str)
  | otherwise = Nothing
