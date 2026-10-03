{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Krivostr.Bridge
  ( runBridge
  , BridgeConfig(..)
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (async)
import Control.Concurrent.STM
import Control.Exception (SomeException, try)
import Control.Monad (forever, forM_, unless, void, when)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Map.Strict as M
import Network.HTTP.Types (status200)
import Network.Wai
import Network.Wai.Handler.Warp (runSettings, setPort, setBeforeMainLoop, defaultSettings)
import Network.Wai.Application.Static (staticApp, defaultWebAppSettings)
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.WebSockets
import System.FilePath ((</>))
import Krivostr.Event
import Krivostr.Filter
import Krivostr.Logging
import Krivostr.Pool
import Krivostr.Store
import Krivostr.Wire

data BridgeConfig = BridgeConfig
  { bcPort      :: !Int
  , bcStaticDir :: !FilePath
  , bcUpstreams :: ![Text]
  }

-- | Run the bridge: HTTP static file server + /ws WebSocket endpoint.
runBridge :: Logger -> BridgeConfig -> Store -> IO ()
runBridge lg cfg store = do
  pool <- newPool lg (onUpstreamEvent lg store)
  forM_ (bcUpstreams cfg) (addRelay pool)
  emit lg Info ("bridge: " <> T.pack (show (length (bcUpstreams cfg)))
                <> " upstream relays")

  -- Background GC thread: evict expired events every hour.
  _ <- async $ forever $ do
    threadDelay (60 * 60 * 1000000)
    void $ evictExpired store

  let settings = setPort (bcPort cfg)
               $ setBeforeMainLoop (emit lg Info
                   ("bridge: listening on :" <> T.pack (show (bcPort cfg))))
               $ defaultSettings

  runSettings settings (app pool store)
  where
    app pool store' req respond
      | pathInfo req == ["ws"] =
          websocketsOr defaultConnectionOptions (wsApp pool store') (const (respond (responseLBS status200 [] "upgrade required"))) req
      | otherwise =
          staticApp (defaultWebAppSettings (bcStaticDir cfg)) req respond

-- | Wire a single WebSocket client.
wsApp :: Pool -> Store -> ServerApp
wsApp pool store pending = do
  conn <- acceptRequest pending
  subs <- newTVarIO (M.empty :: M.Map Text Filter)
  -- Per-client outbound queue drained by a writer thread.
  outbox <- newTQueueIO
  _ <- async (writerLoop conn outbox)
  readerLoop pool store subs outbox conn

writerLoop :: Connection -> TQueue Value -> IO ()
writerLoop conn q = forever $ do
  v <- atomically $ readTQueue q
  sendTextData conn (BL.toStrict (encode v))

enqueue :: TQueue Value -> Value -> IO ()
enqueue q v = atomically $ writeTQueue q v

readerLoop
  :: Pool
  -> Store
  -> TVar (M.Map Text Filter)
  -> TQueue Value
  -> Connection
  -> IO ()
readerLoop pool store subs outbox conn = do
  r <- try (forever $ do
    raw <- receiveData conn
    case eitherDecode (BL.fromStrict raw) of
      Left err -> enqueue outbox (toJSON (["NOTICE", String (T.pack err)] :: [Value]))
      Right v  -> handleClientMsg pool store subs outbox v)
  case r of
    Left (_ :: SomeException) -> pure ()
    Right () -> pure ()

handleClientMsg
  :: Pool
  -> Store
  -> TVar (M.Map Text Filter)
  -> TQueue Value
  -> Value
  -> IO ()
handleClientMsg pool store subs outbox v = case parseMaybe parseClient v of
  Nothing -> enqueue outbox (toJSON (["NOTICE", String "unknown message"] :: [Value]))
  Just (CReq sid filters) -> do
    let f = case filters of
              (x:_) -> x
              []    -> empty
    atomically $ modifyTVar' subs (M.insert sid f)
    -- Serve cached events first, then live subscription upstream.
    cached <- queryEvents store f
    forM_ cached $ \e ->
      enqueue outbox (toJSON (["EVENT", String sid, toJSON e] :: [Value]))
    enqueue outbox (toJSON (["EOSE", String sid] :: [Value]))
    broadcast pool (CReq sid filters)

  Just (CEvent e) -> do
    _ <- insertEvent store e
    broadcast pool (CEvent e)
    enqueue outbox (toJSON (["OK", String (evId e), Bool True, String ""] :: [Value]))

  Just (CClose sid) -> do
    atomically $ modifyTVar' subs (M.delete sid)
    broadcast pool (CClose sid)

-- | Parse a client message into our ADT. Mirrors `decodeRelay`.
parseClient :: Value -> Maybe ClientMessage
parseClient = withArray "ClientMessage" $ \arr -> case toList arr of
  [String "EVENT", ev]         -> CEvent <$> parseJSON ev
  [String "REQ", String sid, fs] -> CReq sid <$> parseJSON fs
  [String "CLOSE", String sid] -> pure (CClose sid)
  _ -> fail "unknown"
  where
    toList = foldr (:) []

-- | Called whenever an upstream relay delivers an event. Persist it.
onUpstreamEvent :: Logger -> Store -> Event -> IO ()
onUpstreamEvent lg store e = do
  inserted <- insertEvent store e
  when inserted $
    emit lg Debug ("bridge: cached " <> evId e)
