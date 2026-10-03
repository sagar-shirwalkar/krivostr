{-# LANGUAGE OverloadedStrings #-}
module Krivostr.Pool
  ( Pool
  , newPool
  , addRelay
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

data Pool = Pool
  { plRelays  :: TVar (M.Map Text RelayHandle)
  , plLogger  :: Logger
  , plHandler :: Event -> IO ()
  }

newPool :: Logger -> (Event -> IO ()) -> IO Pool
newPool lg h = Pool <$> newTVarIO M.empty <*> pure lg <*> pure h

addRelay :: Pool -> Text -> IO ()
addRelay p url = do
  rh <- connect (plLogger p) url
  atomically $ modifyTVar' (plRelays p) (M.insert url rh)
  _ <- async $ drain p rh
  emit (plLogger p) Info ("connected: " <> url)

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
  forM_ (M.elems relays) $ \rh -> sendClient rh cm

subscribe :: Pool -> Text -> [Krivostr.Filter.Filter] -> IO ()
subscribe p sid fs = broadcast p (CReq sid fs)
