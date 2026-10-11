{-# LANGUAGE OverloadedStrings #-}

-- | The backend seam: everything views need from the world, as a record of
-- IO actions. The first cut runs in-process over the 'Store' + 'Pool' that
-- 'runTui' opens (exactly like @cmdFeed --follow --ingest@ composes them);
-- a future @bridgeBackend@ speaking @\/ws@ + @\/relays@ fills the same
-- record and no view changes. This mirrors the web UI's 'RelayHandle'
-- substitution trick.
module Krivostr.Tui.Backend
  ( TuiBackend (..)
  , inProcessBackend
  , flushBatch
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TQueue (isEmptyTQueue, newTQueueIO, readTQueue, writeTQueue)
import Control.Monad (forM_)
import Data.Either (partitionEithers)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Krivostr.Cli.Nostr (publishNoteResults)
import Krivostr.Event (Event, evCreatedAt, evId, evTags)
import Krivostr.Filter (Filter (..), matches, tagEq)
import Krivostr.Logging (Logger)
import Krivostr.Pool (Pool, addRelay, broadcast, broadcastEvent, newPool, poolRelays, removeRelay)
import Krivostr.Nip.Nip51 (muteKind)
import Krivostr.Tui.Types (TuiEvent)
import Krivostr.Wire (ClientMessage (..))
import Krivostr.Store
  ( Store
  , countMatching
  , deleteEvent
  , dequeueOutbox
  , getEventById
  , outboxCount
  , queryEvents
  , removeOutbox
  , searchEvents
  )

-- | Store queries + event stream + publish. Queries hit the shared handle;
-- publishing resolves relays and stores on accept through the same core the
-- one-shot CLI uses ('publishNoteResults'), so both shells agree on what a
-- send means.
data TuiBackend = TuiBackend
  { tbQuery    :: Filter -> IO [Event]
  , tbSearch   :: Text -> Bool -> Maybe [Int] -> Maybe Text -> Int -> IO [Event]
  , tbGet      :: Text -> IO (Maybe Event)
  , tbPublish  :: Event -> IO (Either String ())
  , tbRelays   :: IO [Text]
  , tbAddRelay :: Text -> IO ()
  , tbDelRelay :: Text -> IO ()
  , tbOutbox   :: IO Int
  , tbFlush    :: IO ()
  , tbCount    :: Filter -> IO Int
  , tbPost     :: TuiEvent -> IO ()
  , tbFetchOnce :: Filter -> Int -> IO [Event]
  , tbFetchThread :: Text -> Int -> IO [Event]
  , tbDeleteEvent :: Text -> IO ()
  , tbMuteTags :: Text -> IO [[Text]]
  }

-- | At most one flush pass moves this many events, so a huge backlog cannot
-- stall the tick that also refreshes stats. Same bound as the bridge.
flushBatch :: Int
flushBatch = 50

-- | Backend over an opened store and pool. The log and db path feed
-- publishing; everything else closes over the handles. The poster and the
-- fetch relays wire async completions back into the event loop.
inProcessBackend :: Logger -> FilePath -> Store -> Pool -> [Text] -> (TuiEvent -> IO ()) -> TuiBackend
inProcessBackend lg db st pool relays post = TuiBackend
  { tbQuery    = queryEvents st
  , tbSearch   = searchEvents st
  , tbGet      = getEventById st
  , tbPublish  = publishVia lg db
  , tbRelays   = poolRelays pool
  , tbAddRelay = addRelay pool
  , tbDelRelay = \url -> removeRelay pool url >> pure ()
  , tbOutbox   = outboxCount st
  , tbFlush    = flushVia pool st
  , tbCount    = countMatching st
  , tbPost     = post
  , tbFetchOnce = fetchOnceVia lg relays
  , tbFetchThread = fetchThreadVia st lg relays
  , tbDeleteEvent = deleteEvent st
  , tbMuteTags = muteTagsVia st
  }

-- | Publish through the shared core, collapsing per-relay verdicts the way
-- the status bar needs them: silence on any accept, the first refusal
-- otherwise. Runs in a worker thread; 'runTui' posts the result as
-- 'EvPublishDone'.
publishVia :: Logger -> FilePath -> Event -> IO (Either String ())
publishVia lg db ev = do
  results <- publishNoteResults lg db 15 ev [] "tui"
  pure $ case partitionEithers (map snd results) of
    (_, _ : _) -> Right ()
    (e : _, []) -> Left e
    ([], [])   -> Left "no relays configured"

-- | Deliver every queued event upstream, oldest first. Confirmed events
-- leave the queue; anything still unconfirmed stays for the next pass.
flushVia :: Pool -> Store -> IO ()
flushVia pool st = do
  queued <- dequeueOutbox st flushBatch
  forM_ queued $ \e -> do
    outcome <- broadcastEvent pool e (5 * 1000000)
    case outcome of
      Right _ -> removeOutbox st (evId e)
      Left _  -> pure ()

-- | Thread from the store plus one network pass: the root by id and its
-- replies by @e@ tag, oldest first (a thread reads down). Store answers
-- instantly; the two relay fetches run concurrently in the caller's worker
-- thread (the UI stays live throughout). Deduplicated by id throughout.
fetchThreadVia :: Store -> Logger -> [Text] -> Text -> Int -> IO [Event]
fetchThreadVia st lg relays rid wait = do
  local <- fetchThreadStore st rid
  (byId, byTag) <- concurrently
    (fetchOnceVia lg relays (byIds rid) wait)
    (fetchOnceVia lg relays (tagEq "e" [rid]) wait)
  pure (sortOn evCreatedAt (dedupe (local <> byId <> byTag)))
  where
    byIds r = Filter
      { fIds = Just [r], fAuthors = Nothing, fKinds = Nothing
      , fSince = Nothing, fUntil = Nothing, fLimit = Just 50
      , fTags = [], fSearch = Nothing }
    dedupe = foldr (\e acc -> if any ((== evId e) . evId) acc then acc else e : acc) []

-- | Thread from the store only: the root by id plus its replies by @e@ tag,
-- oldest first (a thread reads down). The fast path inside 'fetchThreadVia'
-- and the seam-testable half of it.
fetchThreadStore :: Store -> Text -> IO [Event]
fetchThreadStore st rid = do
  root <- getEventById st rid
  replies <- queryEvents st (tagEq "e" [rid])
  pure (sortOn evCreatedAt (maybe id (:) root replies))

-- | One-shot fetch from relays: a throwaway pool on the fetch relays, one
-- REQ, collect matches until the window ends. Slice-collected (250ms) with
-- early exit once matches arrive plus a grace second — the UI stays live
-- throughout because the caller runs this in a worker thread.
fetchOnceVia :: Logger -> [Text] -> Filter -> Int -> IO [Event]
fetchOnceVia lg relays filt waitMicros = do
  q <- newTQueueIO
  pool <- newPool lg (atomically . writeTQueue q)
  mapM_ (addRelay pool) relays
  broadcast pool (CReq "tui-once" [filt])
  start <- getCurrentTime
  let window = fromIntegral waitMicros / 1000000 :: Double
      grace = 1.0 :: Double
      loop acc = do
        now <- getCurrentTime
        let elapsed = realToFrac (diffUTCTime now start) :: Double
        rest <- atomically (drainQueue q)
        let acc' = dedupe (acc <> filter (matches filt) rest)
        if elapsed >= window || (not (null acc') && elapsed >= grace)
          then pure acc'
          else threadDelay 250000 >> loop acc'
  found <- loop []
  current <- poolRelays pool
  forM_ current (\u -> removeRelay pool u >> pure ())
  pure found
  where
    drainQueue qq = do
      empty <- isEmptyTQueue qq
      if empty then pure [] else (:) <$> readTQueue qq <*> drainQueue qq
    dedupe = foldr (\e acc -> if any ((== evId e) . evId) acc then acc else e : acc) []

-- | Current mute tags for a pubkey: newest own kind-10000's tags, or empty
-- when they never muted. The read half of read-modify-publish; signing and
-- publishing stay with the caller.
muteTagsVia :: Store -> Text -> IO [[Text]]
muteTagsVia st me = do
  evs <- queryEvents st (Filter Nothing (Just [me]) (Just [muteKind]) Nothing Nothing (Just 1) [] Nothing)
  pure (maybe [] evTags (listToMaybe evs))
  where
    listToMaybe []      = Nothing
    listToMaybe (x : _) = Just x
