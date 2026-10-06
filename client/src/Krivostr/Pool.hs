{-# LANGUAGE OverloadedStrings #-}
module Krivostr.Pool
  ( Pool
  , newPool
  , newPoolWithKey
  , addRelay
  , removeRelay
  , broadcast
  , subscribe
  , BroadcastFailure(..)
  , broadcastEvent
  ) where

import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Exception (SomeException, try)
import Control.Monad (forM_, forever)
import System.Timeout (timeout)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as M
import Krivostr.Event
import Krivostr.Key
import Krivostr.Nip.Nip42
import Krivostr.Logging
import Krivostr.Relay
import Krivostr.Wire
import qualified Krivostr.Filter
import Data.Time.Clock.POSIX (getPOSIXTime)

-- | A relay together with the thread draining its inbox.
--
-- Keeping the 'Async' next to the handle is what lets 'addRelay' notice that a
-- URL is already connected. The previous version replaced the map entry on a
-- repeat call, which orphaned the old socket along with its reader, its writer,
-- and its drain thread, and left the new handle pointed at a second live
-- connection to the same relay.
data PoolEntry = PoolEntry !RelayHandle !(Async ())

-- | Async has no Show instance, so this stays a plain selector over a
-- positional constructor rather than a record field.
peRelay :: PoolEntry -> RelayHandle
peRelay (PoolEntry rh _) = rh

data Pool = Pool
  { plRelays  :: TVar (M.Map Text PoolEntry)
  , plLogger  :: !Logger
  , plHandler :: Event -> IO ()
  -- | The key used to answer NIP-42 challenges, if the user has one loaded.
  --
  -- Optional because a bridge with no key is still useful: it can read public
  -- relays, and a relay that demands AUTH will simply refuse its writes. When a
  -- key is present the pool answers every challenge as it arrives, which is
  -- what "auth-required" relays expect -- they issue the challenge on connect
  -- and reject everything until it is answered.
  , plKey     :: !(Maybe PrivateKey)
  -- | Events awaiting an OK, by event id: a done flag plus the last
  -- refusal seen. 'broadcastEvent' registers before sending (a relay can
  -- answer faster than a slow reader loops). An accept completes the wait;
  -- refusals only update the message, so one fast refusal cannot mask a
  -- slower accept from another relay.
  , plAcks    :: TVar (M.Map Text (TMVar (), TVar Text))
  }

newPool :: Logger -> (Event -> IO ()) -> IO Pool
newPool lg h = Pool <$> newTVarIO M.empty <*> pure lg <*> pure h <*> pure Nothing <*> newTVarIO M.empty

-- | 'newPool' with a key, so the pool can answer NIP-42 challenges.
newPoolWithKey :: Logger -> (Event -> IO ()) -> PrivateKey -> IO Pool
newPoolWithKey lg h k = Pool <$> newTVarIO M.empty <*> pure lg <*> pure h <*> pure (Just k) <*> newTVarIO M.empty

-- | Connect to a relay unless it is already connected.
--
-- A relay that refuses the WebSocket handshake -- a captive portal, a rate
-- limiter answering 503, a relay that is simply down -- makes 'connect' throw.
-- That used to escape and take the whole process down with it, losing the
-- relays that had already connected; a relay that cannot be reached is now
-- reported and left out of the pool, so a later call can retry it.
addRelay :: Pool -> Text -> IO ()
addRelay p url = do
  connected <- readTVarIO (plRelays p)
  case M.lookup url connected of
    Just _ -> emit (plLogger p) Debug ("already connected: " <> url)
    Nothing -> do
      attempt <- try (connect (plLogger p) url) :: IO (Either SomeException RelayHandle)
      case attempt of
        Left e -> emit (plLogger p) Warn
          ("relay unavailable: " <> url <> ": " <> oneLine (show e))
        Right rh -> do
          dr <- async (drain p rh)
          atomically $ modifyTVar' (plRelays p) (M.insert url (PoolEntry rh dr))
          emit (plLogger p) Info ("connected: " <> url)

-- | First line of a multi-line exception message, which is all that fits in a
-- log line and all that says anything useful.
oneLine :: String -> Text
oneLine = T.strip . T.takeWhile (/= '\n') . T.pack

-- | Disconnect a relay and stop draining it. False if it was not connected.
removeRelay :: Pool -> Text -> IO Bool
removeRelay p url = do
  -- modifyTVar' returns (), so take the entry out by hand to report whether
  -- the relay had been connected at all.
  entry <- atomically $ do
    relays <- readTVar (plRelays p)
    modifyTVar' (plRelays p) (M.delete url)
    pure (M.lookup url relays)
  case entry of
    Nothing -> pure False
    Just (PoolEntry rh dr) -> do
      cancel dr
      close rh
      emit (plLogger p) Info ("disconnected: " <> url)
      pure True

-- | Forward upstream relay frames into the pool's handler.
drain :: Pool -> RelayHandle -> IO ()
drain p rh = forever $ do
  msg <- atomically $ readTQueue (rhInbox rh)
  case msg of
    REvent _ ev -> plHandler p ev
    RNotice t   -> emit (plLogger p) Info  ("notice: " <> t)
    RClosed s t -> emit (plLogger p) Warn  ("closed " <> s <> ": " <> t)
    ROk eid ok m -> do
      emit (plLogger p) Debug ("ok: " <> m)
      atomically $ do
        waiters <- readTVar (plAcks p)
        case M.lookup eid waiters of
          Nothing -> pure ()
          Just (done, refusal)
            | ok -> do
                putTMVar done ()
                modifyTVar' (plAcks p) (M.delete eid)
            | otherwise -> writeTVar refusal m
    REose s     -> emit (plLogger p) Debug ("eose: " <> s)
    RChallenge c -> do
      emit (plLogger p) Info ("auth challenge: " <> c)
      case plKey p of
        Nothing ->
          -- Without a key there is nothing to answer with. Say so once rather
          -- than on every challenge, and leave the relay to refuse.
          emit (plLogger p) Warn "no key loaded: cannot answer auth challenge"
        Just k -> do
          -- Build the kind 22242 event and send it. The relay checks the
          -- signature, that the relay tag names it, and that the challenge
          -- matches the one it issued, so all three come from the relay's own
          -- message rather than from anything we guess.
          now <- getPOSIXTime
          let ev =
                Krivostr.Nip.Nip42.buildAuthEvent
                  k
                  (rhUrl rh)
                  c
                  now
          sendAuth rh ev

broadcast :: Pool -> ClientMessage -> IO ()
broadcast p cm = do
  relays <- readTVarIO (plRelays p)
  -- What went out, in the form the relay saw it: when a relay answers "bad
  -- req", the only way to tell whether it is our filter or our framing is to
  -- read the frame that was actually sent.
  emit (plLogger p) Debug ("relay <- " <> T.pack (BL.unpack (Aeson.encode (encodeClient cm))))
  forM_ (M.elems relays) $ \e -> sendClient (peRelay e) cm

subscribe :: Pool -> Text -> [Krivostr.Filter.Filter] -> IO ()
subscribe p sid fs = broadcast p (CReq sid fs)

-- | Why a publish got no confirmation. The bridge queues on 'NoRelays' and
-- 'Timeout' but not on 'Rejected': a relay that refuses (auth, rate limit,
-- policy) will refuse again in thirty seconds, so retrying is noise.
data BroadcastFailure
  = NoRelays
  | Timeout Text
  | Rejected Text
  deriving (Show, Eq)

-- | Publish one event and wait for a relay to confirm it. Success is the
-- first accepting OK. An empty pool fails immediately rather than hanging:
-- nothing is listening, so waiting would only burn the timeout.
--
-- The waiter is registered before sending and removed on settle, so a slow
-- reader cannot miss a fast relay and a settled waiter cannot leak. Late
-- OKs after a settle find no entry and stay log lines.
broadcastEvent :: Pool -> Event -> Int -> IO (Either BroadcastFailure Text)
broadcastEvent p ev waitMicros = do
  relays <- readTVarIO (plRelays p)
  if M.null relays
    then pure (Left NoRelays)
    else do
      done <- newEmptyTMVarIO
      refusal <- newTVarIO ""
      atomically $ modifyTVar' (plAcks p) (M.insert (evId ev) (done, refusal))
      broadcast p (CEvent ev)
      accepted <- timeout waitMicros (atomically (takeTMVar done))
      atomically $ modifyTVar' (plAcks p) (M.delete (evId ev))
      case accepted of
        Just () -> pure (Right "")
        Nothing -> do
          lastRefusal <- readTVarIO refusal
          pure (Left (if T.null lastRefusal
            then Timeout "no relay confirmed in time"
            else Rejected lastRefusal))
