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
  -- Test seams: the client suite drives 'handleClientMsg' directly, because
  -- the interesting bridge behaviours (store-then-forward, outbox on empty
  -- pool) need no socket, only a state and a queue.
  , BridgeState(..)
  , ClientState(..)
  , handleClientMsg
  , retryRelays
  , maxRetries
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.STM
import Control.Exception (SomeException, finally, try)
import Control.Monad (forever, forM_, void, when)
import Data.Aeson (Value (String), encode, eitherDecode, object, parseJSON, toJSON, withArray, withObject, (.:), (.=))
import qualified Data.ByteString.Lazy as BL
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as M
import Network.HTTP.Types (hContentType, methodDelete, methodGet, methodPost, status200, status400, status404, status405)
import Network.Wai
import qualified Network.Wai as Wai
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
  -- | Upstreams that failed to dial and are being retried, with attempt
  -- counts. Ephemeral by design: entries that never connect are dropped
  -- after 'maxRetries', so a pool of retry to-dos cannot grow without
  -- bound no matter how many dead URLs arrive.
  , bsRetries :: !(TVar (M.Map Text Int))
  }

-- | Run the bridge: HTTP static file server + /ws WebSocket endpoint.
runBridge :: Logger -> BridgeConfig -> Store -> IO ()
runBridge lg cfg store = do
  clients <- newTVarIO M.empty
  nextId  <- newTVarIO 0
  retries <- newTVarIO M.empty
  pool    <- newPool lg (onUpstreamEvent lg clients store)
  let bst = BridgeState lg pool store clients nextId retries

  -- Background GC thread: evict expired events every hour.
  _ <- async $ forever $ do
    threadDelay (60 * 60 * 1000000)
    void $ evictExpired store

  -- Background relay thread: connect the upstream set now, then re-offer it
  -- every half minute. 'addRelay' skips relays that are already connected, so
  -- the repeat brings back any that were unreachable or have since dropped.
  -- Each pass also flushes the outbox and retries failed dials.
  --
  -- This runs in the background on purpose. Connecting first meant a relay on a
  -- network that blackholes packets delayed the point where the HTTP listener
  -- started, so a bridge with one unreachable relay could sit silent instead of
  -- serving the UI and reporting the relay as unavailable.
  _ <- async $ forever $ do
    forM_ (bcUpstreams cfg) (addRelay pool)
    retryRelays bst
    flushOutbox bst
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
        (fallback bst' cfg')
    fallback bst' cfg' req respond
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
      -- The relay control channel: the UI relay form manages upstream relays
      -- here (same origin, no extra port). Static files never live at /relays,
      -- so this match costs nothing when the UI is served.
      | pathInfo req == ["relays"] = relaysRoute bst' req >>= respond
      | otherwise =
          staticApp (defaultWebAppSettings (bcStaticDir cfg')) req respond

-- | @GET@ lists connected and configured relays; @POST {"url"}@ connects
-- and remembers; @DELETE {"url"}@ disconnects and forgets. Anything else is
-- a 405: the method list is the contract, not a suggestion.
relaysRoute :: BridgeState -> Wai.Request -> IO Wai.Response
relaysRoute bst req = case requestMethod req of
  m | m == methodGet -> do
    connected <- poolRelays (bsPool bst)
    configured <- getRelayConfig (bsStore bst)
    json status200 (object ["connected" .= connected, "configured" .= configured])
  m | m == methodPost || m == methodDelete -> do
    body <- strictRequestBody req
    case eitherDecode body of
      Left e -> json status400 (object ["error" .= ("body must be {\"url\": ...}: " <> e)])
      Right v -> case relayUrlOf v of
        Left e    -> json status400 (object ["error" .= e])
        Right url
          | m == methodPost -> do
              -- A failed dial stays ephemeral: it joins the retry set, not
              -- the config table, so dead URLs cannot accumulate on disk.
              -- Only a relay that actually connected is remembered.
              addRelay (bsPool bst) url
              connected <- poolRelays (bsPool bst)
              if url `elem` connected
                then do
                  addRelayConfig (bsStore bst) url
                  replaySubs bst url
                  json status200 (object ["added" .= url, "connected" .= True])
                else do
                  atomically $ modifyTVar' (bsRetries bst) (M.insertWith (\_ old -> old) url 0)
                  json status200 (object ["added" .= url, "connected" .= False, "retrying" .= True])
          | otherwise -> do
              _ <- removeRelay (bsPool bst) url
              removeRelayConfig (bsStore bst) url
              atomically $ modifyTVar' (bsRetries bst) (M.delete url)
              json status200 (object ["removed" .= url])
  _ -> json status405 (object ["error" .= ("use GET, POST, or DELETE" :: Text)])
  where
    json st v = pure (responseLBS st [(hContentType, "application/json")] (encode v))
    relayUrlOf v = case parseMaybe urlParser v of
      Just u | "wss://" `T.isPrefixOf` u -> Right u
      Just _ -> Left ("not a relay URL (try wss://…)" :: Text)
      Nothing -> Left ("body must be {\"url\": ...}" :: Text)
    urlParser = withObject "relay" $ \o -> o .: "url"

-- | Retries before a failed dial is dropped. Twelve passes at thirty
-- seconds is six minutes: generous to spotty connections, bounded for
-- memory, disk, and the relay loop's own time.
maxRetries :: Int
maxRetries = 12

-- | Retry every failed dial once. Success replays subscriptions and clears
-- the entry; exhaustion drops it with a warning. Either way the map only
-- shrinks from here — entries are added solely by POST /relays, one per
-- failed dial, and each pass removes at least the exhausted ones.
retryRelays :: BridgeState -> IO ()
retryRelays bst = do
  pending <- readTVarIO (bsRetries bst)
  forM_ (M.toList pending) $ \(url, attempts) ->
    if attempts >= maxRetries
      then do
        atomically $ modifyTVar' (bsRetries bst) (M.delete url)
        emit (bsLogger bst) Warn ("bridge: giving up on " <> url <> " after " <> T.pack (show attempts) <> " tries")
      else do
        addRelay (bsPool bst) url
        connected <- poolRelays (bsPool bst)
        if url `elem` connected
          then do
            atomically $ modifyTVar' (bsRetries bst) (M.delete url)
            -- The POST asked for this relay; the retry finished the job,
            -- so the original intent (remember it) still applies.
            addRelayConfig (bsStore bst) url
            replaySubs bst url
            emit (bsLogger bst) Info ("bridge: retry connected " <> url)
          else atomically $ modifyTVar' (bsRetries bst) (M.insert url (attempts + 1))

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

  -- Verification lives in 'insertEvent': a stored event is a verified
  -- event by construction, and every ingest path funnels through it. The
  -- browser always gets an accepting OK for a valid event -- the bridge took
  -- it -- while upstream forwarding settles separately: confirmed relays
  -- get it now, and anything unconfirmed waits in the outbox for the flush
  -- loop. Local clients see it either way.
  Just (CEvent e) -> do
    let lg = bsLogger bst
    stored <- insertEvent (bsStore bst) e
    case stored of
      InvalidSignature -> do
        emit lg Warn ("bridge: rejected event " <> evId e <> " (invalid signature)")
        enqueue (csOutbox cs) (okMsg (evId e) False "invalid signature")
      Duplicate -> do
        forward bst e
        enqueue (csOutbox cs) (okMsg (evId e) True "duplicate")
      Inserted -> do
        deliverEvent bst e
        forward bst e
        enqueue (csOutbox cs) (okMsg (evId e) True "")

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
  stored <- insertEvent store e
  case stored of
    Inserted -> do
      emit lg Debug ("bridge: cached " <> evId e)
      clients <- readTVarIO clientsVar
      forM_ (M.elems clients) $ \cs -> do
        subs <- readTVarIO (csSubs cs)
        forM_ (M.toList subs) $ \(sid, filters) ->
          when (any (\f -> Filter.matches f e) filters) $
            enqueue (csOutbox cs) (eventMsg sid e)
    Duplicate -> pure ()
    InvalidSignature -> do
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

-- | Re-send every live client subscription to one newly connected relay.
-- Without this a relay added mid-session would sit silent until something
-- re-subscribed: the bridge knows every active filter, so it replays them.
-- Best-effort per filter — a relay that rejects one filter still gets the
-- rest, and the next client REQ re-sends everything anyway.
replaySubs :: BridgeState -> Text -> IO ()
replaySubs bst url = do
  clients <- readTVarIO (bsClients bst)
  forM_ (M.elems clients) $ \cs -> do
    subs <- readTVarIO (csSubs cs)
    forM_ (M.toList subs) $ \(sid, filters) ->
      void (sendTo (bsPool bst) url (CReq sid filters))

-- | Forward one event upstream, queueing it when no relay confirms. A
-- refusal is final (retrying a "no" is noise); anything else -- silence,
-- timeout, an empty pool -- waits in the outbox for the flush loop.
forward :: BridgeState -> Event -> IO ()
forward bst e = do
  let lg = bsLogger bst
  outcome <- broadcastEvent (bsPool bst) e (5 * 1000000)
  case outcome of
    Right _ -> pure ()
    Left (Rejected msg) ->
      emit lg Warn ("bridge: upstream refused " <> evId e <> ": " <> msg)
    Left failure -> do
      emit lg Info ("bridge: queued " <> evId e <> " (" <> describe failure <> ")")
      enqueueOutbox (bsStore bst) e
  where
    describe NoRelays     = "no relays connected"
    describe (Timeout msg) = msg
    describe (Rejected _) = "refused"

-- | Deliver every queued event upstream, oldest first. Confirmed events
-- leave the queue; anything still unconfirmed stays for the next pass. At
-- most 'flushBatch' per pass, so a huge backlog cannot stall the relay
-- loop that also re-offers upstreams.
flushOutbox :: BridgeState -> IO ()
flushOutbox bst = do
  queued <- dequeueOutbox (bsStore bst) flushBatch
  forM_ queued $ \e -> do
    outcome <- broadcastEvent (bsPool bst) e (5 * 1000000)
    case outcome of
      Right _ -> removeOutbox (bsStore bst) (evId e)
      Left _  -> pure ()
  n <- outboxCount (bsStore bst)
  when (n > 0) $
    emit (bsLogger bst) Info ("bridge: outbox holds " <> T.pack (show n))

flushBatch :: Int
flushBatch = 50

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
