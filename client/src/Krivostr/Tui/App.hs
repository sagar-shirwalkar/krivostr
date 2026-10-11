{-# LANGUAGE OverloadedStrings #-}

-- | The brick App: drawing plus a thin IO edge around 'step'. Every event
-- goes through 'Krivostr.Tui.State.step' first; the edge only (a) forwards
-- vty and BChan events, (b) refreshes clock-driven fields on 'EvTick', and
-- (c) turns @asQuit@ into 'halt'. Nothing here decides.
module Krivostr.Tui.App
  ( tuiApp
  , statusText
  ) where

import Brick.AttrMap (attrMap)
import Brick.Main (App (..), halt, neverShowCursor, showCursorNamed, suspendAndResume)
import Brick.Types (BrickEvent (..), CursorLocation, EventM, Widget, nestEventM')
import Brick.Widgets.Core (emptyWidget, str, txt, vBox)
import Brick.Widgets.Edit (editor, getEditContents, handleEditorEvent)
import Brick.Widgets.List (listReplace)
import Control.Concurrent (forkIO)
import Control.Exception (SomeException, try)
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (get, gets, modify)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import qualified Graphics.Vty.Attributes as Vty
import qualified Graphics.Vty.Input.Events as V
import Krivostr.Event (Event, UnsignedEvent (..), evId, evKind, evPubkey)
import Krivostr.Key (PrivateKey, derivePublicKey, pubKeyHex)
import Krivostr.Logging (LogEntry (leMsg))
import Krivostr.Nip.Nip09 (buildDeletionTags, deletionKind)
import Krivostr.Nip.Nip10 (buildReplyTags, replyRoot)
import Krivostr.Nip.Nip18 (buildQuoteTags, buildRepostTags, embedOriginal)
import Krivostr.Nip.Nip22 (ItemRef (..), buildCommentTags)
import Krivostr.Nip.Nip25 (buildReactionTags)
import Krivostr.Nip.Nip51 (addEntry, muteKind)
import Krivostr.Cli.Nostr (signUnsigned)
import Krivostr.Store (StoreStats (ssTotal))
import Krivostr.Tui.Backend (TuiBackend (..))
import Krivostr.Tui.State (findEvent, pushLogText, selectedEvent, step)
import Krivostr.Tui.Types
import Krivostr.Tui.Views.Compose (drawCompose)
import Krivostr.Tui.Views.Feed (drawFeed)
import Krivostr.Tui.Views.Lists (drawLists)
import Krivostr.Tui.Views.Search (drawSearch)
import Krivostr.Tui.Views.Thread (drawThread)
import System.Directory (getTemporaryDirectory, removeFile)
import System.Environment (lookupEnv)
import System.IO (hClose, openTempFile)
import System.Process (callProcess)

-- | The application. The backend is captured for the tick edge (outbox
-- depth is a cheap SQL count); everything else is pure.
tuiApp :: TuiBackend -> App AppState TuiEvent Name
tuiApp backend = App
  { appDraw = drawUI
  , appChooseCursor = chooseCursor
  , appHandleEvent = handleEvent backend
  , appStartEvent = pure ()
  , appAttrMap = const (attrMap Vty.defAttr [])
  }

-- | Cursor follows the compose editor; nowhere else wants one.
chooseCursor :: AppState -> [CursorLocation Name] -> Maybe (CursorLocation Name)
chooseCursor st locs = case asScreen st of
  SCompose _ -> showCursorNamed NComposeEdit locs
  _          -> neverShowCursor st locs

-- | Forward, then quit-check. Mouse and unknown events are ignored: an
-- unbound input must never do anything surprising. The tick edge refreshes
-- the clock-driven fields ('step' cannot do IO, so the edge does it around
-- the step).
-- | Forward, then quit-check. Key routing, in priority order: an open
-- command line owns every key; compose owns everything but send/promote/
-- cancel (so @q@ types instead of quitting); search-enter and thread-fetch
-- are App edges (SQLite and network); immediate sends act on the focused
-- event; the rest falls through to the pure step.
handleEvent :: TuiBackend -> BrickEvent Name TuiEvent -> EventM Name AppState ()
handleEvent backend ev = case ev of
  VtyEvent v -> do
    st <- get
    routeKey backend st v
  AppEvent EvTick -> do
    now <- liftIO getPOSIXTime
    depth <- liftIO (tbOutbox backend)
    modify (\s -> (step EvTick s) { asNow = now, asOutbox = depth })
    checkQuit
  AppEvent e -> do
    modify (step e)
    checkQuit
  _ -> pure ()
  where
    checkQuit = do
      q <- gets asQuit
      when q halt

-- | Key routing. See the module header for the order and why.
routeKey :: TuiBackend -> AppState -> V.Event -> EventM Name AppState ()
routeKey backend st v
  | isJustCmdline = forward
  | isComposeSend = sendCompose
  | isEditorPromote = promoteEditor
  | isCompose = toEditor
  | isSearchEnter = runSearch
  | isFetchRelatives = fetchRelatives
  | isImmediate = immediate
  | otherwise = forward
  where
    isJustCmdline = case asCmdLine st of Just _ -> True; Nothing -> False
    isCompose = case asScreen st of SCompose _ -> True; _ -> False
    isComposeSend = isCompose && isCtrl 'g' v
    isEditorPromote = isCompose && isEmptyEditor && v == V.EvKey (V.KChar 'E') []
    isEmptyEditor = null (getEditContents (asCompose st))
    isSearchEnter = v == V.EvKey V.KEnter [] && asCmdLine st == Nothing && asScreen st == SSearch
    isFetchRelatives = v == V.EvKey (V.KChar 'o') [] && asCmdLine st == Nothing && isThread
    isThread = case asScreen st of SThread _ -> True; _ -> False
    isImmediate = asCmdLine st == Nothing && inFeedView && isImmediateKey v
    inFeedView = asScreen st == SFeed || asScreen st == SSearch
    forward = modify (step (EvVty v)) >> checkQuit
    checkQuit = do
      q <- gets asQuit
      when q halt
    sendCompose = sendComposeWorker backend
    promoteEditor = promoteEditorWorker
    runSearch = runSearchEdge backend
    fetchRelatives = fetchRelativesWorker backend
    immediate = immediateWorker backend v
    toEditor = do
      ed <- gets asCompose
      ed' <- nestEventM' ed (handleEditorEvent (VtyEvent v))
      modify (\s -> s { asCompose = ed' })

-- | Ctrl-modified character, without other modifiers.
isCtrl :: Char -> V.Event -> Bool
isCtrl c (V.EvKey (V.KChar k) [V.MCtrl]) = c == k
isCtrl _ _                              = False

-- | Immediate sends act on the focused event of a feed-like screen.
isImmediateKey :: V.Event -> Bool
isImmediateKey (V.EvKey (V.KChar c) []) = c `elem` ("aRdmy" :: String)
isImmediateKey _                        = False

-- | Search edge: FTS answers in milliseconds, so run it synchronously and
-- swap the widget. Select-all would yank focus nowhere on empty results.
runSearchEdge :: TuiBackend -> EventM Name AppState ()
runSearchEdge backend = do
  st <- get
  results <- liftIO (tbSearch backend (asSearchQuery st) False Nothing Nothing 50)
  modify (\s -> s { asList = listReplace (Seq.fromList results) (if null results then Nothing else Just 0) (asList s) })

-- | Thread fetch edge: store plus network in a worker, typed back as
-- EvFetched. The render loop never waits on relays.
fetchRelativesWorker :: TuiBackend -> EventM Name AppState ()
fetchRelativesWorker backend = do
  st <- get
  case asScreen st of
    SThread rid -> void $ liftIO $ forkIO $ do
      found <- tbFetchThread backend rid 8000000
      tbPost backend (EvFetched found)
    _ -> pure ()

-- | Promote compose to $EDITOR: suspend brick, edit a temp file, resume with
-- its contents. Only on an empty editor — otherwise @E@ types like any other
-- key (the doc's bare @E@ would steal the letter from every post mentioning
-- one). Missing EDITOR logs instead of failing.
promoteEditorWorker :: EventM Name AppState ()
promoteEditorWorker = do
  st <- get
  suspendAndResume (editWith st)
  where
    editWith s = do
      med <- lookupEnv "EDITOR"
      case med of
        Nothing -> pure (pushLogText' s "set EDITOR to promote compose to an external editor")
        Just ed -> case words ed of
          [] -> pure (pushLogText' s "EDITOR is blank")
          (cmd : args) -> do
            tmpDir <- getTemporaryDirectory
            (path, h) <- openTempFile tmpDir "krivostr.md"
            hClose h
            writeFile path (T.unpack (T.unlines (getEditContents (asCompose s))))
            r <- try (callProcess cmd (args ++ [path])) :: IO (Either SomeException ())
            body <- readFile path
            removeFile path
            case r of
              Left ex -> pure (pushLogText' s ("editor failed: " <> T.pack (show ex)))
              Right () -> pure (s { asCompose = editor NComposeEdit Nothing (T.pack body) })
    pushLogText' = flip pushLogText

-- | Sign and publish an unsigned event: mark pending now, publish in a
-- worker, post the verdict. Shared by every send path so pending markers
-- and logging behave identically for compose and immediate sends.
runPublish :: TuiBackend -> UnsignedEvent -> PrivateKey -> IO () -> EventM Name AppState ()
runPublish backend unsigned sk onAccept = do
  now <- liftIO getPOSIXTime
  let me = pubKeyHex (derivePublicKey sk)
      ev = signUnsigned sk unsigned { uePubkey = me, ueCreatedAt = now }
  modify (\s -> s { asPending = Set.insert (evId ev) (asPending s) })
  void $ liftIO $ forkIO $ do
    r <- try (tbPublish backend ev) :: IO (Either SomeException (Either String ()))
    postVerdict backend (evId ev) (either (Left . show) id r) onAccept

-- | Post a publish verdict, running the follow-up (local delete, mute
-- record) first on success. The follow-up runs in the worker so the edge
-- stays responsive; failures post bare.
postVerdict :: TuiBackend -> Text -> Either String () -> IO () -> IO ()
postVerdict backend eid result onAccept = do
  case result of
    Right () -> onAccept
    Left _   -> pure ()
  tbPost backend (EvPublishDone eid result)

-- | Compose send (Ctrl-G): build the unsigned event for the target, sign
-- with the loaded key, publish. Read-only mode and unknown targets log and
-- keep the compose open — a failed send must never eat the draft.
sendComposeWorker :: TuiBackend -> EventM Name AppState ()
sendComposeWorker backend = do
  st <- get
  case asScreen st of
    SCompose target -> do
      let body = T.unlines (getEditContents (asCompose st))
      build <- liftIO (buildUnsigned backend st target body)
      case build of
        Left e -> modify (pushLogText (T.pack e))
        Right u -> case asKey st of
          Nothing -> modify (pushLogText "read-only mode: set KRIVOSTR_NSEC to send")
          Just sk -> runPublish backend u sk (pure ())
    _ -> pure ()

-- | Build the unsigned event for a compose target. Parent/root lookups hit
-- the store; unknown targets are Lefts, never exceptions.
buildUnsigned :: TuiBackend -> AppState -> ComposeTarget -> Text -> IO (Either String UnsignedEvent)
buildUnsigned backend st target body = case target of
  CTNote -> pure (Right (UnsignedEvent "" 0 1 [] body))
  CTReply pid -> do
    parent <- note (findEvent pid st) ("original not in store: " <> T.unpack pid)
    case parent of
      Left e -> pure (Left e)
      Right p -> do
        let rootId = fromMaybe pid (replyRoot p)
        rootAuthor <- if rootId == evId p
          then pure (evPubkey p)
          else maybe "" evPubkey <$> tbGet backend rootId
        pure (Right (UnsignedEvent "" 0 1 (buildReplyTags rootId "" rootAuthor pid "" (evPubkey p)) body))
  CTReact eid -> do
    t <- note (findEvent eid st) ("original not in store: " <> T.unpack eid)
    case t of
      Left e -> pure (Left e)
      Right x ->
        let emoji = let s = T.strip body in if T.null s then "+" else s
        in pure (Right (UnsignedEvent "" 0 7 (buildReactionTags eid "" (evPubkey x) (evKind x)) emoji))
  CTQuote eid -> do
    t <- note (findEvent eid st) ("original not in store: " <> T.unpack eid)
    case t of
      Left e -> pure (Left e)
      Right _ -> pure (Right (UnsignedEvent "" 0 1 (buildQuoteTags eid "") body))
  CTComment eid -> do
    t <- note (findEvent eid st) ("original not in store: " <> T.unpack eid)
    case t of
      Left e -> pure (Left e)
      Right x
        | evKind x == 1 -> pure (Left "that is a kind 1 note: use reply, not comment")
        | otherwise -> pure (Right (UnsignedEvent "" 0 1111
            (buildCommentTags (ItemRef (Just eid) Nothing (evKind x) (evPubkey x) "") Nothing) body))
  CTDm _ -> pure (Left "DM compose needs the DM view (M3)")
  where
    note Nothing msg  = pure (Left msg)
    note (Just x) _   = pure (Right x)

-- | Immediate sends (a/R/d/m) on the focused event. Compose-bound keys
-- (r/A/Q/c) never reach here — they open screens through the pure step.
immediateWorker :: TuiBackend -> V.Event -> EventM Name AppState ()
immediateWorker backend v = do
  st <- get
  case selectedEvent st of
    Nothing -> modify (pushLogText "nothing focused")
    Just t  -> case v of
      V.EvKey (V.KChar 'a') [] -> sendKind7 st t "+"
      V.EvKey (V.KChar 'R') [] -> sendRepost st t
      V.EvKey (V.KChar 'd') [] -> sendDelete st t
      V.EvKey (V.KChar 'm') [] -> sendMute st t
      _ -> pure ()
  where
    sendKind7 :: AppState -> Event -> Text -> EventM Name AppState ()
    sendKind7 st t emoji = case asKey st of
      Nothing -> modify (pushLogText "read-only mode: set KRIVOSTR_NSEC to send")
      Just sk -> runPublish backend
        (UnsignedEvent "" 0 7 (buildReactionTags (evId t) "" (evPubkey t) (evKind t)) emoji) sk (pure ())
    sendRepost :: AppState -> Event -> EventM Name AppState ()
    sendRepost st t = case asKey st of
      Nothing -> modify (pushLogText "read-only mode: set KRIVOSTR_NSEC to send")
      Just sk -> runPublish backend
        (UnsignedEvent "" 0 (if evKind t == 1 then 6 else 16)
          (buildRepostTags (evId t) "" (evPubkey t) (evKind t)) (embedOriginal t)) sk (pure ())
    sendDelete :: AppState -> Event -> EventM Name AppState ()
    sendDelete st t = case asKey st of
      Nothing -> modify (pushLogText "read-only mode: set KRIVOSTR_NSEC to send")
      Just sk
        | evPubkey t /= pubKeyHex (derivePublicKey sk) ->
            modify (pushLogText "not yours, refusing")
        | otherwise -> runPublish backend
            (UnsignedEvent "" 0 deletionKind (buildDeletionTags [evId t] []) "") sk
            (tbDeleteEvent backend (evId t))
    sendMute :: AppState -> Event -> EventM Name AppState ()
    sendMute st t = case asKey st of
      Nothing -> modify (pushLogText "read-only mode: set KRIVOSTR_NSEC to send")
      Just sk -> do
        let me = pubKeyHex (derivePublicKey sk)
            hex = evPubkey t
        current <- liftIO (tbMuteTags backend me)
        now <- liftIO getPOSIXTime
        let ev = signUnsigned sk (UnsignedEvent me now muteKind (addEntry "p" hex current) "")
        modify (\s -> s { asPending = Set.insert (evId ev) (asPending s) })
        void $ liftIO $ forkIO $ do
          r <- try (tbPublish backend ev) :: IO (Either SomeException (Either String ()))
          case either (Left . show) id r of
            Right () -> do
              tbPost backend (EvMuted hex)
              tbPost backend (EvPublishDone (evId ev) (Right ()))
            Left e -> tbPost backend (EvPublishDone (evId ev) (Left e))

-- | Status bar: screen, feed size, follow state, outbox depth, store total.
statusBar :: AppState -> Widget Name
statusBar st = txt (statusText st)

-- | The status line as text, so the format is pinned by tests. The store
-- total is @?@ until the first tick fills it (stats need SQL, not the model).
statusText :: AppState -> Text
statusText st = T.intercalate " · "
  [ screenName (asScreen st)
  , T.pack (show (Seq.length (asFeed st))) <> " events"
  , if asFollowing st then "following" else "paused"
  , "outbox " <> T.pack (show (asOutbox st))
  , "store " <> maybe "?" (T.pack . show . ssTotal) (asStats st)
  ]
  where
    screenName SFeed      = "feed"
    screenName (SThread _) = "thread"
    screenName SSearch     = "search"
    screenName SDm         = "dm"
    screenName SRelays     = "relays"
    screenName SLists       = "lists"
    screenName SOutbox     = "outbox"
    screenName (SCompose _) = "compose"
    screenName SHelp       = "help"

-- | The command line, or nothing when closed.
cmdLine :: AppState -> Widget Name
cmdLine st = case asCmdLine st of
  Nothing  -> emptyWidget
  Just buf -> txt (":" <> buf)

-- | Last few log entries when the pane is toggled (@~@), else nothing.
logPane :: AppState -> Widget Name
logPane st
  | not (asShowLog st) = emptyWidget
  | otherwise = vBox (map (txt . leMsg) (toList (Seq.drop (Seq.length logs - 5) logs)))
  where
    logs :: Seq LogEntry
    logs = asLog st

-- | Feed over status over log over command line. One root widget. Screens
-- other than the feed render in place of it; status, log, and command line
-- are always present.
drawUI :: AppState -> [Widget Name]
drawUI st = [vBox [mainView, statusBar st, logPane st, cmdLine st]]
  where
    mainView = case asScreen st of
      SThread _   -> drawThread (asNow st) (asPending st) (asThread st)
      SSearch     -> drawSearch (asNow st) st
      SCompose t  -> drawCompose st t (asCompose st)
      SLists      -> drawLists st
      SDm         -> str "// dm view arrives in M3 — the CLI `dm` covers sending"
      SRelays     -> str "// relays view arrives in M3 — `relay list` covers it"
      SOutbox     -> str "// outbox view arrives in M3 — depth is in the status bar"
      SHelp       -> str "// help arrives in M3 — ? is currently unbound"
      SFeed       -> drawFeed (asNow st) st
