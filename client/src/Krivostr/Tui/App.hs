{-# LANGUAGE OverloadedStrings #-}

-- | The brick App: drawing plus a thin IO edge around 'step'. Every event
-- goes through 'Krivostr.Tui.State.step' first; the edge only (a) forwards
-- vty and BChan events, (b) refreshes clock-driven fields on 'EvTick', and
-- (c) turns @asQuit@ into 'halt'. Nothing here decides.
module Krivostr.Tui.App
  ( tuiApp
  , statusText
  , buildUnsigned
  , lookupEvent
  ) where

import Brick.Main (App (..), halt, neverShowCursor, showCursorNamed, suspendAndResume)
import Brick.Types (BrickEvent (..), CursorLocation, EventM, Widget, nestEventM')
import Brick.Widgets.Core (emptyWidget, str, txt, vBox)
import Brick.Widgets.Edit (editor, getEditContents, handleEditorEvent)
import Brick.Widgets.List (listReplace, listSelectedElement)
import Control.Concurrent (forkIO)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (get, gets, modify)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe, maybeToList)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import qualified Graphics.Vty.Input.Events as V
import Krivostr.Event (Event, UnsignedEvent (..), evId, evKind, evPubkey, evContent)
import Krivostr.Key (PrivateKey, derivePublicKey, pubKeyHex)
import Krivostr.Logging (LogEntry (leMsg))
import Krivostr.Nip.Nip09 (buildDeletionTags, deletionKind, parameterizedAddress)
import Krivostr.Nip.Nip10 (buildReplyTags, replyRoot)
import Krivostr.Nip.Nip18 (buildQuoteTags, buildRepostTags, embedOriginal)
import Krivostr.Nip.Nip22 (ItemRef (..), buildCommentTags)
import Krivostr.Tui.Theme (themeAttrMap)
import Krivostr.Nip.Nip25 (buildReactionTags)
import Krivostr.Nip.Nip27 (findMentions)
import qualified Krivostr.Nip.Nip27 as Nip27
import Krivostr.Nip.Nip51 (addEntry, muteKind)
import Krivostr.Cli.Nostr (signUnsigned)
import Krivostr.Store (StoreStats (ssTotal))
import Krivostr.Tui.Backend (TuiBackend (..))
import Krivostr.Tui.Dispatch (commandHelp)
import Krivostr.Tui.Sanitize (stripAnsiAndC0)
import Krivostr.Tui.State (findEvent, popScreen, pushLogText, selectedEvent, step)
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
  , appAttrMap = const themeAttrMap
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
  | isComposeCancel = forward
  | isEditorPromote = promoteEditor
  | isResolveMentions = resolveMentions >> forward
  | isSearchOpenResult = openSearchResult
  | isSearchRun = runSearch
  | isCompose = toEditor
  | isFetchRelatives = fetchRelatives
  | isImmediate = immediate
  | otherwise = forward
  where
    isJustCmdline = case asCmdLine st of Just _ -> True; Nothing -> False
    isCompose = case asScreen st of SCompose _ -> True; _ -> False
    isComposeSend = isCompose && isCtrl 'g' v
    isComposeCancel = isCompose && v == V.EvKey V.KEsc []
    isEditorPromote = isCompose && isEmptyEditor && v == V.EvKey (V.KChar 'E') []
    isEmptyEditor = null (getEditContents (asCompose st))
    isSearchRun = v == V.EvKey V.KEnter [] && asCmdLine st == Nothing && asScreen st == SSearch && not (hasSelection st)
    isSearchOpenResult = v == V.EvKey V.KEnter [] && asCmdLine st == Nothing && asScreen st == SSearch && hasSelection st
    isFetchRelatives = v == V.EvKey (V.KChar 'o') [] && asCmdLine st == Nothing && isThread
    isResolveMentions = v == V.EvKey (V.KChar 'n') [] && asCmdLine st == Nothing && isThread
    isThread = case asScreen st of SThread _ -> True; _ -> False
    isImmediate = asCmdLine st == Nothing && inFeedView && isImmediateKey v
    inFeedView = asScreen st == SFeed || asScreen st == SSearch
    forward = modify (step (EvVty v)) >> checkQuit
    checkQuit = do
      q <- gets asQuit
      when q halt
    hasSelection s = case listSelectedElement (asList s) of
      Just _ -> True
      Nothing -> False
    sendCompose = sendComposeWorker backend
    promoteEditor = promoteEditorWorker
    runSearch = runSearchEdge backend
    openSearchResult = openSearchResultWorker backend
    fetchRelatives = fetchRelativesWorker backend
    resolveMentions = resolveMentionsWorker backend
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
isImmediateKey (V.EvKey (V.KChar c) []) = c `elem` ("aRdm" :: String)
isImmediateKey _                        = False

-- | Search edge: FTS answers in milliseconds, so run it synchronously and
-- swap the widget. Select-all would yank focus nowhere on empty results.
runSearchEdge :: TuiBackend -> EventM Name AppState ()
runSearchEdge backend = do
  st <- get
  results <- liftIO (tbSearch backend (asSearchQuery st) False Nothing Nothing 50)
  modify (\s -> s { asList = listReplace (Seq.fromList results) (if null results then Nothing else Just 0) (asList s) })

-- | Open the thread for the currently selected search result.
openSearchResultWorker :: TuiBackend -> EventM Name AppState ()
openSearchResultWorker backend = do
  st <- get
  case selectedEvent st of
    Nothing -> pure ()
    Just e -> do
      modify (\s -> s { asScreen = SThread (evId e), asThread = e : [] })
      fetchRelativesWorker backend

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

-- | Mention resolution: extract mentions from the focused thread event,
-- fetch each referenced event from the store/relays, and post EvResolvedMention
-- for each resolved event so the pure step can open the appropriate view.
resolveMentionsWorker :: TuiBackend -> EventM Name AppState ()
resolveMentionsWorker backend = do
  st <- get
  case (asScreen st, selectedEvent st) of
    (SThread _, Just e) -> void $ liftIO $ forkIO $ do
      let mentions = findMentions (evContent e)
      forM_ mentions $ \m -> case Nip27.meKind m of
        Nip27.MentionEvent eid -> do
          -- Fetch the full thread for this event
          threadEvts <- tbFetchThread backend eid 8000000
          -- Post the thread events so mergeFetched populates asThread
          tbPost backend (EvFetched threadEvts)
          -- Then trigger the screen switch
          tbPost backend (EvResolvedMention (RTEvent eid))
        Nip27.MentionPubkey pk -> tbPost backend (EvResolvedMention (RTAuthor pk))
        Nip27.MentionProfile pk _ -> tbPost backend (EvResolvedMention (RTAuthor pk))
        Nip27.MentionAddress addr -> tbPost backend (EvResolvedMention (RTAddress addr))
        _ -> pure ()
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
-- Optional onSuccess runs in the worker after a successful publish.
runPublish :: TuiBackend -> UnsignedEvent -> PrivateKey -> IO () -> EventM Name AppState ()
runPublish backend unsigned sk onSuccess = do
  now <- liftIO getPOSIXTime
  let me = pubKeyHex (derivePublicKey sk)
      ev = signUnsigned sk unsigned { uePubkey = me, ueCreatedAt = now }
  modify (\s -> s { asPending = Set.insert (evId ev) (asPending s) })
  void $ liftIO $ forkIO $ do
    r <- try (tbPublish backend ev) :: IO (Either SomeException (Either String ()))
    tbPost backend (EvPublishDone (evId ev) (either (Left . show) id r))
    case either (Left . show) id r of
      Right () -> onSuccess
      Left _ -> pure ()

-- | Look up an event by id: first in the model (feed + thread), then in the store.
lookupEvent :: TuiBackend -> AppState -> Text -> IO (Either String Event)
lookupEvent backend st eid =
  case findEvent eid st of
    Just e  -> pure (Right e)
    Nothing -> maybe (Left ("original not in store: " <> T.unpack eid)) Right <$> tbGet backend eid

-- | Compose send (Ctrl-G): build the unsigned event for the target, sign
-- with the loaded key, publish. Read-only mode and unknown targets log and
-- keep the compose open — a failed send must never eat the draft.
-- On successful send, pop back to the previous screen and reset the editor
-- so a second Ctrl-G doesn't double-publish the same draft.
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
          Just sk -> runPublish backend u sk
            (tbPost backend EvComposeSent)
    _ -> pure ()

-- | Build the unsigned event for a compose target. Parent/root lookups hit
-- the model first, then the store; unknown targets are Lefts, never exceptions.
buildUnsigned :: TuiBackend -> AppState -> ComposeTarget -> Text -> IO (Either String UnsignedEvent)
buildUnsigned backend st target body = case target of
  CTNote -> pure (Right (UnsignedEvent "" 0 1 [] body))
  CTReply pid -> do
    parent <- liftIO (lookupEvent backend st pid)
    case parent of
      Left e -> pure (Left e)
      Right p -> do
        let rootId = fromMaybe pid (replyRoot p)
        rootAuthor <- if rootId == evId p
          then pure (evPubkey p)
          else maybe "" evPubkey <$> tbGet backend rootId
        pure (Right (UnsignedEvent "" 0 1 (buildReplyTags rootId "" rootAuthor pid "" (evPubkey p)) body))
  CTReact eid -> do
    t <- liftIO (lookupEvent backend st eid)
    case t of
      Left e -> pure (Left e)
      Right x ->
        let emoji = let s = T.strip body in if T.null s then "+" else s
        in pure (Right (UnsignedEvent "" 0 7 (buildReactionTags eid "" (evPubkey x) (evKind x)) emoji))
  CTQuote eid -> do
    t <- liftIO (lookupEvent backend st eid)
    case t of
      Left e -> pure (Left e)
      Right _ -> pure (Right (UnsignedEvent "" 0 1 (buildQuoteTags eid "") body))
  CTComment eid -> do
    t <- liftIO (lookupEvent backend st eid)
    case t of
      Left e -> pure (Left e)
      Right x
        | evKind x == 1 -> pure (Left "that is a kind 1 note: use reply, not comment")
        | otherwise -> do
            let addr = parameterizedAddress x
            pure (Right (UnsignedEvent "" 0 1111
                (buildCommentTags (ItemRef (Just eid) addr (evKind x) (evPubkey x) "") Nothing) body))
  CTDm _ -> pure (Left "DM compose needs the DM view (M3)")

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
        (UnsignedEvent "" 0 7 (buildReactionTags (evId t) "" (evPubkey t) (evKind t)) emoji) sk
        (pure ())
    sendRepost :: AppState -> Event -> EventM Name AppState ()
    sendRepost st t = case asKey st of
      Nothing -> modify (pushLogText "read-only mode: set KRIVOSTR_NSEC to send")
      Just sk -> runPublish backend
        (UnsignedEvent "" 0 (if evKind t == 1 then 6 else 16)
          (buildRepostTags (evId t) "" (evPubkey t) (evKind t)) (embedOriginal t)) sk
        (pure ())
    sendDelete :: AppState -> Event -> EventM Name AppState ()
    sendDelete st t = case asKey st of
      Nothing -> modify (pushLogText "read-only mode: set KRIVOSTR_NSEC to send")
      Just sk
        | evPubkey t /= pubKeyHex (derivePublicKey sk) ->
            modify (pushLogText "not yours, refusing")
        | otherwise -> do
            let addrs = maybeToList (parameterizedAddress t)
            runPublish backend
              (UnsignedEvent "" 0 deletionKind (buildDeletionTags [evId t] addrs) "") sk
              (liftIO (tbDeleteEvent backend (evId t)))
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
  [ screenName (asScreen st) <> unreadSuffix
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
    unreadSuffix
      | asUnread st > 0 = " (" <> T.pack (show (asUnread st)) <> " new)"
      | otherwise = ""

-- | The command line, or nothing when closed.
cmdLine :: AppState -> Widget Name
cmdLine st = case asCmdLine st of
  Nothing  -> emptyWidget
  Just buf -> txt (":" <> buf)

-- | Last few log entries when the pane is toggled (@~@), else nothing.
logPane :: AppState -> Widget Name
logPane st
  | not (asShowLog st) = emptyWidget
  | otherwise = vBox (map (txt . stripAnsiAndC0 . leMsg) (toList (Seq.drop (Seq.length logs - 5) logs)))
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
      SThread _   -> drawThread (asNow st) (asPending st) (asRevealed st) (asThread st)
      SSearch     -> drawSearch (asNow st) st
      SCompose t  -> drawCompose st t (asCompose st)
      SLists      -> drawLists st
      SDm         -> str "// dm view arrives in M3 — the CLI `dm` covers sending"
      SRelays     -> str "// relays view arrives in M3 — `relay list` covers it"
      SOutbox     -> str "// outbox view arrives in M3 — depth is in the status bar"
      SHelp       -> drawHelp
      SFeed       -> drawFeed (asNow st) st

drawHelp :: Widget Name
drawHelp = vBox
  ( [ str "Global keys:"
    , str "  ?        Help (this screen)"
    , str "  q        Quit"
    , str "  :        Command bar"
    , str "  /        Search"
    , str "  ~        Toggle log pane"
    , str "  Tab      Cycle screens (Feed→Relays→Lists→DM→Outbox→Help)"
    , str "  Esc      Cancel overlay"
    , str ""
    , str "Feed keys:"
    , str "  j/k      Move down/up"
    , str "  g/G      Jump top/bottom"
    , str "  Enter    Open thread"
    , str "  r        Reply compose"
    , str "  A        React compose (+)"
    , str "  Q        Quote compose"
    , str "  c        Comment compose"
    , str "  v        Reveal sensitive (NIP-36)"
    , str "  y        Yank event id"
    , str "  a        Immediate like"
    , str "  R        Immediate repost"
    , str "  d        Immediate delete (own)"
    , str "  m        Immediate mute author"
    , str "  f        Toggle follow"
    , str ""
    , str "Commands (prefix with :):"
    ] <>
    map (\(cmd, desc) -> txt ("  " <> cmd <> "  " <> desc)) commandHelp
  )
