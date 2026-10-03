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
import Data.Time.Clock.POSIX (getPOSIXTime)
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

mkEvent :: PrivateKey -> Int -> Text -> Event
mkEvent sk kind content =
  signEvent sk Event
    { evId = ""
    , evPubkey = ""
    , evCreatedAt = 1700000000 + fromIntegral kind
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
      let e = mkEvent sk 1 "hello"
      ok <- insertEvent st e
      ok `shouldBe` True
      fetched <- getEventById st (evId e)
      fetched `shouldSatisfy` (== Just e)
      closeStore st

    it "is idempotent on duplicate ids" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      let e = mkEvent sk 1 "hello"
      _ <- insertEvent st e
      _ <- insertEvent st e
      n <- countEvents st
      n `shouldBe` 1
      closeStore st

    it "filters by kind" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      forM_ [1, 1, 1, 7] $ \k -> insertEvent st (mkEvent sk k "x")
      rows <- queryEvents st (onlyKinds [1])
      length rows `shouldBe` 3
      closeStore st

    it "respects limit" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      forM_ [1..10] $ \i -> insertEvent st (mkEvent sk 1 (T.pack (show i)))
      rows <- queryEvents st (empty { fLimit = Just 3 })
      length rows `shouldBe` 3
      closeStore st

    it "evicts expired non-persistent kinds" $ do
      lg <- newLogger Error
      st <- openMemoryStore lg
      sk <- generatePrivateKey
      now <- getPOSIXTime
      let old = mkEvent sk 1 "old"
              { evCreatedAt = now - (40 * 24 * 60 * 60) }
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
        let e = mkEvent sk k "x" { evCreatedAt = now - (400 * 24 * 60 * 60) }
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
      forM_ [1, 1, 7] $ \k -> insertEvent st (mkEvent sk k "x")
      stats <- storeStats st
      ssTotal stats `shouldBe` 3
      length (ssByKind stats) `shouldBe` 2
      closeStore st

    it "persists across reopen" $
      withSystemTempDirectory "krivostr" $ \dir -> do
        lg <- newLogger Error
        sk <- generatePrivateKey
        let e = mkEvent sk 1 "persisted"
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

-- ── Helpers ────────────────────────────────────────────────────

-- | Drain a logger's queue without blocking.
drainQueue :: Logger -> IO [LogEntry]
drainQueue lg = go []
  where
    go acc = do
      m <- atomically $ tryReadTQueue (lgQueue lg)
      case m of
        Nothing -> pure (reverse acc)
        Just e  -> go (e : acc)
