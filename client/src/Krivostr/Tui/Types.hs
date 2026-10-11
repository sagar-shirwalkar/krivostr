{-# LANGUAGE OverloadedStrings #-}

-- | TUI model types. Pure data: the screen ADT, the event ADT that drives
-- 'Krivostr.Tui.State.step', and the application state it threads.
--
-- Two deliberate deviations from the design doc's sketch: @asQuit@ (step is
-- total, so quitting is a state flag the App edge turns into 'halt' — and a
-- testable one) and @asShowLog@ (the log pane toggles with @~@).
module Krivostr.Tui.Types
  ( Name (..)
  , Screen (..)
  , ComposeTarget (..)
  , TuiEvent (..)
  , AppState (..)
  , initialState
  , feedCap
  , logCap
  , ResolveTarget(..)
  ) where

import Brick.Widgets.Edit (Editor, editor)
import Brick.Widgets.List (GenericList, list)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time.Clock.POSIX (POSIXTime)
import qualified Graphics.Vty.Input.Events as V
import Krivostr.Event (Event)
import Krivostr.Nip.Nip27 (Mention)
import Krivostr.Filter (Filter)
import Krivostr.Key (PrivateKey)
import Krivostr.Logging (LogEntry)
import Krivostr.Store (StoreStats)

-- | Brick resource names. One per focusable widget, present tense.
data Name
  = NFeedList
  | NCmdEdit
  | NLogView
  | NComposeEdit
  deriving (Show, Eq, Ord)

-- | Every screen the TUI can show. Views (Feed, Thread, …) render these;
-- the dispatcher and keys move between them.
data Screen
  = SFeed
  | SThread Text
  | SSearch
  | SDm
  | SRelays
  | SLists
  | SOutbox
  | SCompose ComposeTarget
  | SHelp
  deriving (Show, Eq)

-- | What we can resolve a mention into.
data ResolveTarget
  = RTAuthor Text       -- hex pubkey
  | RTEvent Text        -- event id
  | RTAddress Text      -- kind:pubkey:slug
  | RTOpaque Text       -- fallback
  deriving (Show, Eq)

-- | What a compose screen will send.
data ComposeTarget
  = CTNote
  | CTReply Text
  | CTReact Text
  | CTQuote Text
  | CTComment Text
  | CTDm Text
  deriving (Show, Eq)

-- | Everything that can change the state. 'EvVty' wraps raw terminal input
-- (the App edge forwards it); everything else arrives from worker threads
-- over the 'BChan' or from the pool handler.
data TuiEvent
  = EvIncoming Event
  | EvPublishDone Text (Either String ())
  | EvAsyncResult Text (Either String Text)
  | EvMuted Text
  | EvFetched [Event]
  | EvTick
  | EvLog LogEntry
  | EvVty V.Event
  | EvResolveMentions [Mention]
  | EvResolvedMention ResolveTarget
  | EvComposeSent
-- No Eq/Show: vty events and key material do not promise them, and tests
-- read fields, not whole values.

-- | The whole TUI model. 'asFeed' is the model (newest first, capped,
-- deduplicated); 'asList' is the brick widget state over the visible slice.
-- They move together — see 'Krivostr.Tui.State.pushEvent'.
data AppState = AppState
  { asScreen    :: !Screen
  , asFeed      :: !(Seq Event)
  , asFilter    :: !Filter
  , asFollowing :: !Bool
  , asKey       :: !(Maybe PrivateKey)
  , asRevealed  :: !(Set Text)
  , asMuted     :: !(Set Text)
  , asOutbox    :: !Int
  , asStats     :: !(Maybe StoreStats)
  , asCmdLine   :: !(Maybe Text)
  , asLog       :: !(Seq LogEntry)
  , asList      :: !(GenericList Name Seq Event)
  , asQuit      :: !Bool
  , asShowLog   :: !Bool
  , asNow       :: !POSIXTime
  , asSearchQuery :: !Text
  , asThread    :: ![Event]
  , asCompose   :: !(Editor Text Name)
  , asPending   :: !(Set Text)
  , asPins      :: !(Set Text)
  , asBookmarks :: !(Set Text)
  , asListTab   :: !Int
  , asUnread    :: !Int
  , asMentions  :: ![Mention]
  }

-- | Feed cap: newest events kept, oldest dropped with a log line.
feedCap :: Int
feedCap = 500

-- | Log cap: the log pane is a diagnostic tail, not an archive.
logCap :: Int
logCap = 200

-- | Empty model over now, a starting filter, and an optional key. Nothing
-- here touches IO: the caller fills feed, stats, and outbox depth after.
initialState :: POSIXTime -> Filter -> Maybe PrivateKey -> AppState
initialState now f key = AppState
  { asScreen    = SFeed
  , asFeed      = Seq.empty
  , asFilter    = f
  , asFollowing = True
  , asKey       = key
  , asRevealed  = Set.empty
  , asMuted     = Set.empty
  , asOutbox    = 0
  , asStats     = Nothing
  , asCmdLine   = Nothing
  , asLog       = Seq.empty
  , asList      = list NFeedList Seq.empty 1
  , asQuit      = False
  , asShowLog   = False
  , asNow       = now
  , asSearchQuery = ""
  , asThread    = []
  , asCompose   = editor NComposeEdit Nothing ""
  , asPending   = Set.empty
  , asPins      = Set.empty
  , asBookmarks = Set.empty
  , asListTab   = 0
  , asUnread    = 0
  , asMentions  = []
  }
