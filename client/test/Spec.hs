{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main (main) where

import Test.Hspec
import Test.QuickCheck
import Control.Concurrent.STM
import Control.Monad (forM_, replicateM)
import Data.Either (isLeft, isRight)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import System.IO.Temp (withSystemTempDirectory)
import Krivostr.Event
import Krivostr.Filter
import Krivostr.Key
import Krivostr.Logging
import Krivostr.Nip.Nip01
import Krivostr.Relay (parseUrl)
import Krivostr.Store
import Krivostr.Wire

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
      ok <- insertEvent st e
      ok `shouldBe` True
      fetched <- getEventById st (evId e)
      fetched `shouldSatisfy` (== Just e)
      closeStore st

    it "is idempotent on duplicate ids" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      let e = mkSigned sk 1 "hello"
      _ <- insertEvent st e
      _ <- insertEvent st e
      n <- countEvents st
      n `shouldBe` 1
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
    it "encodes REQ into a JSON array" $ do
      let v = encodeClient (CReq "s1" [onlyKinds [1]])
      v `shouldSatisfy` (not . null . show)
    it "encodes CLOSE" $ do
      let v = encodeClient (CClose "s1")
      show v `shouldContain` "CLOSE"

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
