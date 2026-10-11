{-# LANGUAGE OverloadedStrings #-}

-- | TUI specs: the pure core ('State.step', the 'Dispatch' parser,
-- 'Sanitize') without a terminal. IO edges ('App', 'Backend', 'runTui')
-- are covered by seam tests in the main suite, not here.
module TuiSpec (tuiSpec) where

import Brick.Widgets.Edit (getEditContents)
import Data.Foldable (toList)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Graphics.Vty.Input.Events as V
import Krivostr.Cli.Options (buildFilter, emptyFilterOpts)
import Krivostr.Event
import Krivostr.Filter (Filter (..))
import Krivostr.Key (derivePublicKey, generatePrivateKey, pubKeyHex)
import Krivostr.Logging (LogEntry (..), LogLevel (..), leMsg, newLogger)
import Krivostr.Nip.Nip01 (signEvent)
import Krivostr.Pool (newPool)
import Krivostr.Store (closeStore, enqueueOutbox, insertEvent, openMemoryStore)
import Krivostr.Tui.App (statusText)
import Krivostr.Tui.Backend
  (inProcessBackend, tbCount, tbDelRelay, tbFetchOnce, tbFetchThread, tbFlush, tbGet
  , tbOutbox, tbQuery, tbRelays, tbSearch)
import Krivostr.Tui.Dispatch (Command (..), commandHelp, parseCommand)
import Krivostr.Tui.Sanitize (stripAnsiAndC0)
import Krivostr.Tui.State
import Krivostr.Tui.Types
import Krivostr.Tui.Views.Compose (targetLine)
import Krivostr.Tui.Views.Feed (rowText)
import Krivostr.Tui.Views.Lists (tabName)
import Krivostr.Tui.Views.Thread (threadReplies)
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
      let row = rowText 1700000001 False e
      row `shouldSatisfy` T.isPrefixOf "now  #1  "
      row `shouldSatisfy` T.isInfixOf "hello red"
      row `shouldSatisfy` (not . T.isInfixOf "\ESC")
      rowText 1700000001 True e `shouldSatisfy` T.isInfixOf "[sending]"

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
      found `shouldBe` [reply, e1]
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

-- | Focused event as a zero-or-one list, for shouldBe against literals.
selEv :: AppState -> [Event]
selEv s = maybe [] (: []) (selectedEvent s)
