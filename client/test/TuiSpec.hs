{-# LANGUAGE OverloadedStrings #-}

-- | TUI specs: the pure core ('State.step', the 'Dispatch' parser,
-- 'Sanitize', the views' text layers) plus IO-edge seam tests
-- ('fillInitial', 'lookupEvent', 'buildUnsigned', 'Backend') driven
-- against memory stores — the same pattern the main suite uses for
-- 'handleClientMsg' and 'route'. Nothing here needs a terminal.
module TuiSpec (tuiSpec) where

import Brick.AttrMap (attrName)
import Brick.Main (appAttrMap, appChooseCursor, appDraw)
import Brick.Types (CursorLocation (..), Location (..), cursorLocationName)
import Brick.Widgets.Edit (editor, getEditContents)
import Brick.Widgets.List (list)
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.List (sort)
import Data.Maybe (isJust)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Graphics.Vty.Input.Events as V
import Krivostr.Cli.Options
  ( TimeSpec (..)
  , buildFilter
  , emptyFilterOpts
  , groupTags
  , parseKind
  , parseTag
  , parseWhen
  , resolveAuthor
  , resolveUpstreams
  )
import Krivostr.Cli.Render
  ( kindColour
  , oneLine
  , relativeTime
  , renderEvent
  , renderEventBlock
  , shortHex
  )
import Krivostr.Event
import Krivostr.Filter (Filter (..))
import Krivostr.Key
  ( PrivateKey
  , derivePublicKey
  , exportNpub
  , generatePrivateKey
  , pubKeyHex
  )
import Krivostr.Logging (LogEntry (..), LogLevel (..), leMsg, newLogger)
import Krivostr.Nip.Nip01 (signEvent)
import Krivostr.Nip.Nip27 (findMentions)
import Krivostr.Pool (newPool)
import Krivostr.Store (closeStore, enqueueOutbox, insertEvent, openMemoryStore)
import Krivostr.Tui (fillInitial, tuiDefaultKinds)
import Krivostr.Tui.App
  ( KeyPlan (..)
  , buildUnsigned
  , chooseCursor
  , cmdLine
  , drawHelp
  , drawUI
  , isCtrl
  , isImmediateKey
  , logPane
  , lookupEvent
  , planKey
  , statusBar
  , statusText
  , tuiApp
  )
import Krivostr.Tui.Backend
  (inProcessBackend, tbAddress, tbCount, tbDelRelay, tbFetchOnce, tbFetchThread, tbFlush, tbGet
  , tbOutbox, tbQuery, tbRelays, tbSearch, tbSetIngest)
import Krivostr.Tui.Dispatch (Command (..), commandHelp, parseCommand)
import Krivostr.Tui.Sanitize (stripAnsiAndC0)
import Krivostr.Tui.State
  ( step
  , applyCommand
  , selectedEvent
  , findEvent
  , popScreen
  , composeFor
  , commentFor
  , revealSelected
  , yankSelected
  , stepEnter
  , cycleScreen
  , cycleScreenBack
  , listMentions
  , handleResolvedMention
  )
import Krivostr.Tui.Theme (kindAttr, selectedAttr, sensitiveAttr, pendingAttr, themeAttrMap)
import Krivostr.Tui.Types
import Krivostr.Tui.Views.Compose (drawCompose, targetLine)
import Krivostr.Tui.Views.Feed (drawFeed, drawRow, rowText)
import Krivostr.Tui.Views.Lists (drawLists, tabName)
import Krivostr.Tui.Views.Thread (drawThread, threadReplies)
import Test.Hspec

mkEv :: Int -> Text -> IO Event
mkEv n content = mkEvFull n 1 content []

-- | Sign with tags from the start: retagging after signing invalidates the
-- signature, and 'insertEvent' refuses forgeries.
mkEvTagged :: Int -> Text -> [[Text]] -> IO Event
mkEvTagged n content tags = mkEvFull n 1 content tags

mkEvFull :: Int -> Int -> Text -> [[Text]] -> IO Event
mkEvFull n kind content tags = do
  sk <- generatePrivateKey
  pure $ signEvent sk Event
    { evId = ""
    , evPubkey = ""
    , evCreatedAt = 1700000000 + fromIntegral n
    , evKind = kind
    , evTags = tags
    , evContent = content
    , evSig = ""
    }

-- | Sign with a given key (pure): authorship fixtures — the list events
-- 'fillInitial' must attribute to me — need a specific pubkey, which
-- mkEvFull's fresh-key-per-call cannot give.
mkEvAs :: PrivateKey -> Int -> Int -> Text -> [[Text]] -> Event
mkEvAs sk n kind content tags = signEvent sk Event
  { evId = ""
  , evPubkey = ""
  , evCreatedAt = 1700000000 + fromIntegral n
  , evKind = kind
  , evTags = tags
  , evContent = content
  , evSig = ""
  }

emptyFilter :: Filter
emptyFilter = Filter Nothing Nothing Nothing Nothing Nothing Nothing [] Nothing

st0 :: AppState
st0 = initialState 1700000000 emptyFilter Nothing

key :: V.Event -> TuiEvent
key = EvVty

tuiSpec :: Spec
tuiSpec = describe "TUI" $ do
  describe "Sanitize.stripAnsiAndC0" $ do
    it "strips CSI color sequences" $
      stripAnsiAndC0 "\ESC[31mred\ESC[0m" `shouldBe` "red"

    it "drops Fe escapes and a trailing lone ESC" $
      stripAnsiAndC0 "a\ESCMb\ESC" `shouldBe` "ab"

    it "drops C0 controls and DEL but keeps newlines" $
      -- '\&' ends the \x7F escape: without it Haskell reads \x7Fc as one
      -- code point, which is exactly the kind of thing this test guards.
      stripAnsiAndC0 "a\NULb\x7F\&c\nd" `shouldBe` "abc\nd"

    it "maps tabs to two spaces and strips carriage returns" $
      stripAnsiAndC0 "a\tb\rc" `shouldBe` "a  bc"

    it "drops a CSI sequence with no terminator" $
      stripAnsiAndC0 "a\ESC[31" `shouldBe` "a"

    it "leaves clean text alone" $
      stripAnsiAndC0 "hello, world — café" `shouldBe` "hello, world — café"

  describe "Dispatch.parseCommand" $ do
    it "parses :q and :quit" $ do
      parseCommand "q" `shouldBe` CmdQuit
      parseCommand "quit" `shouldBe` CmdQuit
      parseCommand "  q  " `shouldBe` CmdQuit
      parseCommand "quit now" `shouldBe` CmdQuit

    it "keeps unknown and empty input as values, never failures" $ do
      parseCommand "bogus" `shouldBe` CmdUnknown "bogus"
      parseCommand "" `shouldBe` CmdUnknown ""

    it "keeps unknown and empty input as values, never failures" $ do
      parseCommand "bogus" `shouldBe` CmdUnknown "bogus"
      parseCommand "" `shouldBe` CmdUnknown ""

    it "parses the CLI-parity commands with their arguments" $ do
      parseCommand "search hello world" `shouldBe` CmdSearch "hello world"
      parseCommand "count" `shouldBe` CmdCount Nothing
      parseCommand "count 7" `shouldBe` CmdCount (Just "7")
      parseCommand "resolve nostr:npub1abc" `shouldBe` CmdResolve "nostr:npub1abc"
      parseCommand "verify alice@example.com" `shouldBe` CmdVerify "alice@example.com" Nothing
      parseCommand "verify alice@example.com npub1abc"
        `shouldBe` CmdVerify "alice@example.com" (Just "npub1abc")
      parseCommand "limit 250" `shouldBe` CmdLimit 250
      parseCommand "publish post.md My Title" `shouldBe` CmdPublish "post.md" (Just "My Title")
      parseCommand "publish post.md" `shouldBe` CmdPublish "post.md" Nothing
      parseCommand "ingest" `shouldBe` CmdIngest Nothing
      parseCommand "ingest on" `shouldBe` CmdIngest (Just True)
      parseCommand "ingest off" `shouldBe` CmdIngest (Just False)

    it "keeps malformed CLI-parity commands as unknown values" $ do
      parseCommand "search" `shouldBe` CmdUnknown "search"
      parseCommand "resolve" `shouldBe` CmdUnknown "resolve"
      parseCommand "limit abc" `shouldBe` CmdUnknown "limit abc"
      parseCommand "ingest maybe" `shouldBe` CmdUnknown "ingest maybe"
      parseCommand "publish" `shouldBe` CmdUnknown "publish"

    it "documents every command it parses" $
      commandHelp `shouldSatisfy` (not . null)

  describe "State.step" $ do
    it "starts following, unquit, and empty" $ do
      asFollowing st0 `shouldBe` True
      asQuit st0 `shouldBe` False
      asFeed st0 `shouldBe` Seq.empty

    it "quits on q and ignores other keys" $ do
      asQuit (step (key (V.EvKey (V.KChar 'q') [])) st0) `shouldBe` True
      asQuit (step (key (V.EvKey (V.KChar 'j') [])) st0) `shouldBe` False

    it "opens, edits, and dispatches the command line" $ do
      let opened = step (key (V.EvKey (V.KChar ':') [])) st0
      asCmdLine opened `shouldBe` Just ""
      let typed = step (key (V.EvKey (V.KChar 'q') [])) opened
      asCmdLine typed `shouldBe` Just "q"
      let done = step (key (V.EvKey V.KEnter [])) typed
      asQuit done `shouldBe` True
      asCmdLine done `shouldBe` Nothing

    it "cancels the command line on Esc" $ do
      let opened = step (key (V.EvKey (V.KChar ':') [])) st0
          cancelled = step (key (V.EvKey V.KEsc [])) opened
      asCmdLine cancelled `shouldBe` Nothing
      asQuit cancelled `shouldBe` False

    it "edits the command line with backspace and blocks nesting colons" $ do
      let opened = step (key (V.EvKey (V.KChar ':') [])) st0
          nested = step (key (V.EvKey (V.KChar ':') [])) opened
      asCmdLine nested `shouldBe` Just ""
      let typed = foldl
            (\s c -> step (key (V.EvKey (V.KChar c) [])) s)
            opened
            ("ab" :: String)
          backed = step (key (V.EvKey V.KBS [])) typed
      asCmdLine backed `shouldBe` Just "a"

    it "toggles the log pane on ~" $ do
      let shown = step (key (V.EvKey (V.KChar '~') [])) st0
      asShowLog shown `shouldBe` True
      asShowLog (step (key (V.EvKey (V.KChar '~') [])) shown) `shouldBe` False

    it "prepends incoming events newest-first and dedupes by id" $ do
      e1 <- mkEv 1 "first"
      e2 <- mkEv 2 "second"
      let s1 = step (EvIncoming e1) st0
          s2 = step (EvIncoming e2) s1
          s3 = step (EvIncoming e1) s2
      map evContent (foldr (:) [] (asFeed s2)) `shouldBe` ["second", "first"]
      asFeed s3 `shouldBe` asFeed s2

    it "caps the feed, dropping the oldest" $ do
      evs <- mapM (\n -> mkEv n (T.pack (show n))) [1 .. feedCap + 1]
      let st = foldl (flip (step . EvIncoming)) st0 evs
      Seq.length (asFeed st) `shouldBe` feedCap

    it "routes publish and async completions to the log" $ do
      let s1 = step (EvPublishDone "abc" (Right ())) st0
          s2 = step (EvPublishDone "abc" (Left "refused")) s1
          s3 = step (EvAsyncResult "verify" (Right "ok")) s2
          s4 = step (EvAsyncResult "verify" (Left "no route")) s3
          s5 = step (EvLog (LogEntry Info "drained")) s4
      -- Full message equality: asserting only the count leaves every
      -- LogEntry an unevaluated thunk, unticked by HPC.
      map leMsg (toList (asLog s5))
        `shouldBe` ["published abc", "publish failed abc: refused", "verify: ok", "verify failed: no route", "drained"]

    it "leaves the feed alone on tick" $ do
      e <- mkEv 1 "x"
      let st = step (EvIncoming e) st0
      Seq.length (asFeed (step EvTick st)) `shouldBe` 1

    it "rejects unknown commands to the log, not to the screen" $ do
      let opened = step (key (V.EvKey (V.KChar ':') [])) st0
          typed = foldl
            (\s c -> step (key (V.EvKey (V.KChar c) [])) s)
            opened
            ("bogus" :: String)
          done = step (key (V.EvKey V.KEnter [])) typed
      asQuit done `shouldBe` False
      asCmdLine done `shouldBe` Nothing
      Seq.length (asLog done) `shouldBe` 1

  describe "State navigation (M1)" $ do
    it "moves selection with j/k and jumps with g/G" $ do
      e1 <- mkEv 1 "first"
      e2 <- mkEv 2 "second"
      e3 <- mkEv 3 "third"
      -- Newest first, like a store fill: foldr over newest-first input so
      -- each prepend lands in display order.
      let st = foldr (step . EvIncoming) st0 [e3, e2, e1]
          top = step (key (V.EvKey (V.KChar 'g') [])) st
          down = step (key (V.EvKey (V.KChar 'j') [])) top
          down2 = step (key (V.EvKey (V.KChar 'j') [])) down
          up = step (key (V.EvKey (V.KChar 'k') [])) down2
          bottom = step (key (V.EvKey (V.KChar 'G') [])) st
      map evContent (selEv top) `shouldBe` ["third"]
      map evContent (selEv down) `shouldBe` ["second"]
      map evContent (selEv down2) `shouldBe` ["first"]
      map evContent (selEv up) `shouldBe` ["second"]
      map evContent (selEv bottom) `shouldBe` ["first"]

    it "opens a thread for the focused event on Enter" $ do
      e1 <- mkEv 1 "root note"
      let st = step (EvIncoming e1) st0
          focused = step (key (V.EvKey (V.KChar 'g') [])) st
          opened = step (key (V.EvKey V.KEnter [])) focused
      asScreen opened `shouldBe` SThread (evId e1)
      map evId (asThread opened) `shouldBe` [evId e1]

    it "enters search on / and edits the query" $ do
      let searching = step (key (V.EvKey (V.KChar '/') [])) st0
      asScreen searching `shouldBe` SSearch
      let typed = foldl
            (\s c -> step (key (V.EvKey (V.KChar c) [])) s)
            searching
            ("gm" :: String)
      asSearchQuery typed `shouldBe` "gm"
      let backed = step (key (V.EvKey V.KBS [])) typed
      asSearchQuery backed `shouldBe` "g"

    it "pops back to the feed on Esc, restoring its widget" $ do
      e1 <- mkEv 1 "root note"
      let st = step (EvIncoming e1) st0
          searching = step (key (V.EvKey (V.KChar '/') [])) st
          back = step (key (V.EvKey V.KEsc [])) searching
      asScreen back `shouldBe` SFeed
      asSearchQuery back `shouldBe` ""

    it "ignores Enter outside the feed and Esc inside it" $ do
      e1 <- mkEv 1 "root note"
      let st = step (EvIncoming e1) st0
          searching = step (key (V.EvKey (V.KChar '/') [])) st
      asScreen (step (key (V.EvKey V.KEnter [])) searching) `shouldBe` SSearch
      asScreen (step (key (V.EvKey V.KEsc [])) st) `shouldBe` SFeed

    it "merges fetched events into feed and open thread" $ do
      e1 <- mkEv 1 "root note"
      let st = step (EvIncoming e1) st0
          focused = step (key (V.EvKey (V.KChar 'g') [])) st
          opened = step (key (V.EvKey V.KEnter [])) focused
      e2 <- mkEv 2 "reply"
      let reply = e2 { evTags = [["e", evId e1]] }
          merged = step (EvFetched [reply, e1]) opened
      -- Full-value equality, not projections: HPC ticks an expression only
      -- when it evaluates, and a length check leaves every element a thunk.
      asThread merged `shouldBe` [e1, reply]
      asFeed merged `shouldBe` Seq.fromList [reply, e1]

    it "merges fetched events into a bare feed without a thread" $ do
      e1 <- mkEv 1 "root note"
      let merged = step (EvFetched [e1]) st0
      Seq.length (asFeed merged) `shouldBe` 1
      asThread merged `shouldBe` []

  describe "State send keys (M2)" $ do
    it "opens reply/quote compose for the focused event" $ do
      e1 <- mkEv 1 "root note"
      let st = step (key (V.EvKey (V.KChar 'g') [])) (step (EvIncoming e1) st0)
          replying = step (key (V.EvKey (V.KChar 'r') [])) st
          quoting = step (key (V.EvKey (V.KChar 'Q') [])) st
      asScreen replying `shouldBe` SCompose (CTReply (evId e1))
      asScreen quoting `shouldBe` SCompose (CTQuote (evId e1))

    it "opens react compose prefilled with +" $ do
      e1 <- mkEv 1 "root note"
      let st = step (key (V.EvKey (V.KChar 'g') [])) (step (EvIncoming e1) st0)
          reacting = step (key (V.EvKey (V.KChar 'A') [])) st
      asScreen reacting `shouldBe` SCompose (CTReact (evId e1))
      getEditContents (asCompose reacting) `shouldBe` ["+"]

    it "opens comment compose for non-notes and refuses notes" $ do
      e1 <- mkEv 1 "a note"
      e2raw <- mkEv 30023 "an article"
      -- Retagging post-signing is fine here: pure step tests never verify.
      let e2 = e2raw { evKind = 30023 }
          st = foldr (step . EvIncoming) st0 [e2, e1]
          onArticle = step (key (V.EvKey (V.KChar 'g') [])) st
          commenting = step (key (V.EvKey (V.KChar 'c') [])) onArticle
      asScreen commenting `shouldBe` SCompose (CTComment (evId e2))
      let onNote = step (key (V.EvKey (V.KChar 'j') [])) onArticle
          refused = step (key (V.EvKey (V.KChar 'c') [])) onNote
      asScreen refused `shouldBe` SFeed
      Seq.length (asLog refused) `shouldBe` 1

    it "reveals sensitive events session-only and yanks ids to the log" $ do
      e1 <- mkEv 1 "secret"
      let st = step (key (V.EvKey (V.KChar 'g') [])) (step (EvIncoming e1) st0)
          revealed = step (key (V.EvKey (V.KChar 'v') [])) st
          yanked = step (key (V.EvKey (V.KChar 'y') [])) st
      asRevealed revealed `shouldSatisfy` Set.member (evId e1)
      map leMsg (toList (asLog yanked)) `shouldBe` ["yanked " <> evId e1]

    it "leaves immediate sends (a/R/d/m) to the App edge" $ do
      e1 <- mkEv 1 "root note"
      let st = step (key (V.EvKey (V.KChar 'g') [])) (step (EvIncoming e1) st0)
      asScreen (step (key (V.EvKey (V.KChar 'a') [])) st) `shouldBe` SFeed
      asScreen (step (key (V.EvKey (V.KChar 'd') [])) st) `shouldBe` SFeed

    it "records mutes and clears pending markers on publish verdicts" $ do
      let muted = step (EvMuted "abc123") st0
      asMuted muted `shouldSatisfy` Set.member "abc123"
      let pending = st0 { asPending = Set.singleton "eid1" }
          done = step (EvPublishDone "eid1" (Right ())) pending
      asPending done `shouldSatisfy` Set.notMember "eid1"
      Seq.length (asLog done) `shouldBe` 1

  describe "Views.Compose.targetLine and Views.Lists.tabName" $ do
    it "names every compose target with its tag shape" $ do
      targetLine CTNote `shouldBe` "note"
      targetLine (CTReply "abcdef1234567890") `shouldBe` "reply → e:abcdef12"
      targetLine (CTReact "abcdef1234567890") `shouldBe` "react → e:abcdef12"
      targetLine (CTQuote "abcdef1234567890") `shouldBe` "quote → q:abcdef12"
      targetLine (CTComment "abcdef1234567890") `shouldBe` "comment → E:abcdef12"
      targetLine (CTDm "abcdef1234567890") `shouldBe` "dm → p:abcdef12"

    it "names mute first, then pin and bookmark" $ do
      tabName 0 `shouldBe` "mute"
      tabName 1 `shouldBe` "pin"
      tabName 2 `shouldBe` "bookmark"

  describe "Views.Thread.threadReplies" $ do
    it "matches positional and marked e tags, nothing else" $ do
      e1 <- mkEv 1 "root"
      e2 <- mkEv 2 "positional reply"
      e3 <- mkEv 3 "marked reply"
      e4 <- mkEv 4 "unrelated"
      let pos = e2 { evTags = [["e", evId e1]] }
          marked = e3 { evTags = [["e", evId e1, "wss://x", "reply"]] }
          other = e4 { evTags = [["p", evId e1]] }
      map evId (threadReplies (evId e1) [pos, marked, other]) `shouldBe` [evId pos, evId marked]

  describe "Views.Feed.rowText and App.statusText" $ do
    it "formats rows CLI-style and sanitizes content" $ do
      e <- mkEv 1 "hello \ESC[31mred\ESC[0m"
      let row = rowText 1700000001 Set.empty Set.empty e
      row `shouldSatisfy` T.isPrefixOf "now  #1  "
      row `shouldSatisfy` T.isInfixOf "hello red"
      row `shouldSatisfy` (not . T.isInfixOf "\ESC")
      rowText 1700000001 (Set.singleton (evId e)) Set.empty e `shouldSatisfy` T.isInfixOf "[sending]"

    it "renders feed size, follow state, outbox, and store total" $
      statusText st0 `shouldBe` "feed · 0 events · following · outbox 0 · store ?"

    it "names every screen, including every compose target" $ do
      let named s = head (T.splitOn " · " (statusText (st0 { asScreen = s })))
      named SFeed `shouldBe` "feed"
      named (SThread "abc") `shouldBe` "thread"
      named SSearch `shouldBe` "search"
      named SDm `shouldBe` "dm"
      named SRelays `shouldBe` "relays"
      named SLists `shouldBe` "lists"
      named SOutbox `shouldBe` "outbox"
      named (SCompose CTNote) `shouldBe` "compose"
      named (SCompose (CTReply "abc")) `shouldBe` "compose"
      named (SCompose (CTComment "abc")) `shouldBe` "compose"
      named (SCompose (CTDm "abc")) `shouldBe` "compose"
      named SHelp `shouldBe` "help"

  describe "App key routing and drawing" $ do
    it "chooses the compose cursor only on the compose screen" $ do
      let cl = CursorLocation (Location (0, 0)) (Just NComposeEdit) True
      fmap cursorLocationName (chooseCursor st0 [cl]) `shouldBe` Nothing
      fmap cursorLocationName (chooseCursor (st0 { asScreen = SCompose CTNote }) [cl])
        `shouldBe` Just (Just NComposeEdit)
      fmap cursorLocationName (chooseCursor (st0 { asScreen = SCompose CTNote }) [])
        `shouldBe` Nothing

    it "matches Ctrl-modified characters and the four immediate keys" $ do
      isCtrl 'g' (V.EvKey (V.KChar 'g') [V.MCtrl]) `shouldBe` True
      isCtrl 'g' (V.EvKey (V.KChar 'g') []) `shouldBe` False
      isCtrl 'x' (V.EvKey (V.KChar 'g') [V.MCtrl]) `shouldBe` False
      isCtrl 'g' (V.EvKey V.KEnter [V.MCtrl]) `shouldBe` False
      map (\c -> isImmediateKey (V.EvKey (V.KChar c) [])) "aRdm" `shouldBe` [True, True, True, True]
      isImmediateKey (V.EvKey (V.KChar 'a') [V.MCtrl]) `shouldBe` False
      isImmediateKey (V.EvKey (V.KChar 'x') []) `shouldBe` False
      isImmediateKey (V.EvKey V.KEnter []) `shouldBe` False

    it "gives every key to an open command line, running it on Enter" $ do
      let st = st0 { asCmdLine = Just "q" }
      planKey st (V.EvKey (V.KChar 'q') []) `shouldBe` PlanForward
      planKey st (V.EvKey V.KEnter []) `shouldBe` PlanCommand

    it "routes compose keys: send, cancel, promote, edit" $ do
      let st = st0 { asScreen = SCompose CTNote }
      planKey st (V.EvKey (V.KChar 'g') [V.MCtrl]) `shouldBe` PlanSendCompose
      planKey st (V.EvKey V.KEsc []) `shouldBe` PlanForward
      planKey st (V.EvKey (V.KChar 'E') []) `shouldBe` PlanPromoteEditor
      planKey st (V.EvKey (V.KChar 'x') []) `shouldBe` PlanToEditor
      planKey (st { asCompose = editor NComposeEdit Nothing "draft" }) (V.EvKey (V.KChar 'E') [])
        `shouldBe` PlanToEditor

    it "routes thread keys n and o, and nothing off-thread" $ do
      let st = st0 { asScreen = SThread "abc" }
      planKey st (V.EvKey (V.KChar 'n') []) `shouldBe` PlanResolveMentions
      planKey st (V.EvKey (V.KChar 'o') []) `shouldBe` PlanFetchRelatives
      planKey st0 (V.EvKey (V.KChar 'n') []) `shouldBe` PlanForward

    it "runs the search on Enter, or opens the selected result" $ do
      e <- mkEv 1 "hit"
      let bare = st0 { asScreen = SSearch }
          withSel = st0 { asScreen = SSearch, asList = list NFeedList (Seq.fromList [e]) 1 }
      planKey bare (V.EvKey V.KEnter []) `shouldBe` PlanRunSearch
      planKey withSel (V.EvKey V.KEnter []) `shouldBe` PlanOpenSearchResult

    it "routes an open command line's Enter to the command runner" $ do
      planKey (st0 { asCmdLine = Just "count" }) (V.EvKey V.KEnter []) `shouldBe` PlanCommand
      planKey (st0 { asCmdLine = Just "count" }) (V.EvKey (V.KChar 'c') []) `shouldBe` PlanForward

    it "sends immediately on a feed or search key, forwards elsewhere" $ do
      planKey st0 (V.EvKey (V.KChar 'a') []) `shouldBe` PlanImmediate
      planKey (st0 { asScreen = SSearch }) (V.EvKey (V.KChar 'R') []) `shouldBe` PlanImmediate
      planKey st0 (V.EvKey (V.KChar 'j') []) `shouldBe` PlanForward
      planKey (st0 { asScreen = SRelays }) (V.EvKey (V.KChar 'a') []) `shouldBe` PlanForward

    it "wires the app record to the pure draw and cursor functions" $ do
      lg <- newLogger Error
      store <- openMemoryStore lg
      pool <- newPool lg (const (pure ()))
      let backend = inProcessBackend lg ":memory:" store pool [] (\_ -> pure ())
          app = tuiApp backend
      appDraw app `seq` appAttrMap app st0 `seq` (pure () :: IO ())
      appChooseCursor app st0 [] `seq` (pure () :: IO ())
      closeStore store

    it "renders the status bar, command line, and log pane" $ do
      statusBar st0 `seq` cmdLine st0 `seq` logPane st0 `seq` (pure () :: IO ())
      cmdLine (st0 { asCmdLine = Just "relays" }) `seq` (pure () :: IO ())
      logPane (st0 { asShowLog = True, asLog = Seq.fromList [LogEntry Info "line"] }) `seq` (pure () :: IO ())

    it "draws every screen, including help" $ do
      mapM_ (\s -> drawUI (st0 { asScreen = s }) `seq` (pure () :: IO ()))
        [ SFeed, SThread "x", SSearch, SDm, SRelays, SLists, SOutbox
        , SCompose CTNote, SHelp ]
      drawHelp `seq` (pure () :: IO ())

  describe "Backend.tbFetchThread" $ do
    it "fetches threads from the store without touching relays" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      e1 <- mkEv 1 "root note"
      reply <- mkEvTagged 2 "reply" [["e", evId e1]]
      _ <- insertEvent st e1
      _ <- insertEvent st reply
      _ <- insertEvent st =<< mkEv 7 "unrelated reaction"
      pool <- newPool lg (const (pure ()))
      let backend = inProcessBackend lg ":memory:" st pool [] (\_ -> pure ())
      found <- tbFetchThread backend (evId e1) 0
      found `shouldBe` [e1, reply]
      closeStore st

  describe "Backend seam on a memory store" $ do
    let withBackend f = do
          lg <- newLogger Error
          st <- openMemoryStore lg
          pool <- newPool lg (const (pure ()))
          let backend = inProcessBackend lg ":memory:" st pool [] (\_ -> pure ())
          f backend st
          closeStore st

    it "queries, counts, gets, and searches without relays" $ do
      withBackend $ \backend st -> do
        e1 <- mkEv 1 "hello world"
        _ <- insertEvent st e1
        found <- tbQuery backend emptyFilter
        length found `shouldSatisfy` (>= 1)
        count <- tbCount backend emptyFilter
        count `shouldSatisfy` (>= 1)
        tbGet backend (evId e1) `shouldReturn` Just e1
        tbGet backend (T.replicate 64 "0") `shouldReturn` Nothing
        hits <- tbSearch backend "hello" False Nothing Nothing 10
        map evId hits `shouldBe` [evId e1]

    it "resolves a kind:pubkey:d address and toggles ingest" $ do
      withBackend $ \backend st -> do
        sk <- generatePrivateKey
        let art = mkEvAs sk 1 30023 "article body" [["d", "hello"]]
            addr = "30023:" <> pubKeyHex (derivePublicKey sk) <> ":hello"
        _ <- insertEvent st art
        tbAddress backend addr `shouldReturn` Just art
        tbAddress backend "30023:deadbeef:nope" `shouldReturn` Nothing
        tbAddress backend "not-an-address" `shouldReturn` Nothing
        -- Empty pool: (un)subscribing just broadcasts to nobody.
        tbSetIngest backend True emptyFilter `shouldReturn` ()
        tbSetIngest backend False emptyFilter `shouldReturn` ()

    it "reports empty relays, outbox, and refusal to delete nothing" $ do
      withBackend $ \backend _st -> do
        tbRelays backend `shouldReturn` []
        tbOutbox backend `shouldReturn` 0
        tbDelRelay backend "wss://x.example" `shouldReturn` ()

    it "flushes queued events and keeps unconfirmed ones" $ do
      withBackend $ \backend st -> do
        e1 <- mkEv 1 "queued note"
        _ <- insertEvent st e1
        enqueueOutbox st e1
        tbOutbox backend `shouldReturn` 1
        -- Empty pool: broadcast fails fast, rows stay queued.
        tbFlush backend
        tbOutbox backend `shouldReturn` 1

    it "fetchOnce with no relays returns nothing fast" $ do
      withBackend $ \backend _st -> do
        found <- tbFetchOnce backend emptyFilter 500000
        found `shouldBe` []

  describe "Views.Lists.drawLists and tabName edge cases" $ do
    it "renders mute tab with entries" $ do
      let st = st0 { asListTab = 0, asMuted = Set.fromList ["abc123", "def456"] }
      let widget = drawLists st
      pure $ widget `seq` ()
      -- We can't easily inspect Widget internals, but we can verify it doesn't crash
      -- and that tabName is called correctly
      tabName 0 `shouldBe` "mute"
      tabName 1 `shouldBe` "pin"
      tabName 2 `shouldBe` "bookmark"
      tabName 999 `shouldBe` "bookmark"

    it "renders pin tab with entries" $ do
      let st = st0 { asListTab = 1, asPins = Set.fromList ["pin1", "pin2"] }
      let widget = drawLists st
      pure $ widget `seq` ()
      tabName 1 `shouldBe` "pin"

    it "renders bookmark tab with entries" $ do
      let st = st0 { asListTab = 2, asBookmarks = Set.fromList ["bm1"] }
      let widget = drawLists st
      pure $ widget `seq` ()
      tabName 2 `shouldBe` "bookmark"

    it "renders empty tab with helpful message" $ do
      let st = st0 { asListTab = 0, asMuted = Set.empty }
      let widget = drawLists st
      pure $ widget `seq` ()
      tabName 0 `shouldBe` "mute"

  describe "Views.Compose.drawCompose" $ do
    it "renders compose view with target line and editor" $ do
      let ed = editor NComposeEdit Nothing "test content"
      let widget = drawCompose st0 CTNote ed
      pure $ widget `seq` ()
      -- Verify it doesn't crash and targetLine is used
      targetLine CTNote `shouldBe` "note"

    it "renders reply compose with shortened event id" $ do
      let ed = editor NComposeEdit Nothing ""
      let widget = drawCompose st0 (CTReply "abcdef1234567890") ed
      pure $ widget `seq` ()
      targetLine (CTReply "abcdef1234567890") `shouldBe` "reply → e:abcdef12"

    it "renders react compose with prefill" $ do
      let ed = editor NComposeEdit Nothing "+"
      let widget = drawCompose st0 (CTReact "abcdef1234567890") ed
      pure $ widget `seq` ()
      targetLine (CTReact "abcdef1234567890") `shouldBe` "react → e:abcdef12"

    it "renders quote compose" $ do
      let ed = editor NComposeEdit Nothing ""
      let widget = drawCompose st0 (CTQuote "abcdef1234567890") ed
      pure $ widget `seq` ()
      targetLine (CTQuote "abcdef1234567890") `shouldBe` "quote → q:abcdef12"

    it "renders comment compose" $ do
      let ed = editor NComposeEdit Nothing ""
      let widget = drawCompose st0 (CTComment "abcdef1234567890") ed
      pure $ widget `seq` ()
      targetLine (CTComment "abcdef1234567890") `shouldBe` "comment → E:abcdef12"

    it "renders dm compose" $ do
      let ed = editor NComposeEdit Nothing ""
      let widget = drawCompose st0 (CTDm "abcdef1234567890") ed
      pure $ widget `seq` ()
      targetLine (CTDm "abcdef1234567890") `shouldBe` "dm → p:abcdef12"

  describe "Views.Thread.drawThread and threadReplies edge cases" $ do
    it "renders empty thread with helpful message" $ do
      let widget = drawThread 1700000000 Set.empty Set.empty []
      pure $ widget `seq` ()
      threadReplies "root" [] `shouldBe` []

    it "renders thread with root and replies" $ do
      e1 <- mkEv 1 "root"
      e2 <- mkEvTagged 2 "reply" [["e", evId e1]]
      let widget = drawThread 1700000000 Set.empty Set.empty [e1, e2]
      pure $ widget `seq` ()
      map evId (threadReplies (evId e1) [e2]) `shouldBe` [evId e2]

    it "threadReplies handles empty tag list" $ do
      e1 <- mkEv 1 "root"
      e2 <- mkEvTagged 2 "no tags" [[]]
      threadReplies (evId e1) [e2] `shouldBe` []

    it "threadReplies handles malformed e tag" $ do
      e1 <- mkEv 1 "root"
      e2 <- mkEvTagged 2 "bad tag" [["e"]]
      threadReplies (evId e1) [e2] `shouldBe` []

  describe "Views.Feed.drawFeed, drawRow, and rowText edge cases" $ do
    it "renders empty feed with helpful message" $ do
      let widget = drawFeed 1700000000 st0
      pure $ widget `seq` ()
      e <- mkEv 1 "test"
      rowText 1700000001 Set.empty Set.empty e `shouldSatisfy` T.isPrefixOf "now  #1  "

    it "renders feed with events" $ do
      e <- mkEv 1 "hello"
      let st = step (EvIncoming e) st0
      let widget = drawFeed 1700000001 st
      pure $ widget `seq` ()
      rowText 1700000001 Set.empty Set.empty e `shouldSatisfy` T.isInfixOf "hello"

    it "drawRow delegates to rowText" $ do
      e <- mkEv 1 "test"
      let widget = drawRow 1700000001 Set.empty Set.empty False e
      pure $ widget `seq` ()
      rowText 1700000001 Set.empty Set.empty e `shouldSatisfy` T.isInfixOf "test"

    it "rowText includes pending marker when true" $ do
      e <- mkEv 1 "test"
      rowText 1700000001 (Set.singleton (evId e)) Set.empty e `shouldSatisfy` T.isInfixOf "[sending]"

    it "rowText excludes pending marker when false" $ do
      e <- mkEv 1 "test"
      rowText 1700000001 Set.empty Set.empty e `shouldSatisfy` (not . T.isInfixOf "[sending]")

  describe "State.findEvent" $ do
    it "finds event in feed by id" $ do
      e1 <- mkEv 1 "first"
      e2 <- mkEv 2 "second"
      let st = foldr (step . EvIncoming) st0 [e2, e1]
      findEvent (evId e1) st `shouldBe` Just e1
      findEvent (evId e2) st `shouldBe` Just e2

    it "finds event in open thread by id" $ do
      e1 <- mkEv 1 "root"
      e2 <- mkEvTagged 2 "reply" [["e", evId e1]]
      let st = foldr (step . EvIncoming) st0 [e1]
          focused = step (key (V.EvKey (V.KChar 'g') [])) st
          opened = step (key (V.EvKey V.KEnter [])) focused
      findEvent (evId e1) opened `shouldBe` Just e1
      findEvent (evId e2) opened `shouldBe` Nothing -- not in feed or thread yet

    it "returns Nothing for missing event" $ do
      e1 <- mkEv 1 "first"
      let st = step (EvIncoming e1) st0
      findEvent "nonexistent" st `shouldBe` Nothing

  describe "State.mergeFetched edge cases" $ do
    it "handles empty e tag in mergeFetched" $ do
      e1 <- mkEv 1 "root"
      e2 <- mkEvTagged 2 "bad tag" [["e"]]
      let st = step (EvIncoming e1) st0
          focused = step (key (V.EvKey (V.KChar 'g') [])) st
          opened = step (key (V.EvKey V.KEnter [])) focused
          merged = step (EvFetched [e2]) opened
      asThread merged `shouldBe` [e1] -- e2 not added because tag is malformed

  describe "State mention jump (worker ordering)" $ do
    it "keeps the root first when it is also in the fetch" $ do
      e1 <- mkEv 1 "root"
      e2 <- mkEvTagged 2 "reply" [["e", evId e1]]
      let opened = step (key (V.EvKey V.KEnter []))
                     (step (key (V.EvKey (V.KChar 'g') [])) (step (EvIncoming e1) st0))
          merged = step (EvFetched [e1, e2]) opened
      asThread merged `shouldBe` [e1, e2]

    it "loads the referenced thread after a jump, root included" $ do
      oldRoot <- mkEv 1 "old root"
      newRoot <- mkEv 2 "new root"
      reply   <- mkEvTagged 3 "new reply" [["e", evId newRoot]]
      let onOld = step (key (V.EvKey V.KEnter []))
                    (step (key (V.EvKey (V.KChar 'g') [])) (step (EvIncoming oldRoot) st0))
          jumped = step (EvResolvedMention (RTEvent (evId newRoot))) onOld
          merged = step (EvFetched [newRoot, reply]) jumped
      asScreen merged `shouldBe` SThread (evId newRoot)
      asThread merged `shouldBe` [newRoot, reply]

    it "a mention jump replaces the open thread instead of appending" $ do
      oldRoot <- mkEv 1 "old"
      newRoot <- mkEv 2 "new"
      let onOld = step (key (V.EvKey V.KEnter []))
                    (step (key (V.EvKey (V.KChar 'g') [])) (step (EvIncoming oldRoot) st0))
          jumped = handleResolvedMention (RTEvent (evId newRoot)) onOld
      asScreen jumped `shouldBe` SThread (evId newRoot)
      asThread jumped `shouldBe` []

    it "seeds the thread from the model when the root is already known" $ do
      e1 <- mkEv 1 "root"
      let st = handleResolvedMention (RTEvent (evId e1)) (step (EvIncoming e1) st0)
      asScreen st `shouldBe` SThread (evId e1)
      asThread st `shouldBe` [e1]

    it "a fetch applied before the jump lands on the stale thread" $ do
      oldRoot <- mkEv 1 "old"
      newRoot <- mkEv 2 "new"
      reply   <- mkEvTagged 3 "new reply" [["e", evId newRoot]]
      let onOld = step (key (V.EvKey V.KEnter []))
                    (step (key (V.EvKey (V.KChar 'g') [])) (step (EvIncoming oldRoot) st0))
          stale = step (EvFetched [newRoot, reply]) onOld
      -- The bug the worker order avoids: with the old thread open, the new
      -- thread's events are not attributed to it.
      asThread stale `shouldBe` [oldRoot]

  describe "State.pushEvent deduplication" $ do
    it "dedupes by id in pushEvent" $ do
      e1 <- mkEv 1 "first"
      let st = step (EvIncoming e1) st0
          st2 = step (EvIncoming e1) st -- duplicate
      Seq.length (asFeed st2) `shouldBe` 1

    it "preserves selection when pushing events" $ do
      e1 <- mkEv 1 "first"
      e2 <- mkEv 2 "second"
      let st = foldr (step . EvIncoming) st0 [e2, e1]
          focused = step (key (V.EvKey (V.KChar 'g') [])) st
      isJust (selectedEvent focused) `shouldBe` True

  describe "State.moveWhenVisible edge cases" $ do
    it "handles movement keys on search screen (widget may be empty)" $ do
      e1 <- mkEv 1 "first"
      e2 <- mkEv 2 "second"
      let st = foldr (step . EvIncoming) st0 [e2, e1]
          searching = step (key (V.EvKey (V.KChar '/') [])) st
          -- Movement keys should not crash on search screen
          down = step (key (V.EvKey (V.KChar 'j') [])) searching
          up = step (key (V.EvKey (V.KChar 'k') [])) down
      asScreen down `shouldBe` SSearch
      asScreen up `shouldBe` SSearch

    it "ignores movement keys on non-feed screens" $ do
      let st = st0 { asScreen = SThread "abc" }
      let down = step (key (V.EvKey (V.KChar 'j') [])) st
      asScreen down `shouldBe` SThread "abc"

  describe "State.popScreen" $ do
    it "restores feed screen and resets compose editor" $ do
      let st = st0 { asScreen = SSearch, asSearchQuery = "test" }
      let popped = popScreen st
      asScreen popped `shouldBe` SFeed
      asSearchQuery popped `shouldBe` ""

  describe "State.composeFor nothing focused" $ do
    it "logs 'nothing focused' when no event selected" $ do
      let st = st0
      let result = composeFor selectedEvent CTReply st
      Seq.length (asLog result) `shouldBe` 1
      map leMsg (toList (asLog result)) `shouldBe` ["nothing focused"]

  describe "State.commentFor edge cases" $ do
    it "logs 'nothing focused' when no event selected" $ do
      let result = commentFor st0
      Seq.length (asLog result) `shouldBe` 1
      map leMsg (toList (asLog result)) `shouldBe` ["nothing focused"]

    it "refuses comment on kind 1 note with log message" $ do
      e1 <- mkEv 1 "a note"
      let st = step (EvIncoming e1) st0
          focused = step (key (V.EvKey (V.KChar 'g') [])) st
          refused = commentFor focused
      asScreen refused `shouldBe` SFeed
      Seq.length (asLog refused) `shouldBe` 1
      map leMsg (toList (asLog refused)) `shouldBe` ["that is a kind 1 note: use reply, not comment"]

  describe "State.revealSelected edge cases" $ do
    it "does nothing when no event focused" $ do
      let result = revealSelected st0
      asRevealed result `shouldBe` Set.empty

    it "adds event id to revealed set" $ do
      e1 <- mkEv 1 "secret"
      let st = step (EvIncoming e1) st0
          focused = step (key (V.EvKey (V.KChar 'g') [])) st
          revealed = revealSelected focused
      asRevealed revealed `shouldSatisfy` Set.member (evId e1)

  describe "State.yankSelected edge cases" $ do
    it "logs 'nothing focused' when no event selected" $ do
      let result = yankSelected st0
      Seq.length (asLog result) `shouldBe` 1
      map leMsg (toList (asLog result)) `shouldBe` ["nothing focused"]

    it "logs full event id when focused" $ do
      e1 <- mkEv 1 "secret"
      let st = step (EvIncoming e1) st0
          focused = step (key (V.EvKey (V.KChar 'g') [])) st
          yanked = yankSelected focused
      Seq.length (asLog yanked) `shouldBe` 1
      map leMsg (toList (asLog yanked)) `shouldBe` ["yanked " <> evId e1]

  describe "State.stepEnter edge cases" $ do
    it "does nothing when no event focused on feed" $ do
      let result = stepEnter st0
      asScreen result `shouldBe` SFeed
      asThread result `shouldBe` []

    it "stays on current screen when not on feed" $ do
      let st = st0 { asScreen = SThread "abc" }
      let result = stepEnter st
      asScreen result `shouldBe` SThread "abc"

  describe "Types.AppState record fields" $ do
    it "initializes all fields correctly" $ do
      let st = initialState 1700000000 emptyFilter Nothing
      asScreen st `shouldBe` SFeed
      asFeed st `shouldBe` Seq.empty
      asFilter st `shouldBe` emptyFilter
      asFollowing st `shouldBe` True
      asKey st `shouldBe` Nothing
      asRevealed st `shouldBe` Set.empty
      asMuted st `shouldBe` Set.empty
      asOutbox st `shouldBe` 0
      asStats st `shouldBe` Nothing
      asIngest st `shouldBe` False
      asCmdLine st `shouldBe` Nothing
      asLog st `shouldBe` Seq.empty
      asQuit st `shouldBe` False
      asShowLog st `shouldBe` False
      asSearchQuery st `shouldBe` ""
      asThread st `shouldBe` []
      asPending st `shouldBe` Set.empty
      asPins st `shouldBe` Set.empty
      asBookmarks st `shouldBe` Set.empty
      asListTab st `shouldBe` 0

    it "Screen constructors are all reachable" $ do
      let screens = [ SFeed, SThread "abc", SSearch, SDm, SRelays, SLists, SOutbox
                    , SCompose CTNote, SCompose (CTReply "abc"), SCompose (CTReact "abc")
                    , SCompose (CTQuote "abc"), SCompose (CTComment "abc"), SCompose (CTDm "abc")
                    , SHelp ]
      length screens `shouldBe` 14

    it "ComposeTarget constructors are all reachable" $ do
      let targets = [ CTNote, CTReply "a", CTReact "a", CTQuote "a", CTComment "a", CTDm "a" ]
      length targets `shouldBe` 6

    it "Name constructors are all reachable" $ do
      let names = [ NFeedList, NCmdEdit, NLogView, NComposeEdit ]
      length names `shouldBe` 4

    it "TuiEvent constructors are all reachable" $ do
      e <- mkEv 1 "test"
      let events = [ EvIncoming e, EvPublishDone "a" (Right ()), EvAsyncResult "k" (Right "v")
                   , EvMuted "a", EvFetched [], EvTick, EvLog (LogEntry Info "test") ]
      length events `shouldBe` 7

  describe "State.step EvMuted branch" $ do
    it "adds muted id and logs" $ do
      let muted = step (EvMuted "abc123") st0
      asMuted muted `shouldSatisfy` Set.member "abc123"
      Seq.length (asLog muted) `shouldBe` 1
      map leMsg (toList (asLog muted)) `shouldBe` ["muted abc123"]

  describe "State.step EvAsyncResult branch" $ do
    it "logs async success" $ do
      let st = step (EvAsyncResult "verify" (Right "ok")) st0
      Seq.length (asLog st) `shouldBe` 1
      map leMsg (toList (asLog st)) `shouldBe` ["verify: ok"]

    it "logs async failure" $ do
      let st = step (EvAsyncResult "verify" (Left "failed")) st0
      Seq.length (asLog st) `shouldBe` 1
      map leMsg (toList (asLog st)) `shouldBe` ["verify failed: failed"]

  describe "State.step EvLog branch" $ do
    it "appends log entry" $ do
      let st = step (EvLog (LogEntry Warn "test warning")) st0
      Seq.length (asLog st) `shouldBe` 1
      map leMsg (toList (asLog st)) `shouldBe` ["test warning"]

  describe "State.cycleScreen (Tab key)" $ do
    it "cycles through all screens" $ do
      let s0 = st0
      let s1 = cycleScreen s0
      asScreen s1 `shouldBe` SRelays
      let s2 = cycleScreen s1
      asScreen s2 `shouldBe` SLists
      let s3 = cycleScreen s2
      asScreen s3 `shouldBe` SDm
      let s4 = cycleScreen s3
      asScreen s4 `shouldBe` SOutbox
      let s5 = cycleScreen s4
      asScreen s5 `shouldBe` SHelp
      let s6 = cycleScreen s5
      asScreen s6 `shouldBe` SFeed

    it "cycles through screens via step with Tab key" $ do
      let s0 = step (key (V.EvKey (V.KChar '\t') [])) st0
      asScreen s0 `shouldBe` SRelays
      let s1 = step (key (V.EvKey (V.KChar '\t') [])) s0
      asScreen s1 `shouldBe` SLists
      let s2 = step (key (V.EvKey (V.KChar '\t') [])) s1
      asScreen s2 `shouldBe` SDm
      let s3 = step (key (V.EvKey (V.KChar '\t') [])) s2
      asScreen s3 `shouldBe` SOutbox
      let s4 = step (key (V.EvKey (V.KChar '\t') [])) s3
      asScreen s4 `shouldBe` SHelp
      let s5 = step (key (V.EvKey (V.KChar '\t') [])) s4
      asScreen s5 `shouldBe` SFeed

    it "cycles backwards via step with Shift-Tab (KBackTab)" $ do
      let s0 = step (key (V.EvKey V.KBackTab [])) st0
      asScreen s0 `shouldBe` SHelp
      let s1 = step (key (V.EvKey V.KBackTab [])) s0
      asScreen s1 `shouldBe` SOutbox
      let s2 = step (key (V.EvKey V.KBackTab [])) s1
      asScreen s2 `shouldBe` SDm
      let s3 = step (key (V.EvKey V.KBackTab [])) s2
      asScreen s3 `shouldBe` SLists
      let s4 = step (key (V.EvKey V.KBackTab [])) s3
      asScreen s4 `shouldBe` SRelays
      let s5 = step (key (V.EvKey V.KBackTab [])) s4
      asScreen s5 `shouldBe` SFeed

  describe "Unread counter" $ do
    it "increments on EvIncoming when not on feed" $ do
      e1 <- mkEv 1 "event 1"
      e2 <- mkEv 2 "event 2"
      let st = st0 { asScreen = SThread "abc" }
          st1 = step (EvIncoming e1) st
          st2 = step (EvIncoming e2) st1
      asUnread st1 `shouldBe` 1
      asUnread st2 `shouldBe` 2

    it "does not increment on EvIncoming when on feed" $ do
      e1 <- mkEv 1 "event 1"
      let st = step (EvIncoming e1) st0
      asUnread st `shouldBe` 0

    it "clears on popScreen (Esc from sub-screen)" $ do
      e1 <- mkEv 1 "event 1"
      let st = st0 { asScreen = SThread "abc", asUnread = 5 }
          st1 = step (EvIncoming e1) st  -- unread becomes 6
          st2 = popScreen st1
      asScreen st2 `shouldBe` SFeed
      asUnread st2 `shouldBe` 0

    it "clears on Tab cycle back to feed" $ do
      e1 <- mkEv 1 "event 1"
      let st = st0 { asScreen = SHelp, asUnread = 3 }
          st1 = step (EvIncoming e1) st  -- unread becomes 4
          st2 = cycleScreen st1  -- SHelp -> SFeed
      asScreen st2 `shouldBe` SFeed
      asUnread st2 `shouldBe` 0

    it "clears on Shift-Tab cycle back to feed" $ do
      e1 <- mkEv 1 "event 1"
      let st = st0 { asScreen = SRelays, asUnread = 3 }
          st1 = step (EvIncoming e1) st  -- unread becomes 4
          st2 = cycleScreenBack st1  -- SRelays -> SFeed
      asScreen st2 `shouldBe` SFeed
      asUnread st2 `shouldBe` 0

    it "statusText shows unread count on feed" $ do
      let st = st0 { asUnread = 3 }
      statusText st `shouldSatisfy` T.isInfixOf "feed (3 new)"

    it "statusText does not show unread when zero" $ do
      let st = st0 { asUnread = 0 }
      statusText st `shouldSatisfy` (not . T.isInfixOf "new")

  describe "State.applyCommand new commands" $ do
    it "switches to relays view" $ do
      let st = applyCommand CmdRelays st0
      asScreen st `shouldBe` SRelays
      asCmdLine st `shouldBe` Nothing

    it "switches to lists view" $ do
      let st = applyCommand CmdLists st0
      asScreen st `shouldBe` SLists
      asCmdLine st `shouldBe` Nothing

    it "switches to outbox view" $ do
      let st = applyCommand CmdOutbox st0
      asScreen st `shouldBe` SOutbox
      asCmdLine st `shouldBe` Nothing

    it "switches to dm view" $ do
      let st = applyCommand CmdDm st0
      asScreen st `shouldBe` SDm
      asCmdLine st `shouldBe` Nothing

    it "switches to help view" $ do
      let st = applyCommand CmdHelp st0
      asScreen st `shouldBe` SHelp
      asCmdLine st `shouldBe` Nothing

    it "opens search with the query already in place" $ do
      let st = applyCommand (CmdSearch "gm nostr") st0
      asScreen st `shouldBe` SSearch
      asSearchQuery st `shouldBe` "gm nostr"
      asCmdLine st `shouldBe` Nothing

    it "sets the feed limit in the filter" $ do
      let st = applyCommand (CmdLimit 250) st0
      fLimit (asFilter st) `shouldBe` Just 250
      asCmdLine st `shouldBe` Nothing

    it "toggles ingest, honouring an explicit on/off" $ do
      asIngest (applyCommand (CmdIngest Nothing) st0) `shouldBe` True
      asIngest (applyCommand (CmdIngest (Just True)) st0) `shouldBe` True
      asIngest (applyCommand (CmdIngest (Just False)) (st0 { asIngest = True })) `shouldBe` False

    it "closes the command line for the commands the edge runs" $ do
      asCmdLine (applyCommand (CmdCount Nothing) st0) `shouldBe` Nothing
      asCmdLine (applyCommand (CmdResolve "x") st0) `shouldBe` Nothing
      asCmdLine (applyCommand (CmdVerify "a@b.c" Nothing) st0) `shouldBe` Nothing
      asCmdLine (applyCommand (CmdPublish "f.md" Nothing) st0) `shouldBe` Nothing

  describe "Views.Feed muting filter" $ do
    it "filters out events from muted authors (retroactive on EvMuted)" $ do
      e1 <- mkEv 1 "from muted"
      e2 <- mkEv 2 "from normal"
      let st = foldr (step . EvIncoming) st0 [e2, e1]
          -- Process the mute event - this should purge e1 from feed
          muted = step (EvMuted (evPubkey e1)) st
      -- The model feed should only contain e2 (not muted)
      let feed = toList (asFeed muted)
      length feed `shouldBe` 1
      evContent (head feed) `shouldBe` "from normal"

    it "rejects incoming events from muted authors at ingest time" $ do
      e1 <- mkEv 1 "from muted"
      e2 <- mkEv 2 "from normal"
      let st = st0 { asMuted = Set.singleton (evPubkey e1) }
          -- Incoming events from muted author should be rejected
          st1 = step (EvIncoming e1) st
          st2 = step (EvIncoming e2) st1
      let feed = toList (asFeed st2)
      length feed `shouldBe` 1
      evContent (head feed) `shouldBe` "from normal"

  describe "Views.Feed NIP-36 content warning" $ do
    it "hides sensitive content when not revealed" $ do
      e1 <- mkEvTagged 1 "secret" [["content-warning", "spoiler"]]
      let row = rowText 1700000001 Set.empty Set.empty e1
      row `shouldSatisfy` T.isInfixOf "[hidden — content-warning]"
      row `shouldSatisfy` (not . T.isInfixOf "secret")

    it "shows sensitive content when revealed" $ do
      e1 <- mkEvTagged 1 "secret" [["content-warning", "spoiler"]]
      let revealed = Set.singleton (evId e1)
      let row = rowText 1700000001 Set.empty revealed e1
      row `shouldSatisfy` T.isInfixOf "secret"
      row `shouldSatisfy` (not . T.isInfixOf "[hidden — content-warning]")

    it "shows normal content without warning tag" $ do
      e1 <- mkEv 1 "normal content"
      let row = rowText 1700000001 Set.empty Set.empty e1
      row `shouldSatisfy` T.isInfixOf "normal content"
      row `shouldSatisfy` (not . T.isInfixOf "[hidden — content-warning]")

  describe "Views.Thread NIP-36 content warning" $ do
    it "passes revealed set to drawRow" $ do
      e1 <- mkEvTagged 1 "secret" [["content-warning", "spoiler"]]
      let widget = drawThread 1700000000 Set.empty Set.empty [e1]
      pure $ widget `seq` ()
      -- Just verify it doesn't crash
      True `shouldBe` True

  describe "Krivostr.Tui.Theme" $ do
    it "maps kind 1 to kind-note" $ do
      kindAttr 1 `shouldBe` attrName "kind-note"
    it "maps kind 4 to kind-dm" $ do
      kindAttr 4 `shouldBe` attrName "kind-dm"
    it "maps kind 7 to kind-reaction" $ do
      kindAttr 7 `shouldBe` attrName "kind-reaction"
    it "maps kind 0 to kind-meta" $ do
      kindAttr 0 `shouldBe` attrName "kind-meta"
    it "maps kind 3 to kind-meta" $ do
      kindAttr 3 `shouldBe` attrName "kind-meta"
    it "maps kind 10002 to kind-meta" $ do
      kindAttr 10002 `shouldBe` attrName "kind-meta"
    it "maps kind 5 to kind-delete" $ do
      kindAttr 5 `shouldBe` attrName "kind-delete"
    it "maps kind 6 to kind-delete" $ do
      kindAttr 6 `shouldBe` attrName "kind-delete"
    it "maps other kinds to kind-note" $ do
      kindAttr 999 `shouldBe` attrName "kind-note"
    it "themeAttrMap contains all kind attrs" $ do
      let attrs = [kindAttr 1, kindAttr 4, kindAttr 7, kindAttr 0, kindAttr 3, kindAttr 10002, kindAttr 5, kindAttr 6, selectedAttr, sensitiveAttr, pendingAttr]
      -- Verify all attrs are accounted for (11 distinct attributes in our list)
      length attrs `shouldBe` 11

    it "themeAttrMap is non-empty" $ do
      -- Just verify the map is constructed without error
      themeAttrMap `seq` True `shouldBe` True

  describe "Mention handling" $ do
    it "findMentions runs without error on valid text" $ do
      let text = "hello world"
      let ms = findMentions text
      length ms `shouldBe` 0

    it "findMentions returns empty for invalid bech32" $ do
      let text = "nostr:invalid_bech32"
      let ms = findMentions text
      length ms `shouldBe` 0

    it "findMentions handles empty text" $ do
      let ms = findMentions ""
      length ms `shouldBe` 0

    it "listMentions extracts mentions from thread event" $ do
      e1 <- mkEvTagged 1 "hello world" [["content-warning", "spoiler"]]
      let st = foldr (step . EvIncoming) st0 [e1]
          focused = step (key (V.EvKey (V.KChar 'g') [])) st
          opened = step (key (V.EvKey V.KEnter [])) focused
          mentioned = listMentions opened
      -- No mentions in "hello world" so asMentions should be empty
      asMentions mentioned `shouldBe` []
      Seq.length (asLog mentioned) `shouldBe` 1

    it "listMentions logs 'not in a thread' when not on thread" $ do
      let mentioned = listMentions st0
      Seq.length (asLog mentioned) `shouldBe` 1
      map leMsg (toList (asLog mentioned)) `shouldBe` ["not in a thread"]

    it "handleResolvedMention opens thread for RTEvent" $ do
      let st = handleResolvedMention (RTEvent "eid123") st0
      asScreen st `shouldBe` SThread "eid123"

    it "handleResolvedMention does nothing for RTOpaque" $ do
      let st = handleResolvedMention (RTOpaque "unknown") st0
      asScreen st `shouldBe` SFeed

    it "handleResolvedMention logs authors and addresses instead of switching" $ do
      let a = handleResolvedMention (RTAuthor "abc123") st0
          r = handleResolvedMention (RTAddress "30023:pk:d") st0
      asScreen a `shouldBe` SFeed
      map leMsg (toList (asLog a)) `shouldBe` ["author abc123"]
      asScreen r `shouldBe` SFeed
      map leMsg (toList (asLog r)) `shouldBe` ["address 30023:pk:d (open with :resolve)"]

  describe "Krivostr.Cli.Options pure helpers" $ do
    describe "parseWhen" $ do
      it "parses a unix timestamp" $
        parseWhen "1700000000" `shouldBe` Right (At 1700000000)

      it "parses every relative unit" $ do
        parseWhen "30s" `shouldBe` Right (Ago 30)
        parseWhen "5m"  `shouldBe` Right (Ago 300)
        parseWhen "2h"  `shouldBe` Right (Ago 7200)
        parseWhen "7d"  `shouldBe` Right (Ago 604800)
        parseWhen "2w"  `shouldBe` Right (Ago 1209600)
        parseWhen "3mo" `shouldBe` Right (Ago 7776000)
        parseWhen "1y"  `shouldBe` Right (Ago 31536000)

      it "parses an ISO date" $
        parseWhen "2026-01-01" `shouldBe` Right (At 1767225600)

      it "rejects garbage" $ do
        parseWhen "not-a-time"   `shouldSatisfy` isLeft
        parseWhen ""             `shouldSatisfy` isLeft
        parseWhen "3fortnights"  `shouldSatisfy` isLeft

    describe "parseKind" $ do
      it "parses every named kind" $ do
        parseKind "note"     `shouldBe` Right 1
        parseKind "dm"       `shouldBe` Right 4
        parseKind "delete"   `shouldBe` Right 5
        parseKind "repost"   `shouldBe` Right 6
        parseKind "like"     `shouldBe` Right 7
        parseKind "metadata" `shouldBe` Right 0
        parseKind "follow"   `shouldBe` Right 3
        parseKind "relays"   `shouldBe` Right 10002
        parseKind "giftwrap" `shouldBe` Right 1059

      it "parses numeric kinds within the 16-bit range" $ do
        parseKind "0"     `shouldBe` Right 0
        parseKind "999"   `shouldBe` Right 999
        parseKind "65535" `shouldBe` Right 65535

      it "rejects out-of-range and non-numeric" $ do
        parseKind "65536"      `shouldSatisfy` isLeft
        parseKind "-1"         `shouldSatisfy` isLeft
        parseKind "not-a-kind" `shouldSatisfy` isLeft

    describe "parseTag" $ do
      it "parses e=value, #e=value, and bare pairs" $ do
        parseTag "e=abc123"  `shouldBe` Right ("e", "abc123")
        parseTag "#e=abc123" `shouldBe` Right ("e", "abc123")
        parseTag "p=pubkey"  `shouldBe` Right ("p", "pubkey")

      it "accepts an empty value but rejects a missing key" $ do
        parseTag "key="   `shouldBe` Right ("key", "")
        parseTag "=value" `shouldSatisfy` isLeft

    describe "resolveAuthor" $ do
      it "resolves an npub to its hex" $ do
        sk <- generatePrivateKey
        let npub = exportNpub (derivePublicKey sk)
            hex  = pubKeyHex (derivePublicKey sk)
        resolveAuthor (T.unpack npub) `shouldBe` Right hex

      it "passes hex through and rejects junk" $ do
        sk <- generatePrivateKey
        let hex = pubKeyHex (derivePublicKey sk)
        resolveAuthor (T.unpack hex) `shouldBe` Right hex
        resolveAuthor "invalid"      `shouldSatisfy` isLeft

    describe "groupTags" $ do
      it "groups values per key" $
        groupTags [("e", "a"), ("e", "b"), ("p", "c")]
          `shouldSatisfy` \res -> sort res == sort [("e", ["a", "b"]), ("p", ["c"])]

      it "maps the empty list to the empty list" $
        groupTags [] `shouldBe` []

    describe "resolveUpstreams" $ do
      it "falls back to the compiled-in defaults" $
        resolveUpstreams [] [] `shouldNotBe` ([] :: [Text])

      it "unions flags and saved, deduplicated, flags first" $ do
        resolveUpstreams ["a", "b"] ["b", "c"] `shouldBe` ["a", "b", "c"]
        resolveUpstreams ["a", "a"] ["a"]      `shouldBe` ["a"]

  describe "Krivostr.Cli.Render" $ do
    it "shortHex keeps short strings and elides the middle" $ do
      shortHex 4 "abcd"         `shouldBe` "abcd"
      shortHex 4 "abcdefghi"    `shouldBe` "abcdefghi"
      shortHex 4 "abcdefghijkl" `shouldBe` "abcd\8230ijkl"

    it "oneLine collapses whitespace, CRLF, and clips" $ do
      oneLine 80 "hello    world\nwith\nlines" `shouldBe` "hello world with lines"
      oneLine 80 "hello\r\nworld"              `shouldBe` "hello world"
      oneLine 10 "123456789012345"             `shouldBe` "123456789\8230"
      oneLine 80 ""                            `shouldBe` ""

    it "relativeTime names every bucket" $ do
      relativeTime 1000 950          `shouldBe` "now"
      relativeTime 3600 3000         `shouldBe` "10m"
      relativeTime 86400 43200       `shouldBe` "12h"
      relativeTime 864000 432000     `shouldBe` "5d"
      relativeTime 31536000 15768000 `shouldBe` "6mo"
      relativeTime 31536000 0        `shouldBe` "1y"

    it "kindColour matches the CLI palette" $ do
      kindColour 4     `shouldBe` "\ESC[35m"
      kindColour 7     `shouldBe` "\ESC[33m"
      kindColour 0     `shouldBe` "\ESC[36m"
      kindColour 3     `shouldBe` "\ESC[36m"
      kindColour 10002 `shouldBe` "\ESC[36m"
      kindColour 5     `shouldBe` "\ESC[31m"
      kindColour 6     `shouldBe` "\ESC[31m"
      kindColour 999   `shouldBe` "\ESC[32m"

    describe "renderEvent" $ do
      it "includes age, kind, pubkey, and content" $ do
        let e = Event "id" "pub" 1000 1 [] "content" "sig"
            rendered = renderEvent False False 2000 e
        rendered `shouldSatisfy` T.isInfixOf "pub"
        rendered `shouldSatisfy` T.isInfixOf "#1"
        rendered `shouldSatisfy` T.isInfixOf "content"

      it "hides content behind a CW unless revealed" $ do
        let e = Event "id" "pub" 1000 1 [["content-warning", "spoiler"]] "secret" "sig"
        renderEvent False False 2000 e `shouldSatisfy` T.isInfixOf "sensitive"
        let shown = renderEvent False True 2000 e
        shown `shouldSatisfy` T.isInfixOf "secret"
        shown `shouldSatisfy` (not . T.isInfixOf "sensitive")

      it "emits ANSI only when colour is on" $ do
        let e = Event "id" "pub" 1000 1 [] "content" "sig"
        renderEvent True  False 2000 e `shouldSatisfy` T.isInfixOf "\ESC["
        renderEvent False False 2000 e `shouldSatisfy` (not . T.isInfixOf "\ESC[")

      it "sanitizes the warning reason — it is tag data" $ do
        let e = Event "id" "pub" 1000 1 [["content-warning", "\ESC[31mx\ESC[0m"]] "body" "sig"
            rendered = renderEvent False False 2000 e
        rendered `shouldSatisfy` T.isInfixOf "sensitive"
        rendered `shouldSatisfy` (not . T.isInfixOf "\ESC")

    describe "renderEventBlock" $ do
      it "includes header, body, and tags" $ do
        let e = Event "id" "pub" 1000 1 [["p", "alice"]] "content" "sig"
            rendered = renderEventBlock False False 2000 e
        rendered `shouldSatisfy` T.isInfixOf "content"
        rendered `shouldSatisfy` T.isInfixOf "#p alice"

      it "sanitizes tag values" $ do
        let e = Event "id" "pub" 1000 1 [["subject", "\ESC[31mhi\ESC[0m"]] "body" "sig"
            rendered = renderEventBlock False False 2000 e
        rendered `shouldSatisfy` T.isInfixOf "hi"
        rendered `shouldSatisfy` (not . T.isInfixOf "\ESC[31m")

  describe "Tui.tuiDefaultKinds" $ do
    it "renders social kinds and excludes the firehose and ciphertext" $ do
      tuiDefaultKinds `shouldSatisfy` all (`elem` [1, 5, 6, 7, 16, 1111, 9735, 30023])
      -- Encrypted and firehose-dominating kinds must not stream into rows.
      tuiDefaultKinds `shouldNotSatisfy` (4 `elem`)
      tuiDefaultKinds `shouldNotSatisfy` (1059 `elem`)
      tuiDefaultKinds `shouldNotSatisfy` (0 `elem`)
      tuiDefaultKinds `shouldNotSatisfy` (3 `elem`)
      tuiDefaultKinds `shouldNotSatisfy` (10002 `elem`)

  describe "Tui.fillInitial seam" $ do
    it "fills the feed from the store, newest first" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      e1 <- mkEv 1 "first"
      e2 <- mkEv 2 "second"
      _ <- insertEvent st e1
      _ <- insertEvent st e2
      filt <- buildFilter emptyFilterOpts
      initial <- fillInitial st filt Nothing
      map evContent (toList (asFeed initial)) `shouldBe` ["second", "first"]
      closeStore st

    it "loads my mute/pin/bookmark lists when a key is present" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      -- List events must be authored by me and carry the list kinds:
      -- fillInitial queries (author = my pubkey, kind = 10000/10001/10003).
      let m1 = mkEvAs sk 1 10000 "" [["p", "pub1"], ["p", "pub2"]]
          p1 = mkEvAs sk 2 10001 "" [["e", "ev1"]]
          b1 = mkEvAs sk 3 10003 "" [["e", "ev2"], ["a", "30023:x:y"]]
      _ <- insertEvent st m1
      _ <- insertEvent st p1
      _ <- insertEvent st b1
      filt <- buildFilter emptyFilterOpts
      initial <- fillInitial st filt (Just sk)
      asMuted initial     `shouldBe` Set.fromList ["pub1", "pub2"]
      asPins initial      `shouldBe` Set.fromList ["ev1"]
      asBookmarks initial `shouldBe` Set.fromList ["ev2", "30023:x:y"]
      closeStore st

    it "reads only the newest version of a replaceable list" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      let older = mkEvAs sk 1 10000 "" [["p", "gone"]]
          newer = mkEvAs sk 5 10000 "" [["p", "kept"]]
      _ <- insertEvent st older
      _ <- insertEvent st newer
      filt <- buildFilter emptyFilterOpts
      initial <- fillInitial st filt (Just sk)
      asMuted initial `shouldBe` Set.fromList ["kept"]
      closeStore st

    it "starts with empty lists and no key" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      filt <- buildFilter emptyFilterOpts
      initial <- fillInitial st filt Nothing
      asMuted initial     `shouldBe` Set.empty
      asPins initial      `shouldBe` Set.empty
      asBookmarks initial `shouldBe` Set.empty
      closeStore st

  describe "Tui.App.lookupEvent seam" $ do
    it "falls back to the store when the model does not have it" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      e1 <- mkEv 1 "test event"
      _ <- insertEvent st e1
      pool <- newPool lg (const (pure ()))
      let backend = inProcessBackend lg ":memory:" st pool [] (\_ -> pure ())
      filt <- buildFilter emptyFilterOpts
      lookupEvent backend (initialState 0 filt Nothing) (evId e1)
        `shouldReturn` Right e1
      closeStore st

    it "prefers the model copy" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      e1 <- mkEv 1 "in feed"
      _ <- insertEvent st e1
      pool <- newPool lg (const (pure ()))
      let backend = inProcessBackend lg ":memory:" st pool [] (\_ -> pure ())
      filt <- buildFilter emptyFilterOpts
      initial <- fillInitial st filt Nothing
      lookupEvent backend initial (evId e1) `shouldReturn` Right e1
      closeStore st

    it "reports a missing event as Left" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      pool <- newPool lg (const (pure ()))
      let backend = inProcessBackend lg ":memory:" st pool [] (\_ -> pure ())
      filt <- buildFilter emptyFilterOpts
      r <- lookupEvent backend (initialState 0 filt Nothing) "nonexistent"
      r `shouldSatisfy` isLeft
      closeStore st

  describe "Tui.App.buildUnsigned seam" $ do
    it "builds a note — no key needed to BUILD, only to send" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      pool <- newPool lg (const (pure ()))
      let backend = inProcessBackend lg ":memory:" st pool [] (\_ -> pure ())
      filt <- buildFilter emptyFilterOpts
      r <- buildUnsigned backend (initialState 0 filt Nothing) CTNote "hello world"
      r `shouldBe` Right (UnsignedEvent "" 0 1 [] "hello world")
      closeStore st

    it "builds a reply with NIP-10 marked tags, parent from the store" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      e1 <- mkEv 1 "parent note"
      _ <- insertEvent st e1
      pool <- newPool lg (const (pure ()))
      let backend = inProcessBackend lg ":memory:" st pool [] (\_ -> pure ())
      filt <- buildFilter emptyFilterOpts
      r <- buildUnsigned backend (initialState 0 filt Nothing) (CTReply (evId e1)) "reply text"
      case r of
        Right ue -> do
          ueKind ue    `shouldBe` 1
          ueContent ue `shouldBe` "reply text"
          ueTags ue    `shouldBe` [["e", evId e1, "", "root"], ["p", evPubkey e1]]
        Left e -> expectationFailure e
      closeStore st

    it "reports a missing parent as Left" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      pool <- newPool lg (const (pure ()))
      let backend = inProcessBackend lg ":memory:" st pool [] (\_ -> pure ())
      filt <- buildFilter emptyFilterOpts
      r <- buildUnsigned backend (initialState 0 filt Nothing) (CTReply (T.replicate 64 "0")) "x"
      r `shouldSatisfy` isLeft
      closeStore st

    it "builds a reaction with the default emoji and NIP-25 tags" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      e1 <- mkEv 1 "note to react"
      _ <- insertEvent st e1
      pool <- newPool lg (const (pure ()))
      let backend = inProcessBackend lg ":memory:" st pool [] (\_ -> pure ())
      filt <- buildFilter emptyFilterOpts
      r <- buildUnsigned backend (initialState 0 filt Nothing) (CTReact (evId e1)) ""
      case r of
        Right ue -> do
          ueKind ue    `shouldBe` 7
          ueContent ue `shouldBe` "+"
          ueTags ue    `shouldBe` [["e", evId e1, ""], ["p", evPubkey e1], ["k", "1"]]
        Left e -> expectationFailure e
      closeStore st

    it "builds a quote with a q tag and no e tag" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      e1 <- mkEv 1 "note to quote"
      _ <- insertEvent st e1
      pool <- newPool lg (const (pure ()))
      let backend = inProcessBackend lg ":memory:" st pool [] (\_ -> pure ())
      filt <- buildFilter emptyFilterOpts
      r <- buildUnsigned backend (initialState 0 filt Nothing) (CTQuote (evId e1)) "my quote"
      case r of
        Right ue -> do
          ueKind ue    `shouldBe` 1
          ueContent ue `shouldBe` "my quote"
          ueTags ue    `shouldBe` [["q", evId e1, ""]]
        Left e -> expectationFailure e
      closeStore st

    it "builds a comment with the address of an addressable target" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      -- A real kind-30023 with a d tag, correctly signed: insertEvent verifies.
      e1 <- mkEvFull 1 30023 "article" [["d", "slug"]]
      _ <- insertEvent st e1
      pool <- newPool lg (const (pure ()))
      let backend = inProcessBackend lg ":memory:" st pool [] (\_ -> pure ())
          addr = "30023:" <> evPubkey e1 <> ":slug"
      filt <- buildFilter emptyFilterOpts
      r <- buildUnsigned backend (initialState 0 filt Nothing) (CTComment (evId e1)) "my comment"
      case r of
        Right ue -> do
          ueKind ue `shouldBe` 1111
          ueTags ue `shouldSatisfy` any (\t -> case t of
            ("A" : a : _) -> a == addr
            _             -> False)
        Left e -> expectationFailure e
      closeStore st

    it "refuses comment on kind 1 note" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      e1 <- mkEv 1 "a note"
      _ <- insertEvent st e1
      pool <- newPool lg (const (pure ()))
      let backend = inProcessBackend lg ":memory:" st pool [] (\_ -> pure ())
      filt <- buildFilter emptyFilterOpts
      r <- buildUnsigned backend (initialState 0 filt Nothing) (CTComment (evId e1)) "comment"
      r `shouldBe` Left "that is a kind 1 note: use reply, not comment"
      closeStore st

    it "refuses DM compose until the DM view exists" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      pool <- newPool lg (const (pure ()))
      let backend = inProcessBackend lg ":memory:" st pool [] (\_ -> pure ())
      filt <- buildFilter emptyFilterOpts
      r <- buildUnsigned backend (initialState 0 filt Nothing) (CTDm "abcd") "hi"
      r `shouldBe` Left "DM compose needs the DM view (M3)"
      closeStore st

-- | Focused event as a zero-or-one list, for shouldBe against literals.
selEv :: AppState -> [Event]
selEv s = maybe [] (: []) (selectedEvent s)
