{-# LANGUAGE OverloadedStrings #-}
module Krivostr.Pool
  ( Pool
  , newPool
  , addRelay
  , removeRelay
  , broadcast
  , subscribe
  ) where

import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Monad (forM_, forever)
import Data.Text (Text)
import qualified Data.Map.Strict as M
import Krivostr.Event
import Krivostr.Logging
import Krivostr.Relay
import Krivostr.Wire
import qualified Krivostr.Filter

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
  }

newPool :: Logger -> (Event -> IO ()) -> IO Pool
newPool lg h = Pool <$> newTVarIO M.empty <*> pure lg <*> pure h

-- | Connect to a relay unless it is already connected.
addRelay :: Pool -> Text -> IO ()
addRelay p url = do
  connected <- readTVarIO (plRelays p)
  case M.lookup url connected of
    Just _ -> emit (plLogger p) Debug ("already connected: " <> url)
    Nothing -> do
      rh <- connect (plLogger p) url
      dr <- async (drain p rh)
      atomically $ modifyTVar' (plRelays p) (M.insert url (PoolEntry rh dr))
      emit (plLogger p) Info ("connected: " <> url)

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
    ROk _ _ m   -> emit (plLogger p) Debug ("ok: " <> m)
    REose s     -> emit (plLogger p) Debug ("eose: " <> s)

broadcast :: Pool -> ClientMessage -> IO ()
broadcast p cm = do
  relays <- readTVarIO (plRelays p)
  forM_ (M.elems relays) $ \e -> sendClient (peRelay e) cm

subscribe :: Pool -> Text -> [Krivostr.Filter.Filter] -> IO ()
subscribe p sid fs = broadcast p (CReq sid fs)
