{-# LANGUAGE OverloadedStrings #-}

-- | The pure TUI transition: 'TuiEvent' in, 'AppState' out, no IO anywhere.
-- This module is the hspec target — see @client/test/TuiSpec.hs@. Key handling
-- lives here too (including the quit request as 'asQuit'), so every key is
-- tested without a terminal; 'Krivostr.Tui.App' only forwards events and
-- turns @asQuit@ into 'halt'.
module Krivostr.Tui.State
  ( step
  , stepKey
  , pushEvent
  , pushLog
  , pushLogText
  , applyCommand
  , selectedEvent
  , findEvent
  , mergeFetched
  , clearPending
  , stepCmdKey
  , stepSearchKey
  , stepNavKey
  , popScreen
  , composeFor
  , commentFor
  , revealSelected
  , yankSelected
  , stepEnter
  ) where

import Brick.Widgets.Edit (editor)
import Brick.Widgets.List
  (listMoveDown, listMoveToBeginning, listMoveToEnd, listMoveUp, listReplace, listSelectedElement)
import Data.Foldable (toList)
import Data.Sequence ((<|), (|>))
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text (Text)
import qualified Graphics.Vty.Input.Events as V
import Krivostr.Event (Event, evId, evKind, evTags)
import Krivostr.Logging (LogEntry (..), LogLevel (..))
import Krivostr.Tui.Dispatch (Command (..), parseCommand)
import Krivostr.Tui.Types
import Krivostr.Tui.Views.Thread (threadReplies)

-- | Total transition. Every constructor is handled; unknown input degrades
-- to a log line, never a crash.
step :: TuiEvent -> AppState -> AppState
step ev st = case ev of
  EvIncoming e     -> pushEvent e st
  EvPublishDone eid r -> pushLog (publishEntry eid r) (clearPending eid st)
  EvAsyncResult k r   -> pushLog (asyncEntry k r) st
  EvMuted hex      -> (pushLogText ("muted " <> hex) st)
    { asMuted = Set.insert hex (asMuted st) }
  EvFetched evs    -> mergeFetched evs st
  EvTick          -> st
  EvLog entry     -> pushLog entry st
  EvVty v         -> stepKey v st

-- | A publish settled: drop its pending marker. The log line is written by
-- the caller ('pushLog' above); this only clears the marker.
clearPending :: Text -> AppState -> AppState
clearPending eid st = st { asPending = Set.delete eid (asPending st) }

-- | The focused event, if the widget has a selection at all.
selectedEvent :: AppState -> Maybe Event
selectedEvent st = snd <$> listSelectedElement (asList st)

-- | Find an event by id in the feed, then the open thread. Pure model
-- lookup; the store and relays are the worker's job.
findEvent :: Text -> AppState -> Maybe Event
findEvent eid st =
  case filter ((== eid) . evId) (toList (asFeed st) <> asThread st) of
    (e : _) -> Just e
    []      -> Nothing

-- | Merge fetched events into the feed and, when a thread is open, into it
-- too (deduplicated by id on both sides).
mergeFetched :: [Event] -> AppState -> AppState
mergeFetched evs st =
  let fed = foldr pushEvent st evs
  in case asScreen st of
    SThread rid -> fed { asThread = dedupe (asThread fed <> filter (cites rid) evs) }
    _           -> fed
  where
    cites r e = any isReply (evTags e)
      where
        isReply (t : rest) = t == "e" && r `elem` rest
        isReply []         = False
    dedupe = foldr (\e acc -> if any ((== evId e) . evId) acc then acc else e : acc) []

-- | Prepend an event to the feed unless its id is already there; cap at
-- 'feedCap' newest. Newest-first is the invariant the views render, so the
-- prepend goes left and the cap drops the right ('Seq.take' keeps the left).
-- The widget follows the model (selection preserved by 'listReplace').
pushEvent :: Event -> AppState -> AppState
pushEvent e st
  | any ((== evId e) . evId) (toList (asFeed st)) = st
  | otherwise =
      let feed = Seq.take feedCap (e <| asFeed st)
          sel = fst <$> listSelectedElement (asList st)
      in st { asFeed = feed, asList = listReplace feed sel (asList st) }

-- | Append a log entry, keeping the newest 'logCap'. The pane is a
-- diagnostic tail: old entries leave from the left.
pushLog :: LogEntry -> AppState -> AppState
pushLog e st = st { asLog = Seq.drop (max 0 (Seq.length appended - logCap)) appended }
  where
    appended = asLog st |> e

-- | Short entries for worker completions. Failures are warnings: the status
-- bar shows the latest, the log pane keeps the history.
publishEntry :: Text -> Either String () -> LogEntry
publishEntry eid (Right ()) = LogEntry Info ("published " <> eid)
publishEntry eid (Left err) = LogEntry Warn ("publish failed " <> eid <> ": " <> T.pack err)

-- | Short entries for async completions, keyed by the requesting command.
asyncEntry :: Text -> Either String Text -> LogEntry
asyncEntry k (Right t) = LogEntry Info (k <> ": " <> t)
asyncEntry k (Left e)  = LogEntry Warn (k <> " failed: " <> T.pack e)

-- | Log plain text at Info level.
pushLogText :: Text -> AppState -> AppState
pushLogText t = pushLog (LogEntry Info t)

-- | Leave command-line mode.
closeCmd :: AppState -> AppState
closeCmd st = st { asCmdLine = Nothing }

-- | Route a parsed ':' command. Unknown input is a log line, not an error.
applyCommand :: Command -> AppState -> AppState
applyCommand cmd st = case cmd of
  CmdQuit        -> st { asQuit = True, asCmdLine = Nothing }
  CmdUnknown raw -> closeCmd (pushLogText ("unknown command: " <> raw) st)

-- | Key handling. Three layers, checked in order: an open command line
-- owns every key; the search screen owns printable input; otherwise the
-- navigation layer. M0 covered @q@/@:/@~/@Esc@/@Enter@/@Backspace@; M1 adds
-- @j/k/g/G@ movement, @Enter@ to thread, @/@ to search, and @Esc@ to pop
-- back to the feed. Anything else is ignored — unbound keys must never do
-- anything surprising.
stepKey :: V.Event -> AppState -> AppState
stepKey v st = case asCmdLine st of
  Just buf -> stepCmdKey v buf st
  Nothing
    | asScreen st == SSearch -> stepSearchKey v st
    | otherwise -> stepNavKey v st

-- | Command-line editing. @Enter@ dispatches (see 'applyCommand'), @Esc@
-- cancels, @Backspace@ deletes; a leading colon would nest command lines.
stepCmdKey :: V.Event -> Text -> AppState -> AppState
stepCmdKey v buf st = case v of
  V.EvKey V.KEsc []   -> st { asCmdLine = Nothing }
  V.EvKey V.KEnter [] -> applyCommand (parseCommand buf) st
  V.EvKey V.KBS []    -> st { asCmdLine = Just (T.dropEnd 1 buf) }
  V.EvKey (V.KChar c) []
    -- A leading colon would nest command lines; colons elsewhere are
    -- ordinary input (nostr: references, relay URLs).
    | c == ':' && T.null buf -> st
    | otherwise -> st { asCmdLine = Just (buf <> T.singleton c) }
  _ -> st

-- | Search-screen input. @Enter@ is deliberately a no-op here: running the
-- search hits SQLite, so the App edge runs it and swaps the widget. Pure
-- step tests cover everything up to that edge.
stepSearchKey :: V.Event -> AppState -> AppState
stepSearchKey v st = case v of
  V.EvKey V.KEsc []   -> popScreen st
  V.EvKey V.KEnter [] -> st
  V.EvKey V.KBS []    -> st { asSearchQuery = T.dropEnd 1 (asSearchQuery st) }
  V.EvKey (V.KChar c) [] -> st { asSearchQuery = asSearchQuery st <> T.singleton c }
  _ -> st

-- | Navigation and screen moves on feed-like screens. Movement keys only
-- act where the feed widget is visible (feed, search results); everywhere
-- else they are ignored rather than moving a hidden widget.
stepNavKey :: V.Event -> AppState -> AppState
stepNavKey v st = case v of
  V.EvKey (V.KChar 'q') [] -> st { asQuit = True }
  V.EvKey (V.KChar ':') [] -> st { asCmdLine = Just "" }
  V.EvKey (V.KChar '~') [] -> st { asShowLog = not (asShowLog st) }
  V.EvKey (V.KChar '/') [] -> st { asScreen = SSearch, asSearchQuery = "" }
  V.EvKey V.KEsc []        -> if asScreen st == SFeed then st else popScreen st
  V.EvKey V.KEnter []      -> stepEnter st
  V.EvKey (V.KChar 'j') [] -> moveWhenVisible listMoveDown st
  V.EvKey (V.KChar 'k') [] -> moveWhenVisible listMoveUp st
  V.EvKey (V.KChar 'g') [] -> moveWhenVisible listMoveToBeginning st
  V.EvKey (V.KChar 'G') [] -> moveWhenVisible listMoveToEnd st
  V.EvKey (V.KChar 'r') [] -> composeFor selectedEvent CTReply st
  V.EvKey (V.KChar 'A') [] -> composeFor selectedEvent CTReact st
  V.EvKey (V.KChar 'Q') [] -> composeFor selectedEvent CTQuote st
  V.EvKey (V.KChar 'c') [] -> commentFor st
  V.EvKey (V.KChar 'v') [] -> revealSelected st
  V.EvKey (V.KChar 'y') [] -> yankSelected st
  V.EvKey (V.KChar c) [] | asScreen st == SLists, c >= '1', c <= '3' ->
    st { asListTab = fromEnum c - fromEnum '1' }
  _ -> st
  where
    nav f s = s { asList = f (asList s) }
    moveWhenVisible f s = case asScreen s of
      SFeed   -> nav f s
      SSearch -> nav f s
      _       -> s

-- | Back to the feed, restoring its widget from the model. Search results
-- are a borrowed widget, not model state — leaving the screen gives them back.
-- The compose editor resets too: a cancelled compose leaves nothing behind.
popScreen :: AppState -> AppState
popScreen st = st
  { asScreen = SFeed
  , asSearchQuery = ""
  , asCompose = editor NComposeEdit Nothing ""
  , asList = listReplace (asFeed st) Nothing (asList st)
  }

-- | Open compose for the focused event, or log that nothing is focused.
-- 'A' (react) prefills @+@: most reactions are likes, and deleting one
-- character beats typing an emoji every time.
composeFor :: (AppState -> Maybe Event) -> (Text -> ComposeTarget) -> AppState -> AppState
composeFor sel mk st = case sel st of
  Nothing -> pushLogText "nothing focused" st
  Just e  -> st
    { asScreen = SCompose (mk (evId e))
    , asCompose = editor NComposeEdit Nothing (prefill (mk (evId e)))
    }
  where
    prefill (CTReact _) = "+"
    prefill _           = ""

-- | Comment on the focused event unless it is a note (NIP-22 threads
-- everything but kind 1; that refusal is the spec's, quoted).
commentFor :: AppState -> AppState
commentFor st = case selectedEvent st of
  Nothing -> pushLogText "nothing focused" st
  Just e
    | evKind e == 1 -> pushLogText "that is a kind 1 note: use reply, not comment" st
    | otherwise -> st { asScreen = SCompose (CTComment (evId e)) }

-- | Reveal-once for NIP-36: session-only, never persisted, like the web UI.
revealSelected :: AppState -> AppState
revealSelected st = case selectedEvent st of
  Nothing -> st
  Just e  -> st { asRevealed = Set.insert (evId e) (asRevealed st) }

-- | Log the focused id in full: terminal selection copies what the eye
-- cannot reliably retype.
yankSelected :: AppState -> AppState
yankSelected st = case selectedEvent st of
  Nothing -> pushLogText "nothing focused" st
  Just e  -> pushLogText ("yanked " <> evId e) st

-- | @Enter@: on the feed, open a thread for the focused event (root plus
-- whatever replies the model already holds — the store fetch for missing
-- relatives is the App edge's @o@, not this); anywhere else, stay.
stepEnter :: AppState -> AppState
stepEnter st = case asScreen st of
  SFeed -> case selectedEvent st of
    Nothing -> st
    Just e  -> st
      { asScreen = SThread (evId e)
      , asThread = e : threadReplies (evId e) (toList (asFeed st))
      }
  _ -> st
