{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main (main) where

import Test.Hspec
import Test.QuickCheck
import qualified Data.ByteString as BS
import Control.Concurrent.STM
import Control.Monad (forM_, replicateM)
import Data.Either (isLeft, isRight)
import Data.Aeson (eitherDecodeStrict, encode, object, (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import qualified Database.SQLite3 as SQLite
import System.IO.Temp (withSystemTempDirectory)
import Krivostr.Cli
  ( FilterOpts (..)
  , csvField
  , isHex64
  , parseKind
  , parseTag
  , parseWhen
  , renderCsv
  , resolveAuthor
  , resolveTime
  , substitute
  , TimeSpec (..)
  )
import Krivostr.Cli.Nostr (decryptNip04, encryptNip04)
import Krivostr.Cli.Render (oneLine, relativeTime, renderEvent, renderEventBlock, shortHex)
import Krivostr.Event
import Krivostr.Filter
import Krivostr.Key
import Krivostr.Logging
import Krivostr.Bridge (BridgeState (..), ClientState (..), handleClientMsg, maxRetries, parseClient, retryRelays)
import Krivostr.Pool (BroadcastFailure (..), broadcastEvent, newPool)
import qualified Data.Map.Strict as M
import Krivostr.Nip.Nip01
import Krivostr.Nip.Nip42
import Krivostr.Relay (parseUrl)
import Krivostr.Store
import Krivostr.Wire
import Data.Aeson (Value, toJSON)
import Data.Aeson.Types (parseEither)

-- ── Fixtures ───────────────────────────────────────────────────

-- | Timestamps are fixed by default so that ids are reproducible.
mkSigned :: PrivateKey -> Int -> Text -> Event
mkSigned sk kind content =
  mkSignedAt sk (1700000000 + fromIntegral kind) kind content

-- | Build and sign an event with an explicit timestamp. The eviction tests need
-- this: overriding 'evCreatedAt' on an already-signed event would change the
-- serialized form and invalidate the signature.
mkSignedAt :: PrivateKey -> POSIXTime -> Int -> Text -> Event
mkSignedAt sk created kind content =
  signEvent sk Event
    { evId = ""
    , evPubkey = ""
    , evCreatedAt = created
    , evKind = kind
    , evTags = []
    , evContent = content
    , evSig = ""
    }

-- ── Tests ──────────────────────────────────────────────────────

main :: IO ()
main = hspec $ do
  describe "Store" $ do
    it "round-trips an event" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      let e = mkSigned sk 1 "hello"
      insertEvent st e `shouldReturn` Inserted
      fetched <- getEventById st (evId e)
      fetched `shouldSatisfy` (== Just e)
      closeStore st

    it "tells a duplicate from a write" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      let e = mkSigned sk 1 "hello"
      insertEvent st e `shouldReturn` Inserted
      insertEvent st e `shouldReturn` Duplicate
      n <- countEvents st
      n `shouldBe` 1
      closeStore st

    it "queues, dequeues oldest-first, and removes" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      let a = mkSignedAt sk 1000 1 "first"
          b = mkSignedAt sk 2000 1 "second"
      outboxCount st `shouldReturn` 0
      enqueueOutbox st a
      enqueueOutbox st b
      enqueueOutbox st a
      outboxCount st `shouldReturn` 2
      map evContent <$> dequeueOutbox st 10 `shouldReturn` ["first", "second"]
      removeOutbox st (evId a)
      outboxCount st `shouldReturn` 1
      map evContent <$> dequeueOutbox st 10 `shouldReturn` ["second"]
      closeStore st

    it "remembers, lists, and forgets relays" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      getRelayConfig st `shouldReturn` []
      addRelayConfig st "wss://b.example"
      addRelayConfig st "wss://a.example"
      addRelayConfig st "wss://a.example"
      getRelayConfig st `shouldReturn` ["wss://b.example", "wss://a.example"]
      removeRelayConfig st "wss://b.example"
      removeRelayConfig st "wss://never-there.example"
      getRelayConfig st `shouldReturn` ["wss://a.example"]
      closeStore st

    it "refuses a forged event and stores nothing" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      let e = mkSigned sk 1 "hello"
      insertEvent st e {evContent = "forged"} `shouldReturn` InvalidSignature
      insertEvent st e {evSig = T.replicate 128 "0"} `shouldReturn` InvalidSignature
      getEventById st (evId e) `shouldReturn` Nothing
      countEvents st `shouldReturn` 0
      closeStore st

    it "filters by kind" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      -- Content must differ per row: event ids are content addresses, so three
      -- identical kind-1 events are one row and INSERT OR IGNORE collapses them.
      forM_ (zip [1, 1, 1, 7] [1 .. 4 :: Int]) $ \(k, i) ->
        insertEvent st (mkSigned sk k (T.pack ("x" <> show i)))
      rows <- queryEvents st (onlyKinds [1])
      length rows `shouldBe` 3
      closeStore st

    it "respects limit" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      forM_ [1..10] $ \i -> insertEvent st (mkSigned sk 1 (T.pack (show i)))
      rows <- queryEvents st (empty { fLimit = Just 3 })
      length rows `shouldBe` 3
      closeStore st

    it "evicts expired non-persistent kinds" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      now <- getPOSIXTime
      let old = mkSignedAt sk (now - 40 * 86400) 1 "old"
      insertEvent st old
      removed <- evictExpired st
      removed `shouldBe` 1
      closeStore st

    it "keeps persistent kinds forever" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      now <- getPOSIXTime
      forM_ [0, 3, 4, 1059, 10002] $ \k -> do
        let e = mkSignedAt sk (now - 400 * 86400) k "x"
        insertEvent st e
      removed <- evictExpired st
      removed `shouldBe` 0
      n <- countEvents st
      n `shouldBe` 5
      closeStore st

    it "reports stats" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      forM_ (zip [1, 1, 7] [1 .. 3 :: Int]) $ \(k, i) ->
        insertEvent st (mkSigned sk k (T.pack ("x" <> show i)))
      stats <- storeStats st
      ssTotal stats `shouldBe` 3
      length (ssByKind stats) `shouldBe` 2
      closeStore st

    it "persists across reopen" $
      withSystemTempDirectory "krivostr" $ \dir -> do
        lg <- newLogger Error
        sk <- generatePrivateKey
        let e = mkSigned sk 1 "persisted"
            path = dir <> "/events.db"
        st1 <- openStore lg path
        insertEvent st1 e
        closeStore st1
        st2 <- openStore lg path
        n <- countEvents st2
        n `shouldBe` 1
        closeStore st2

  describe "Relay.parseUrl" $ do
    it "parses wss with port" $
      parseUrl "wss://relay.example:8443/path"
        `shouldBe` ("relay.example", 8443, "/path")

    it "defaults to 443" $
      parseUrl "wss://relay.example/path"
        `shouldBe` ("relay.example", 443, "/path")

    it "handles missing path" $
      parseUrl "wss://relay.example"
        `shouldBe` ("relay.example", 443, "/")

    it "accepts ws:// scheme" $
      parseUrl "ws://localhost:8080"
        `shouldBe` ("localhost", 8080, "/")

  describe "Logging" $ do
    it "respects minimum level" $ do
      lg <- newLogger Warn
      emit lg Debug "hidden"
      emit lg Info  "hidden"
      emit lg Error "shown"
      entries <- drainQueue lg
      map leMsg entries `shouldBe` ["shown"]

    it "honours withLevel override" $ do
      lg <- newLogger Error
      let lgd = withLevel lg Debug
      emit lgd Debug "visible"
      entries <- drainQueue lg
      length entries `shouldBe` 1

  describe "Wire" $ do
    it "encodes REQ with the filters as trailing elements" $
      -- The UI sends ["REQ", id, filter] and relays demand exactly that shape.
      encode (encodeClient (CReq "s1" [onlyKinds [1]]))
        `shouldBe` "[\"REQ\",\"s1\",{\"kinds\":[1]}]"
    it "encodes CLOSE" $ do
      let v = encodeClient (CClose "s1")
      show v `shouldContain` "CLOSE"

  describe "NIP-42 AUTH" $ do
    let sk = either (error "bad key") id (importHex "0000000000000000000000000000000000000000000000000000000000000003")
        url = "wss://relay.example.com"
        challenge = "krivostr-test-challenge"

    it "decodes an AUTH frame into a challenge" $
      parseEither decodeRelay (toJSON (["AUTH", challenge] :: [Text]))
        `shouldBe` Right (RChallenge challenge)

    it "decodes an AUTH frame with a non-string challenge as an error" $
      parseEither decodeRelay (object ["AUTH" .= (7 :: Int)])
        `shouldSatisfy` Data.Either.isLeft

    it "builds an event the validator accepts" $ do
      let ev = Krivostr.Nip.Nip42.buildAuthEvent sk url challenge 1700000000
      Krivostr.Nip.Nip42.validateAuthEvent url challenge 1700000000 300 ev
        `shouldBe` Right ()

    it "rejects an event for a different relay" $ do
      let ev = Krivostr.Nip.Nip42.buildAuthEvent sk url challenge 1700000000
      Krivostr.Nip.Nip42.validateAuthEvent "wss://other.example" challenge 1700000000 300 ev
        `shouldSatisfy` Data.Either.isLeft

    it "rejects an event answering a different challenge" $ do
      let ev = Krivostr.Nip.Nip42.buildAuthEvent sk url challenge 1700000000
      Krivostr.Nip.Nip42.validateAuthEvent url "other-challenge" 1700000000 300 ev
        `shouldSatisfy` Data.Either.isLeft

    it "rejects an event that is too old" $ do
      -- Built a thousand seconds in the past, validated against a ten second
      -- window: the age is what must exceed the window, not the timestamp.
      let ev = Krivostr.Nip.Nip42.buildAuthEvent sk url challenge 1700000000
      Krivostr.Nip.Nip42.validateAuthEvent url challenge 1700001000 10 ev
        `shouldSatisfy` Data.Either.isLeft

    it "rejects an event with no signature" $ do
      let ev = Krivostr.Nip.Nip42.buildAuthEvent sk url challenge 1700000000
      Krivostr.Nip.Nip42.validateAuthEvent url challenge 1700000000 300 (ev {evSig = ""})
        `shouldSatisfy` Data.Either.isLeft

  describe "Bridge protocol" $ do
    let parsed :: BS.ByteString -> Maybe ClientMessage
        parsed = either (const Nothing) (parseMaybe parseClient) . eitherDecodeStrict

    it "parses the variadic REQ the UI sends" $
      parsed "[\"REQ\",\"s1\",{\"kinds\":[1]}]"
        `shouldBe` Just (CReq "s1" [onlyKinds [1]])

    it "parses a REQ carrying several filters" $
      parsed "[\"REQ\",\"s1\",{\"kinds\":[1]},{\"kinds\":[2]}]"
        `shouldBe` Just (CReq "s1" [onlyKinds [1], onlyKinds [2]])

    it "round-trips its own REQ encoding" $
      parseMaybe parseClient (encodeClient (CReq "s1" [onlyKinds [1], onlyKinds [2]]))
        `shouldBe` Just (CReq "s1" [onlyKinds [1], onlyKinds [2]])

    it "rejects a REQ with no filters" $
      parsed "[\"REQ\",\"s1\"]" `shouldBe` Nothing

    it "parses CLOSE" $
      parsed "[\"CLOSE\",\"s1\"]" `shouldBe` Just (CClose "s1")

    it "parses COUNT with filters as trailing elements" $
      parsed "[\"COUNT\",\"c1\",{\"kinds\":[1]}]"
        `shouldBe` Just (CCount "c1" [onlyKinds [1]])

    it "round-trips its own COUNT encoding" $
      parseMaybe parseClient (encodeClient (CCount "c1" [onlyKinds [1], tagEq "e" ["x"]]))
        `shouldBe` Just (CCount "c1" [onlyKinds [1], tagEq "e" ["x"]])

    it "rejects a COUNT with no filters" $
      parsed "[\"COUNT\",\"c1\"]" `shouldBe` Nothing

  describe "Bridge outbox" $ do
    let withBridge f = do
          lg <- newLogger Error
          st <- openMemoryStore lg
          pool <- newPool lg (const (pure ()))
          clients <- newTVarIO M.empty
          nextId <- newTVarIO 0
          retries <- newTVarIO M.empty
          let bst = BridgeState lg pool st clients nextId retries
          outbox <- newTQueueIO
          subs <- newTVarIO M.empty
          f bst (ClientState 0 outbox subs) outbox st
        drainOutbox outbox = atomically $ do
          empty <- isEmptyTQueue outbox
          if empty then pure [] else (:) <$> readTQueue outbox <*> pure []

    it "stores, queues, and accepts when no relay is connected" $ do
      sk <- generatePrivateKey
      let e = mkSigned sk 1 "offline note"
      withBridge $ \bst cs outbox st -> do
        handleClientMsg bst cs (encodeClient (CEvent e))
        getEventById st (evId e) `shouldReturn` Just e
        outboxCount st `shouldReturn` 1
        frames <- drainOutbox outbox
        length frames `shouldBe` 1

    it "rejects forgeries without storing or queueing" $ do
      sk <- generatePrivateKey
      let e = (mkSigned sk 1 "hello") { evContent = "forged" }
      withBridge $ \bst cs outbox st -> do
        handleClientMsg bst cs (encodeClient (CEvent e))
        getEventById st (evId e) `shouldReturn` Nothing
        outboxCount st `shouldReturn` 0

  describe "Bridge retries" $ do
    it "counts attempts and gives up at the cap" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      pool <- newPool lg (const (pure ()))
      clients <- newTVarIO M.empty
      nextId <- newTVarIO 0
      retries <- newTVarIO (M.singleton "wss://dead.example" 0)
      let bst = BridgeState lg pool st clients nextId retries
      -- No relay answers (empty pool): attempts climb without persisting.
      retryRelays bst
      readTVarIO retries `shouldReturn` M.singleton "wss://dead.example" 1
      getRelayConfig st `shouldReturn` []
      atomically $ writeTVar retries (M.singleton "wss://dead.example" maxRetries)
      retryRelays bst
      readTVarIO retries `shouldReturn` M.empty
      getRelayConfig st `shouldReturn` []
      closeStore st

  describe "Pool" $ do
    it "fails fast with an empty pool" $ do
      lg <- newLogger Error
      pool <- newPool lg (const (pure ()))
      sk <- generatePrivateKey
      broadcastEvent pool (mkSigned sk 1 "nowhere to go") 1000
        `shouldReturn` Left NoRelays

  describe "Key" $ do
    it "generates distinct keys" $ do
      sk1 <- generatePrivateKey
      sk2 <- generatePrivateKey
      exportHex sk1 `shouldNotBe` exportHex sk2
    it "hex round-trips" $ do
      sk <- generatePrivateKey
      importHex (exportHex sk) `shouldBe` Right sk
    it "rejects garbage" $
      importHex "0xDEADBEEF" `shouldSatisfy` isLeft

  describe "Store search (FTS5)" $ do
    it "answers a search filter from the FTS index" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      insertEvent st (mkSigned sk 1 "the quick brown fox")
      insertEvent st (mkSigned sk 1 "something unrelated")
      hits <- queryEvents st (empty { fSearch = Just "brown fox" })
      map evContent hits `shouldBe` ["the quick brown fox"]
      closeStore st

    it "combines search with kinds and limit" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      insertEvent st (mkSigned sk 1 "shared word one")
      insertEvent st (mkSigned sk 7 "shared word two")
      kinds <- queryEvents st (empty { fSearch = Just "shared", fKinds = Just [7] })
      map evKind kinds `shouldBe` [7]
      limited <- queryEvents st (empty { fSearch = Just "shared", fLimit = Just 1 })
      length limited `shouldBe` 1
      closeStore st

    it "counts matches ignoring the limit" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      forM_ [1..5] $ \i -> insertEvent st (mkSigned sk 1 (T.pack ("counted " ++ show (i :: Int))))
      insertEvent st (mkSigned sk 7 "counted reaction")
      countMatching st (empty { fKinds = Just [1], fLimit = Just 2 }) `shouldReturn` 5
      countMatching st (empty { fSearch = Just "counted" }) `shouldReturn` 6
      countMatching st (empty { fKinds = Just [7], fTags = [("p", ["nobody"])] }) `shouldReturn` 0
      closeStore st

    it "indexes what is inserted and finds it" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      let e = mkSigned sk 1 "the quick brown fox"
      insertEvent st e
      hits <- searchEvents st "brown" False Nothing Nothing 10
      map evContent hits `shouldBe` ["the quick brown fox"]
      closeStore st

    it "finds nothing for a word that is not there" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      insertEvent st (mkSigned sk 1 "the quick brown fox")
      hits <- searchEvents st "aardvark" False Nothing Nothing 10
      hits `shouldBe` []
      closeStore st

    it "requires every word by default and accepts any word with --any" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      insertEvent st (mkSigned sk 1 "hello world")
      both <- searchEvents st "hello world" False Nothing Nothing 10
      one <- searchEvents st "hello world" True Nothing Nothing 10
      neither <- searchEvents st "hello goodbye" False Nothing Nothing 10
      map evContent both `shouldBe` ["hello world"]
      map evContent one `shouldBe` ["hello world"]
      neither `shouldBe` []
      closeStore st

    -- The bug this covers: `case kinds of` had no Nothing branch, so every
    -- search without --kind threw a pattern-match failure at runtime.
    it "searches with no kind filter at all" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      forM_ [1, 7] $ \k -> insertEvent st (mkSigned sk k "shared word")
      noFilter <- searchEvents st "shared" False Nothing Nothing 10
      kinds <- searchEvents st "shared" False (Just [1, 7]) Nothing 10
      onlyOne <- searchEvents st "shared" False (Just [1]) Nothing 10
      emptyKinds <- searchEvents st "shared" False (Just []) Nothing 10
      length noFilter `shouldBe` 2
      length kinds `shouldBe` 2
      map evKind onlyOne `shouldBe` [1]
      length emptyKinds `shouldBe` 2
      closeStore st

    it "filters search by author" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk1 <- generatePrivateKey
      sk2 <- generatePrivateKey
      insertEvent st (mkSigned sk1 1 "shared word")
      insertEvent st (mkSigned sk2 1 "shared word")
      let mine = pubKeyHex (derivePublicKey sk1)
      hits <- searchEvents st "shared" False Nothing (Just mine) 10
      map evPubkey hits `shouldBe` [mine]
      closeStore st

    it "respects the search limit" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      forM_ [1 .. 5] $ \i -> insertEvent st (mkSigned sk 1 (T.pack ("hit " <> show i)))
      hits <- searchEvents st "hit" False Nothing Nothing 2
      length hits `shouldBe` 2
      closeStore st

    it "drops deleted events from the index" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      let e = mkSigned sk 1 "temporary word"
      insertEvent st e
      before <- searchEvents st "temporary" False Nothing Nothing 10
      length before `shouldBe` 1
      deleteEvent st (evId e)
      after <- searchEvents st "temporary" False Nothing Nothing 10
      after `shouldBe` []
      closeStore st

    it "rebuilds the index from the events table" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      insertEvent st (mkSigned sk 1 "rebuilt word")
      n <- reindexEvents st
      n `shouldBe` 1
      hits <- searchEvents st "rebuilt" False Nothing Nothing 10
      length hits `shouldBe` 1
      closeStore st

    -- A store created before this feature has events but no index; the search
    -- command must notice and rebuild rather than reporting zero results.
    it "rebuilds when the index is behind the events table" $
      withSystemTempDirectory "krivostr" $ \dir -> do
        lg <- newLogger Error
        sk <- generatePrivateKey
        let path = dir <> "/events.db"
        st1 <- openStore lg path
        insertEvent st1 (mkSigned sk 1 "stale word")
        closeStore st1
        st2 <- openStore lg path
        _ <- reindexEvents st2
        -- Simulate the index losing rows the way an old store would.
        wipeIndex path
        available <- searchAvailable st2
        rebuilt <- reindexIfStale st2
        available `shouldBe` True
        rebuilt `shouldBe` True
        hits <- searchEvents st2 "stale" False Nothing Nothing 10
        length hits `shouldBe` 1
        closeStore st2

    it "quotes user input so punctuation cannot reach FTS5 as syntax" $ do
      searchQuery False "c++"  `shouldBe` Just "\"c++\""
      searchQuery False "foo bar" `shouldBe` Just "\"foo\" AND \"bar\""
      searchQuery True  "foo bar" `shouldBe` Just "\"foo\" OR \"bar\""
      searchQuery False "NOT AND OR" `shouldBe` Just "\"NOT\" AND \"AND\" AND \"OR\""
      -- Nothing searchable: no MATCH expression to run.
      searchQuery False "..." `shouldBe` Nothing
      searchQuery False ""    `shouldBe` Nothing
      -- A quote cannot be smuggled in to break out of the phrase.
      searchQuery False "a\"b" `shouldBe` Just "\"a b\""

  describe "Key.sharedSecret" $ do
    it "agrees in both directions" $ do
      sk1 <- generatePrivateKey
      sk2 <- generatePrivateKey
      let p1 = derivePublicKey sk1
          p2 = derivePublicKey sk2
      sharedSecret sk1 p2 `shouldBe` sharedSecret sk2 p1

    -- The key constructors are not exported, so the "not on the curve" branch
    -- of sharedSecret is only reachable through this parser.
    it "rejects a public key that is not a curve point" $ do
      publicKeyFromBytes (BS.replicate 32 0xff) `shouldBe` Nothing
      publicKeyFromBytes (BS.replicate 31 0x02) `shouldBe` Nothing
      publicKeyFromBytes BS.empty `shouldBe` Nothing

    it "is a 32-byte secret and is stable" $ do
      sk1 <- generatePrivateKey
      sk2 <- generatePrivateKey
      let ss1 = sharedSecret sk1 (derivePublicKey sk2)
          ss2 = sharedSecret sk1 (derivePublicKey sk2)
      ss1 `shouldBe` ss2
      fmap BS.length ss1 `shouldBe` Just 32

    it "differs per peer" $ do
      sk1 <- generatePrivateKey
      sk2 <- generatePrivateKey
      sk3 <- generatePrivateKey
      let p2 = derivePublicKey sk2
          p3 = derivePublicKey sk3
      sharedSecret sk1 p2 `shouldNotBe` sharedSecret sk1 p3

  describe "NIP-04" $ do
    it "round-trips a message between two keys" $ do
      sk1 <- generatePrivateKey
      sk2 <- generatePrivateKey
      let pk1 = derivePublicKey sk1
          pk2 = derivePublicKey sk2
      enc <- encryptNip04 sk1 pk2 "meet at 8"
      case enc of
        Left e   -> expectationFailure ("encrypt: " <> e)
        Right ct -> do
          dec <- decryptNip04 sk2 pk1 ct
          dec `shouldBe` Right "meet at 8"

    it "cannot be read by a third party" $ do
      sk1 <- generatePrivateKey
      sk2 <- generatePrivateKey
      sk3 <- generatePrivateKey
      enc <- encryptNip04 sk1 (derivePublicKey sk2) "secret"
      case enc of
        Left e   -> expectationFailure ("encrypt: " <> e)
        Right ct -> do
          dec <- decryptNip04 sk3 (derivePublicKey sk1) ct
          dec `shouldSatisfy` isLeft

    it "round-trips text that is not ascii, and an empty message" $ do
      sk1 <- generatePrivateKey
      let pk1 = derivePublicKey sk1
      forM_ ["", "grüße, 日本語 \n newline"] $ \msg -> do
        enc <- encryptNip04 sk1 pk1 msg
        case enc of
          Left e   -> expectationFailure ("encrypt: " <> e)
          Right ct -> do
            dec <- decryptNip04 sk1 pk1 ct
            dec `shouldBe` Right msg

    it "refuses a payload with no iv" $ do
      sk1 <- generatePrivateKey
      let pk1 = derivePublicKey sk1
      r <- decryptNip04 sk1 pk1 "notbase64?nothing"
      r `shouldSatisfy` isLeft

    it "refuses a payload whose iv is not base64" $ do
      sk1 <- generatePrivateKey
      let pk1 = derivePublicKey sk1
      r <- decryptNip04 sk1 pk1 "AAAA?iv=!!!"
      r `shouldSatisfy` isLeft

  describe "Render" $ do
    it "renders one line with age, kind, and author" $ do
      sk <- generatePrivateKey
      let e = mkSigned sk 1 "hello world"
      renderEvent False True 1700000001 e `shouldSatisfy` T.isInfixOf "hello world"
      renderEvent False True 1700000001 e `shouldSatisfy` T.isInfixOf "#1"

    it "hides sensitive content unless revealed" $ do
      sk <- generatePrivateKey
      let e = (mkSigned sk 1 "secret body") { evTags = [["content-warning", "nudity"]] }
      renderEvent False False 1700000001 e `shouldSatisfy` T.isInfixOf "sensitive: nudity"
      renderEvent False False 1700000001 e `shouldSatisfy` (not . T.isInfixOf "secret body")
      renderEvent False True 1700000001 e `shouldSatisfy` T.isInfixOf "secret body"

    it "hides sensitive bodies in block rendering" $ do
      sk <- generatePrivateKey
      let e = (mkSigned sk 1 "secret body") { evTags = [["content-warning"]] }
      renderEventBlock False False 1700000001 e `shouldSatisfy` T.isInfixOf "[content hidden"
      renderEventBlock False True 1700000001 e `shouldSatisfy` T.isInfixOf "secret body"

    it "formats relative ages" $ do
      relativeTime 1700000000 1699999990 `shouldBe` "now"
      relativeTime 1700000000 1699999900 `shouldSatisfy` T.isPrefixOf "1m"
      relativeTime 1700000000 1699913600 `shouldSatisfy` T.isPrefixOf "1d"

    it "shortens hex and single-lines text" $ do
      shortHex 8 (T.replicate 64 "a") `shouldSatisfy` T.isPrefixOf "aaaaaaaa"
      oneLine 100 "a\nb" `shouldBe` "a b"

  describe "Cli helpers" $ do
    it "parses relative times" $ do
      agoSeconds "90s" `shouldBe` Just 90
      agoSeconds "30m" `shouldBe` Just 1800
      agoSeconds "2h"  `shouldBe` Just 7200
      agoSeconds "7d"  `shouldBe` Just 604800
      agoSeconds "1w"  `shouldBe` Just 604800
      agoSeconds "6mo" `shouldBe` Just (6 * 2592000)
      agoSeconds "1y"  `shouldBe` Just 31536000

    it "parses a date and a unix timestamp as absolute" $ do
      case parseWhen "2024-01-02" of
        Right (At t) -> t `shouldBe` 1704153600
        _            -> expectationFailure "2024-01-02 did not parse as a date"
      case parseWhen "1704153600" of
        Right (At t) -> t `shouldBe` 1704153600
        _            -> expectationFailure "1704153600 did not parse as a timestamp"
      parseWhen "not a time" `shouldSatisfy` isLeft
      parseWhen "12q"         `shouldSatisfy` isLeft

    it "resolves a relative time into the past" $ do
      before <- getPOSIXTime
      t      <- resolveTime =<< orFail (parseWhen "1h")
      after  <- getPOSIXTime
      (after - 3590) `shouldSatisfy` (>= t)
      t `shouldSatisfy` (<= before - 3590)

    it "names kinds" $ do
      parseKind "note"     `shouldBe` Right 1
      parseKind "dm"       `shouldBe` Right 4
      parseKind "metadata" `shouldBe` Right 0
      parseKind "relays"   `shouldBe` Right 10002
      parseKind "42"       `shouldBe` Right 42
      parseKind "-1"       `shouldSatisfy` isLeft
      parseKind "99999999999999" `shouldSatisfy` isLeft

    it "splits tag filters" $ do
      parseTag "e=abc" `shouldBe` Right ("e", "abc")
      parseTag "t="    `shouldBe` Right ("t", "")
      parseTag "noequals" `shouldSatisfy` isLeft

    it "recognises hex pubkeys" $ do
      isHex64 (T.replicate 64 "a") `shouldBe` True
      isHex64 "abc"                 `shouldBe` False
      isHex64 (T.replicate 63 "a")  `shouldBe` False

    it "escapes csv only when it has to" $ do
      csvField "plain"      `shouldBe` "plain"
      csvField "a,b"        `shouldBe` "\"a,b\""
      csvField "say \"hi\"" `shouldBe` "\"say \"\"hi\"\"\""
      csvField "two\nlines" `shouldBe` "\"two\nlines\""

    it "renders csv with a header and one row per event" $ do
      sk <- generatePrivateKey
      let e = (mkSigned sk 1 "hello, world") { evTags = [["t", "bitcoin"], ["e", "abc", "wss://x"]] }
      case lines (renderCsv [e]) of
        [header, row] -> do
          header `shouldBe` "id,pubkey,created_at,kind,tags,content,sig"
          row `shouldContain` "\"hello, world\""
          row `shouldContain` "t=bitcoin e=abc|wss://x"
        other -> expectationFailure ("expected 2 csv lines, got " <> show (length other))

    it "substitutes the documented placeholders" $ do
      sk <- generatePrivateKey
      let e = (mkSigned sk 7 "body text") { evTags = [["t", "x"]] }
      substitute "kind={kind} author={author} content={content}" e
        `shouldBe` "kind=7 author=" <> evPubkey e <> " content=body text"
      T.unpack (substitute "{json}" e) `shouldContain` T.unpack (evId e)

  describe "resolveAuthor" $ do
    it "accepts a hex pubkey unchanged" $ do
      sk <- generatePrivateKey
      let hex = pubKeyHex (derivePublicKey sk)
      resolveAuthor (T.unpack hex) `shouldBe` Right hex

    it "accepts an npub" $ do
      sk <- generatePrivateKey
      let hex = pubKeyHex (derivePublicKey sk)
      resolveAuthor (T.unpack (exportNpub (derivePublicKey sk))) `shouldBe` Right hex

    it "rejects anything else" $ do
      resolveAuthor "alice" `shouldSatisfy` isLeft
      resolveAuthor "" `shouldSatisfy` isLeft


-- | Seconds for a relative spec; Nothing if it is absolute or unreadable.
agoSeconds :: String -> Maybe Integer
agoSeconds s = case parseWhen s of
  Right (Ago n) -> Just n
  _            -> Nothing

-- | 'orDie' for a pure Either.
orFail :: Either String a -> IO a
orFail (Right a) = pure a
orFail (Left e)  = expectationFailure e >> error "unreachable"

-- | Empty the FTS table behind the store's back, which is what a database
-- written before this feature looks like.
wipeIndex :: FilePath -> IO ()
wipeIndex path = do
  conn <- SQLite.open (T.pack path)
  _ <- SQLite.exec conn "DELETE FROM events_fts"
  SQLite.close conn
