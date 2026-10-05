{-# LANGUAGE OverloadedStrings #-}

-- | NIP-25 reactions and NIP-18 reposts.
--
-- Reactions count votes per event id; reposts embed the original as JSON and
-- cite it with @e@, while quotes cite with @q@ so they stay out of the
-- reply thread.
module Nip25Spec (nip25Spec) where

import Data.Text (Text)
import Krivostr.Event
import Krivostr.Nip.Nip18
import Krivostr.Nip.Nip25
import Test.Hspec

reaction :: Text -> [[Text]] -> Event
reaction content tags =
  Event
    { evId = "reaction"
    , evPubkey = "reactor"
    , evCreatedAt = 1700000000
    , evKind = 7
    , evTags = tags
    , evContent = content
    , evSig = "sig"
    }

repost :: Int -> Text -> [[Text]] -> Event
repost kind content tags =
  Event
    { evId = "repost"
    , evPubkey = "reposter"
    , evCreatedAt = 1700000000
    , evKind = kind
    , evTags = tags
    , evContent = content
    , evSig = "sig"
    }

target :: Event
target =
  Event
    { evId = "target-id"
    , evPubkey = "target-author"
    , evCreatedAt = 1699999999
    , evKind = 1
    , evTags = []
    , evContent = "original note"
    , evSig = "sig"
    }

nip25Spec :: Spec
nip25Spec = describe "NIP-25 reactions" $ do
  describe "reactionOf" $ do
    it "parses e, p and k tags" $
      reactionOf (reaction "+" [["e", "target-id", "wss://r"], ["p", "alice"], ["k", "1"]])
        `shouldBe` Just (Reaction "target-id" "alice" (Just 1) "+")

    it "defaults the kind to Nothing without a k tag" $
      reactionOf (reaction "+" [["e", "target-id"], ["p", "alice"]])
        `shouldBe` Just (Reaction "target-id" "alice" Nothing "+")

    it "rejects non-kind-7 events" $
      reactionOf target `shouldBe` Nothing

    it "rejects a kind 7 without an e tag" $
      reactionOf (reaction "+" [["p", "alice"]]) `shouldBe` Nothing

    it "rejects a malformed k tag" $
      reactionOf (reaction "+" [["e", "target-id"], ["k", "many"]])
        `shouldBe` Just (Reaction "target-id" "" Nothing "+")

  describe "isLike / isDislike" $ do
    it "reads + as a like" $
      isLike (reaction "+" [["e", "x"]]) `shouldBe` True

    it "reads an emoji as a like" $
      isLike (reaction "\10084" [["e", "x"]]) `shouldBe` True

    it "reads - as a dislike and not a like" $ do
      isDislike (reaction "-" [["e", "x"]]) `shouldBe` True
      isLike (reaction "-" [["e", "x"]]) `shouldBe` False

    it "reads empty content as neither" $ do
      isLike (reaction "" [["e", "x"]]) `shouldBe` False
      isDislike (reaction "" [["e", "x"]]) `shouldBe` False

  describe "buildReactionTags" $
    it "emits e, p and k" $
      buildReactionTags "target-id" "wss://r" "alice" 1
        `shouldBe` [["e", "target-id", "wss://r"], ["p", "alice"], ["k", "1"]]

  describe "countReactions" $
    it "counts likes and dislikes per event id" $
      countReactions
        [ reaction "+" [["e", "a"]]
        , reaction "\10084" [["e", "a"]]
        , reaction "-" [["e", "a"]]
        , reaction "+" [["e", "b"]]
        , reaction "+" []
        ]
        `shouldBe` [("a", 2, 1), ("b", 1, 0)]

  describe "NIP-18 reposts" $ do
    it "parses a kind 6 with e and p" $
      repostOf (repost 6 "" [["e", "target-id", "wss://r"], ["p", "alice"]])
        `shouldBe` Just (Repost "target-id" "alice" (Just 1))

    it "parses a kind 16 with its k tag" $
      repostOf (repost 16 "" [["e", "art-id"], ["p", "bob"], ["k", "30023"]])
        `shouldBe` Just (Repost "art-id" "bob" (Just 30023))

    it "rejects other kinds and tagless reposts" $ do
      repostOf target `shouldBe` Nothing
      repostOf (repost 6 "" []) `shouldBe` Nothing

    it "quotes with q and never with e" $ do
      let q = target {evTags = [["q", "target-id", "wss://r"]]}
      quoteOf q `shouldBe` Just (Quote "target-id" "wss://r")
      isQuote q `shouldBe` True
      quoteOf target `shouldBe` Nothing
      quoteOf (repost 6 "" [["q", "target-id"]]) `shouldBe` Nothing

    it "builds kind-6 tags without k and generic tags with k" $ do
      buildRepostTags "target-id" "wss://r" "alice" 1
        `shouldBe` [["e", "target-id", "wss://r"], ["p", "alice"]]
      buildRepostTags "art-id" "wss://r" "bob" 30023
        `shouldBe` [["e", "art-id", "wss://r"], ["p", "bob"], ["k", "30023"]]

    it "builds quote tags with q" $
      buildQuoteTags "target-id" "wss://r" `shouldBe` [["q", "target-id", "wss://r"]]

    it "embeds the original as JSON and reads it back" $
      embeddedOriginal (embedOriginal target) `shouldBe` Just target
