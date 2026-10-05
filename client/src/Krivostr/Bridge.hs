{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The bridge: an HTTP static file server plus a @\/ws@ WebSocket endpoint.
--
-- Two things were wrong here before. 'runBridge' wrote @app@ with an 'Application'
-- arity while calling 'websocketsOr' with a 'ServerApp' arity, so it did not
-- compile. More importantly, events arriving from upstream relays were only
-- written to the store: nothing was ever pushed to the browser clients that
-- had actually sent the REQ, so a subscription delivered its cached events and
-- its EOSE and then stayed silent forever. Upstream events now fan out to every
-- client whose subscriptions match.
module Krivostr.Bridge
  ( runBridge
  , BridgeConfig(..)
  , parseClient
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.STM
import Control.Exception (SomeException, finally, try)
import Control.Monad (forever, forM_, void, when)
import Data.Aeson (Value (String), encode, eitherDecode, object, parseJSON, toJSON, withArray, (.=))
import qualified Data.ByteString.Lazy as BL
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as M
import Network.HTTP.Types (hContentType, status200, status400, status404)
import Network.Wai
import Network.Wai.Handler.Warp
  ( defaultSettings
  , runSettings
  , setBeforeMainLoop
  , setHost
  , setPort
  )
import Data.Streaming.Network.Internal (HostPreference (Host))
import Network.Wai.Application.Static (defaultWebAppSettings, staticApp)
import System.FilePath ((</>))
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.WebSockets
import Krivostr.Event (Event, evId)
import Krivostr.Filter (Filter (fLimit))
import qualified Krivostr.Filter as Filter
import Krivostr.Logging
import Krivostr.Nip.Nip01 (verifyEvent)
import Krivostr.Pool
import Krivostr.Store
import Krivostr.Wire

data BridgeConfig = BridgeConfig
  { bcPort      :: !Int
  , bcHost      :: !Text
  , bcStaticDir :: !FilePath
  , bcUpstreams :: ![Text]
  }

-- | Everything one connected browser client owns.
data ClientState = ClientState
  { csId     :: !Int
  , csOutbox :: !(TQueue Value)
  -- | Subscription id to that subscription's filters. A REQ may carry several
  -- filters and the event matches if it matches any of them, so this holds a
  -- list rather than the single filter the old code kept.
  , csSubs   :: !(TVar (M.Map Text [Filter.Filter]))
  }

data BridgeState = BridgeState
  { bsLogger  :: !Logger
  , bsPool    :: !Pool
  , bsStore   :: !Store
  , bsClients :: !(TVar (M.Map Int ClientState))
  , bsNextId  :: !(TVar Int)
  }

-- | Run the bridge: HTTP static file server + /ws WebSocket endpoint.
runBridge :: Logger -> BridgeConfig -> Store -> IO ()
runBridge lg cfg store = do
  clients <- newTVarIO M.empty
  nextId  <- newTVarIO 0
  pool    <- newPool lg (onUpstreamEvent lg clients store)
  let bst = BridgeState lg pool store clients nextId

  -- Background GC thread: evict expired events every hour.
  _ <- async $ forever $ do
    threadDelay (60 * 60 * 1000000)
    void $ evictExpired store

  -- Background relay thread: connect the upstream set now, then re-offer it
  -- every half minute. 'addRelay' skips relays that are already connected, so
  -- the repeat brings back any that were unreachable or have since dropped.
  --
  -- This runs in the background on purpose. Connecting first meant a relay on a
  -- network that blackholes packets delayed the point where the HTTP listener
  -- started, so a bridge with one unreachable relay could sit silent instead of
  -- serving the UI and reporting the relay as unavailable.
  _ <- async $ forever $ do
    forM_ (bcUpstreams cfg) (addRelay pool)
    threadDelay (30 * 1000000)
  emit lg Info
    ("bridge: " <> T.pack (show (length (bcUpstreams cfg))) <> " upstream relays")

  let settings =
        setPort (bcPort cfg)
          $ setHost (Host (T.unpack (bcHost cfg)))
          $ setBeforeMainLoop
              (emit lg Info ("bridge: listening on http://" <> bcHost cfg <> ":" <> T.pack (show (bcPort cfg))))
          $ defaultSettings

  runSettings settings (app bst cfg)
  where
    -- 'websocketsOr' is a 'Middleware': it upgrades matching requests and hands
    -- everything else to the fallback 'Application'.
    app :: BridgeState -> BridgeConfig -> Application
    app bst' cfg' =
      websocketsOr
        defaultConnectionOptions
        (wsApp bst')
        (fallback cfg')
    fallback cfg' req respond
      | pathInfo req == ["ws"] =
          respond (responseLBS status400 [] "expected a websocket upgrade")
      -- A browser asks for a bare "/" first, and wai-app-static answers that
      -- with a 404: it only looks for files, and the UI has no client-side
      -- routing, so the root is the one path that needs naming by hand. wai
      -- drops the leading slash, so "/" arrives here as an empty segment list.
      | null (pathInfo req) = do
          let index = bcStaticDir cfg' </> "index.html"
          loaded <- try (BL.readFile index) :: IO (Either SomeException BL.ByteString)
          respond $ case loaded of
            Left _    -> responseLBS status404 [] "index.html not found"
            Right html -> responseLBS status200 [(hContentType, "text/html; charset=utf-8")] html
      | otherwise =
          staticApp (defaultWebAppSettings (bcStaticDir cfg')) req respond

-- | Wire a single WebSocket client. Registers it for upstream fan-out, serves
-- its requests until the socket dies, then unregisters it and stops its writer.
wsApp :: BridgeState -> ServerApp
wsApp bst pending = do
  conn <- acceptRequest pending
  cid <- atomically $ do
    n <- readTVar (bsNextId bst)
    writeTVar (bsNextId bst) (n + 1)
    pure n
  outbox <- newTQueueIO
  subs   <- newTVarIO M.empty
  let cs = ClientState cid outbox subs
  atomically $ modifyTVar' (bsClients bst) (M.insert cid cs)
  writer <- async (writerLoop (bsLogger bst) cid conn outbox)
  emit (bsLogger bst) Debug ("bridge: client " <> T.pack (show cid) <> " connected")
  let cleanup = do
        cancel writer
        atomically $ modifyTVar' (bsClients bst) (M.delete cid)
  flip finally cleanup $ readerLoop bst cs conn

writerLoop :: Logger -> Int -> Connection -> TQueue Value -> IO ()
writerLoop lg cid conn q = loop
  where
    loop = do
      v <- atomically $ readTQueue q
      outcome <-
        try (sendTextData conn (encode v)) :: IO (Either SomeException ())
      case outcome of
        -- The client is gone; the reader thread is what notices, so just stop.
        Left err -> emit lg Debug
          ("bridge: client " <> T.pack (show cid) <> " write failed: " <> T.pack (show err))
        Right () -> loop

readerLoop :: BridgeState -> ClientState -> Connection -> IO ()
readerLoop bst cs conn = loop
  where
    lg = bsLogger bst
    loop = do
      outcome <-
        try (receiveData conn) :: IO (Either SomeException BL.ByteString)
      case outcome of
        Left err -> emit lg Debug
          ("bridge: client " <> T.pack (show (csId cs)) <> " read ended: " <> T.pack (show err))
        Right raw -> case eitherDecode raw of
          Left err -> enqueue (csOutbox cs) (noticeMsg ("invalid json: " <> T.pack err))
          Right v -> handleClientMsg bst cs v >> loop

enqueue :: TQueue Value -> Value -> IO ()
enqueue q v = atomically $ writeTQueue q v

-- | Relay-to-client frames. Each element needs its own 'toJSON': tagging the
-- list as @[Value]@ made the string elements fail to typecheck.
noticeMsg :: Text -> Value
noticeMsg t = toJSON [toJSON ("NOTICE" :: Text), toJSON t]

eventMsg :: Text -> Event -> Value
eventMsg sid e = toJSON [toJSON ("EVENT" :: Text), toJSON sid, toJSON e]

eoseMsg :: Text -> Value
eoseMsg sid = toJSON [toJSON ("EOSE" :: Text), toJSON sid]

okMsg :: Text -> Bool -> Text -> Value
okMsg eid accepted msg =
  toJSON [toJSON ("OK" :: Text), toJSON eid, toJSON accepted, toJSON msg]

handleClientMsg :: BridgeState -> ClientState -> Value -> IO ()
handleClientMsg bst cs v = case parseMaybe parseClient v of
  Nothing -> enqueue (csOutbox cs) (noticeMsg "unknown message")
  Just (CReq sid filters) -> do
    atomically $ modifyTVar' (csSubs cs) (M.insert sid filters)
    -- Serve cached events first, then stay subscribed for live ones.
    cached <- concat <$> mapM (queryEvents (bsStore bst)) filters
    forM_ (dedupe cached) $ \e -> enqueue (csOutbox cs) (eventMsg sid e)
    enqueue (csOutbox cs) (eoseMsg sid)
    broadcast (bsPool bst) (CReq sid filters)

  Just (CEvent e) -> do
    let lg = bsLogger bst
    if verifyEvent e
      then do
        _ <- insertEvent (bsStore bst) e
        broadcast (bsPool bst) (CEvent e)
        -- Other local clients watching the same kinds should see this too.
        deliverEvent bst e
        enqueue (csOutbox cs) (okMsg (evId e) True "")
      else do
        emit lg Warn ("bridge: rejected event " <> evId e <> " (invalid signature)")
        enqueue (csOutbox cs) (okMsg (evId e) False "invalid signature")

  Just (CClose sid) -> do
    atomically $ modifyTVar' (csSubs cs) (M.delete sid)
    broadcast (bsPool bst) (CClose sid)

  -- NIP-45: answered from SQLite and never forwarded. A count is a local
  -- question -- the bridge knows its own store, and upstream relays answer
  -- for themselves when asked directly. Overlapping filters union by id, so
  -- one event matching two filters counts once.
  Just (CCount sid filters) -> do
    n <- countUnion (bsStore bst) filters
    enqueue (csOutbox cs) (countMsg sid n)

-- | Push an event to every connected client with a matching subscription.
deliverEvent :: BridgeState -> Event -> IO ()
deliverEvent bst e = do
  clients <- readTVarIO (bsClients bst)
  forM_ (M.elems clients) $ \cs -> do
    subs <- readTVarIO (csSubs cs)
    forM_ (M.toList subs) $ \(sid, filters) ->
      -- One REQ may carry many filters; any match delivers.
      when (any (\f -> Filter.matches f e) filters) $
        enqueue (csOutbox cs) (eventMsg sid e)

-- | Called whenever an upstream relay delivers an event: persist it, then hand
-- it to the local clients that asked for it.
onUpstreamEvent :: Logger -> TVar (M.Map Int ClientState) -> Store -> Event -> IO ()
onUpstreamEvent lg clientsVar store e = do
  if verifyEvent e
    then do
      inserted <- insertEvent store e
      when inserted $ do
        emit lg Debug ("bridge: cached " <> evId e)
        clients <- readTVarIO clientsVar
        forM_ (M.elems clients) $ \cs -> do
          subs <- readTVarIO (csSubs cs)
          forM_ (M.toList subs) $ \(sid, filters) ->
            when (any (\f -> Filter.matches f e) filters) $
              enqueue (csOutbox cs) (eventMsg sid e)
    else
      emit lg Warn ("bridge: rejected upstream event " <> evId e <> " (invalid signature)")

-- | Distinct events by id, keeping first-seen order. A REQ with overlapping
-- filters can return the same row more than once.
dedupe :: [Event] -> [Event]
dedupe = go mempty
  where
    go _ [] = []
    go seen (e:es)
      | evId e `elem` seen = go seen es
      | otherwise          = e : go (evId e : seen) es

countMsg :: Text -> Int -> Value
countMsg sid n = toJSON [toJSON ("COUNT" :: Text), toJSON sid, object ["count" .= n]]

-- | Count matches across the filters of one COUNT. A single filter counts
-- exactly in SQL; several union by id, bounded by 'countCap', because an
-- event matching two filters is still one event.
countUnion :: Store -> [Filter] -> IO Int
countUnion st [f] = countMatching st f
countUnion st fs = do
  evs <- concat <$> mapM (\f -> queryEvents st (f { fLimit = Just countCap })) fs
  pure (length (dedupe evs))

-- | Parse a client message into our ADT. Mirrors @decodeRelay@.
--
-- Subscriptions are variadic, @[\"REQ\", <subscription_id>, <filter>, ...]@, so
-- every element after the subscription id is a filter. A REQ with no filters
-- carries no subscription at all and is rejected.
parseClient :: Value -> Parser ClientMessage
parseClient = withArray "ClientMessage" $ \arr -> case toList arr of
  [String "EVENT", ev]                        -> CEvent <$> parseJSON ev
  (String "REQ" : String sid : fs@(_:_))      -> CReq sid <$> traverse parseJSON fs
  [String "CLOSE", String sid]                -> pure (CClose sid)
  (String "COUNT" : String sid : fs@(_:_))    -> CCount sid <$> traverse parseJSON fs
  _                                          -> fail "unknown"
  where
    toList = foldr (:) []
