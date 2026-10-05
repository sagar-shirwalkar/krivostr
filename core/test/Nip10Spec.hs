{-# LANGUAGE OverloadedStrings #-}

-- | NIP-10 reply conventions.
--
-- Marked @e@ tags say what a note answers; positional order is only the
-- fallback for old events. The builder emits the marked form arranged so the
-- positional reading agrees.
module Nip10Spec (nip10Spec) where

import Data.Text (Text)
import Krivostr.Event
import Krivostr.Nip.Nip10
import Test.Hspec

note :: [[Text]] -> Event
note tags =
  Event
    { evId = "note"
    , evPubkey = "author"
    , evCreatedAt = 1700000000
    , evKind = 1
    , evTags = tags
    , evContent = "hi"
    , evSig = "sig"
    }

nip10Spec :: Spec
nip10Spec = describe "NIP-10 replies" $ do
  describe "threadOf" $ do
    it "reads marked root and reply tags" $
      threadOf (note [["e", "root-id", "wss://r", "root"], ["e", "parent-id", "", "reply"]])
        `shouldBe` Just (ThreadRef "root-id" "wss://r" (Just "parent-id") "")

    it "treats a lone root marker as a reply to the root" $
      threadOf (note [["e", "root-id", "", "root"]])
        `shouldBe` Just (ThreadRef "root-id" "" (Just "root-id") "")

    it "ignores mention markers" $
      threadOf (note [["e", "root-id", "", "root"], ["e", "other", "", "mention"]])
        `shouldBe` Just (ThreadRef "root-id" "" (Just "root-id") "")

    it "falls back to positional order without markers" $
      threadOf (note [["e", "root-id", "wss://a"], ["e", "parent-id", "wss://b"]])
        `shouldBe` Just (ThreadRef "root-id" "wss://a" (Just "parent-id") "wss://b")

    it "treats one positional e tag as root and parent at once" $
      threadOf (note [["e", "only", ""]])
        `shouldBe` Just (ThreadRef "only" "" (Just "only") "")

    it "finds no thread without e tags" $
      threadOf (note []) `shouldBe` Nothing

  describe "isReply / replyRoot / replyTo" $ do
    it "a bare note is not a reply" $
      isReply (note []) `shouldBe` False

    it "a marked reply reports root and parent" $ do
      let e = note [["e", "root-id", "", "root"], ["e", "parent-id", "", "reply"]]
      isReply e `shouldBe` True
      replyRoot e `shouldBe` Just "root-id"
      replyTo e `shouldBe` Just "parent-id"

  describe "mentionedPubkeys" $
    it "lists p tags in wire order" $
      mentionedPubkeys (note [["p", "alice"], ["e", "x"], ["p", "bob"]])
        `shouldBe` ["alice", "bob"]

  describe "buildReplyTags" $ do
    it "emits one e tag when the parent is the root" $
      buildReplyTags "root" "wss://r" "alice" "root" "wss://r" "alice"
        `shouldBe` [["e", "root", "wss://r", "root"], ["p", "alice"]]

    it "emits root and reply with both authors" $
      buildReplyTags "root" "wss://a" "alice" "parent" "wss://b" "bob"
        `shouldBe`
          [ ["e", "root", "wss://a", "root"]
          , ["p", "alice"]
          , ["e", "parent", "wss://b", "reply"]
          , ["p", "bob"]
          ]

    it "p-tags one author once when both notes share them" $
      buildReplyTags "root" "wss://a" "alice" "parent" "wss://b" "alice"
        `shouldBe`
          [ ["e", "root", "wss://a", "root"]
          , ["p", "alice"]
          , ["e", "parent", "wss://b", "reply"]
          ]

    it "round-trips through threadOf" $ do
      let tags = buildReplyTags "root" "wss://a" "alice" "parent" "wss://b" "bob"
      threadOf (note tags)
        `shouldBe` Just (ThreadRef "root" "wss://a" (Just "parent") "wss://b")
