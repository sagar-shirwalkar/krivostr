{-# LANGUAGE OverloadedStrings #-}

-- | @krivostr tui@: the interactive shell. Wires the store, the pool, the
-- log drain, and the tick into a 'BChan' and runs the brick app from
-- 'Krivostr.Tui.App' over the in-process 'TuiBackend'.
--
-- Terminal ownership: the TUI must own stdout/stderr while brick runs, so
-- the caller passes a plain queue logger ('newLogger') — never the stderr
-- printer ('withStderrLog'), which would shred the screen. Log entries
-- drain into the log pane instead.
module Krivostr.Tui
  ( TuiOpts (..)
  , runTui
  ) where

import Brick.BChan (BChan, newBChan, writeBChan, writeBChanNonBlocking)
import Brick.Main (customMain)
import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (finally)
import Control.Monad (forM_, forever, unless, void)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Graphics.Vty.Config (defaultConfig)
import Graphics.Vty.CrossPlatform (mkVty)
import Krivostr.Cli.Nostr (loadKey)
import Krivostr.Cli.Options (buildFilter, emptyFilterOpts, FilterOpts (foKinds), resolveUpstreams)
import Krivostr.Event (Event)
import Krivostr.Filter (Filter (..))
import Krivostr.Key (PrivateKey, derivePublicKey, pubKeyHex)
import Krivostr.Logging (LogLevel (Warn), Logger, drainQueue, emit)
import Krivostr.Nip.Nip51 (bookmarkKind, bookmarkedIds, muteKind, mutedPubkeys, pinKind, pinnedIds)
import Krivostr.Pool (addRelay, broadcast, newPool, poolRelays, removeRelay)
import Krivostr.Store
  (Store, closeStore, getRelayConfig, openStore, outboxCount, queryEvents, storeStats)
import Krivostr.Tui.App (tuiApp)
import Krivostr.Tui.Backend (inProcessBackend)
import Krivostr.Tui.State (pushEvent)
import Krivostr.Tui.Types (AppState (..), TuiEvent (..), initialState)
import Krivostr.Tui.Types (AppState (..), TuiEvent (..), initialState)
import Krivostr.Wire (ClientMessage (..))
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | Default kinds for the TUI live feed. Matches the web UI's FEED_KINDS
-- to exclude firehose-dominating kinds (0, 3, 4, 1059, 10002, etc.) and
-- encrypted content that renders as ciphertext.
tuiDefaultKinds :: [Int]
tuiDefaultKinds = [1, 5, 6, 7, 16, 1111, 9735, 30023]

-- | TUI options from argv. @--no-ingest@ starts paused (read the archive,
-- touch no relays); ingest is on by default — that is the local-first pitch.
data TuiOpts = TuiOpts
  { toRelays   :: [Text]
  , toNoIngest :: Bool
  } deriving (Show, Eq)

-- | Run the interactive shell. Opens the store and pool, fills the initial
-- model from SQLite, subscribes the follow filter when ingesting, and hands
-- the terminal to brick until @q@. Quitting disconnects the relays and
-- closes the store.
runTui :: TuiOpts -> Logger -> FilePath -> IO ()
runTui opts lg db = do
  keyE <- loadKey
  key <- case keyE of
    Left e  -> hPutStrLn stderr ("cannot start tui: " ++ e) >> exitFailure
    Right k -> pure k
  filt <- buildFilter emptyFilterOpts { foKinds = tuiDefaultKinds }
  st <- openStore lg db
  flip finally (closeStore st) $ do
    saved <- getRelayConfig st
    let relays = resolveUpstreams (toRelays opts) saved
    chan <- newBChan 1000
    pool <- newPool lg (postEvent lg chan)
    mapM_ (addRelay pool) relays
    let backend = inProcessBackend lg db st pool relays (writeBChan chan)
    initial <- fillInitial st filt key
    unless (toNoIngest opts) $
      broadcast pool (CReq "tui-feed" [filt])
    void $ forkIO $ forever $ do
      threadDelay 1000000
      void (writeBChanNonBlocking chan EvTick)
    void $ forkIO $ forever $ do
      entries <- drainQueue lg
      forM_ entries (writeBChan chan . EvLog)
      threadDelay 100000
    vty <- mkVty defaultConfig
    void (customMain vty (mkVty defaultConfig) (Just chan) (tuiApp backend) initial)
    current <- poolRelays pool
    forM_ current (\u -> removeRelay pool u >> pure ())
  where
    -- The pool handler must never block a relay drain thread: the BChan is
    -- bounded (1000), so a firehose overflows into a log line instead of
    -- wedging the relay. The drain thread posts the line to the log pane.
    postEvent :: Logger -> BChan TuiEvent -> Event -> IO ()
    postEvent logger chan e = do
      ok <- writeBChanNonBlocking chan (EvIncoming e)
      unless ok (emit logger Warn "event feed overflow, dropping")

-- | Fill the model from SQLite before the first draw: stored events through
-- the same dedupe-and-cap path as live ones, plus store stats and outbox
-- depth. Lists come from my newest list events when a key is loaded;
-- read-only mode shows empty tabs (nothing muted yet that we know of).
fillInitial :: Store -> Filter -> Maybe PrivateKey -> IO AppState
fillInitial st filt key = do
  now <- getPOSIXTime
  evs <- queryEvents st filt
  stats <- storeStats st
  depth <- outboxCount st
  (mutes, pins, bookmarks) <- case key of
    Nothing -> pure (Set.empty, Set.empty, Set.empty)
    Just sk -> do
      let me = pubKeyHex (derivePublicKey sk)
      mutes' <- Set.fromList . concatMap mutedPubkeys <$> listsOf st me muteKind
      pins' <- Set.fromList . concatMap pinnedIds <$> listsOf st me pinKind
      bookmarks' <- Set.fromList . concatMap bookmarkedIds <$> listsOf st me bookmarkKind
      pure (mutes', pins', bookmarks')
  let s0 = (initialState now filt key)
        { asStats = Just stats
        , asOutbox = depth
        , asMuted = mutes
        , asPins = pins
        , asBookmarks = bookmarks
        }
  pure (foldr pushEvent s0 evs)
  where
    listsOf s me kind = queryEvents s (byKindAuthor kind me)
    byKindAuthor kind me = Filter
      { fIds = Nothing, fAuthors = Just [me], fKinds = Just [kind]
      , fSince = Nothing, fUntil = Nothing, fLimit = Just 1
      , fTags = [], fSearch = Nothing }
