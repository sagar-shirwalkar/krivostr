{-# LANGUAGE OverloadedStrings #-}

-- | NIP-40 expiration tests.
--
-- The tag itself is trivial; these pin the decisions that are easy to get
-- wrong. In particular the boundary test: an event whose expiration equals the
-- current second is already expired, and a @<@ comparison would keep serving it
-- for one more second on every tick.
module Nip40Spec (nip40Spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime)
import Krivostr.Event
import Krivostr.Nip.Nip40
import Test.Hspec

-- | A note with no tags, built by the caller under test.
baseEvent :: Event
baseEvent =
  Event
    { evId = "abc"
    , evPubkey = "pub"
    , evCreatedAt = 1000000000
    , evKind = 1
    , evTags = []
    , evContent = "temporary"
    , evSig = "sig"
    }

withExpiration :: Text -> Event
withExpiration v = baseEvent {evTags = [["expiration", v]]}

at :: Integer -> POSIXTime
at = fromInteger

nip40Spec :: Spec
nip40Spec = describe "NIP-40 expiration" $ do
  describe "the tag" $ do
    it "is the tag name and a unix timestamp in seconds" $
      expirationTag (at 1600000000) `shouldBe` ["expiration", "1600000000"]

    it "reads back what it wrote" $
      expirationOf (baseEvent {evTags = [expirationTag (at 1600000000)]})
        `shouldBe` Just (at 1600000000)

    it "prepends the tag to an empty tag list" $
      buildExpirationTags (at 1600000000) [] `shouldBe` [["expiration", "1600000000"]]

    it "replaces an existing expiration rather than shadowing it" $ do
      let tags = buildExpirationTags (at 1700000000) [["expiration", "1600000000"]]
      length tags `shouldBe` 1
      expirationOf (baseEvent {evTags = tags}) `shouldBe` Just (at 1700000000)

    it "keeps unrelated tags" $
      buildExpirationTags (at 1700000000) [["t", "post"], ["p", "alice"]]
        `shouldBe` [ ["expiration", "1700000000"], ["t", "post"], ["p", "alice"] ]

  describe "parsing" $ do
    it "returns Nothing when the tag is absent" $
      expirationOf baseEvent `shouldBe` Nothing

    it "returns Nothing for an empty tag or a tag with no value" $ do
      expirationOf (baseEvent {evTags = [["expiration"]]}) `shouldBe` Nothing
      expirationOf (baseEvent {evTags = [["expiration", ""]]}) `shouldBe` Nothing

    it "rejects non-numeric, signed and padded values" $ do
      expirationOf (withExpiration "abc") `shouldBe` Nothing
      expirationOf (withExpiration "-1") `shouldBe` Nothing
      expirationOf (withExpiration "+1") `shouldBe` Nothing
      expirationOf (withExpiration " 1600000000") `shouldBe` Nothing
      expirationOf (withExpiration "1600000000 ") `shouldBe` Nothing
      expirationOf (withExpiration "1600000000.5") `shouldBe` Nothing
      expirationOf (withExpiration "1e9") `shouldBe` Nothing

    it "ignores extra elements after the value" $
      -- Trailing junk in the value is rejected, but extra tag elements are not
      -- part of the specified shape and must not change the reading.
      expirationOf (baseEvent {evTags = [["expiration", "1600000000", "extra"]]})
        `shouldBe` Just (at 1600000000)

    it "takes the first expiration when several are present" $
      expirationOf
        ( baseEvent
            { evTags = [ ["expiration", "1600000000"]
                       , ["expiration", "1700000000"]
                       ]
            }
        )
        `shouldBe` Just (at 1600000000)

  describe "isExpiredAt" $ do
    it "is False before the expiration" $
      isExpiredAt (at 1599999999) (withExpiration "1600000000") `shouldBe` False

    it "is True after the expiration" $
      isExpiredAt (at 1600000001) (withExpiration "1600000000") `shouldBe` True

    it "is True exactly at the expiration second" $
      -- The boundary that a strict @<@ would get wrong.
      isExpiredAt (at 1600000000) (withExpiration "1600000000") `shouldBe` True

    it "is False for a note with no expiration tag" $
      -- Relays may persist untagged events indefinitely.
      isExpiredAt (at 999999999999) baseEvent `shouldBe` False

    it "is False for an unparseable tag, leaving the decision to the caller" $
      -- Treating garbage as "expired at the epoch" would silently delete the
      -- note; treating it as never-expiring is the safe direction.
      isExpiredAt (at 1600000000) (withExpiration "not-a-timestamp")
        `shouldBe` False

  describe "filtering" $ do
    let events =
          [ withExpiration "1600000000"
          , baseEvent
          , withExpiration "1800000000"
          ]
        now = at 1700000000

    it "keeps unexpired notes and those without a tag" $
      keepUnexpired now events `shouldSatisfy` ((== 2) . length)

    it "drops only the expired note" $
      dropExpired now events `shouldSatisfy` ((== 1) . length)

    it "splits into both halves" $
      case filterExpired now events of
        (live, [onlyDead]) -> do
          length live `shouldBe` 2
          expirationOf onlyDead `shouldBe` Just (at 1600000000)
        (_, other) -> expectationFailure ("unexpected split: " ++ show (length other))

    it "keeps everything when nothing has expired" $ do
      keepUnexpired (at 1) events `shouldSatisfy` ((== 3) . length)
      dropExpired (at 1) events `shouldBe` []

    it "leaves an untagged note alone however far in the future" $
      -- The one event with no expiration tag is the one that always survives,
      -- so "everything expired" can never mean an empty keep list here.
      keepUnexpired (at 999999999999) events `shouldSatisfy` ((== 1) . length)

    it "drops every tagged note once they have all expired" $
      dropExpired (at 999999999999) events `shouldSatisfy` ((== 2) . length)
