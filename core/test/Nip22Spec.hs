{-# LANGUAGE OverloadedStrings #-}

-- | NIP-22 comments: uppercase root scope, lowercase parent scope.
module Nip22Spec (nip22Spec) where

import Data.Text (Text)
import Krivostr.Event
import Krivostr.Nip.Nip22
import Test.Hspec

comment :: [[Text]] -> Event
comment tags =
  Event
    { evId = "comment"
    , evPubkey = "commenter"
    , evCreatedAt = 1700000000
    , evKind = 1111
    , evTags = tags
    , evContent = "great post"
    , evSig = "sig"
    }

articleRef :: ItemRef
articleRef = ItemRef
  { refId = Just "article-v1"
  , refAddress = Just "30023:alice:slug"
  , refKind = 30023
  , refAuthor = "alice"
  , refRelay = "wss://r"
  }

nip22Spec :: Spec
nip22Spec = describe "NIP-22 comments" $ do
  describe "commentOf" $ do
    it "parses root and parent scopes on an article comment" $ do
      let tags = buildCommentTags articleRef Nothing
          c = commentOf (comment tags)
      fmap cmRoot c `shouldBe` Just articleRef
      fmap cmParent c `shouldBe` Just articleRef

    it "keeps the root when answering another comment" $ do
      let parentRef = ItemRef (Just "comment-1") Nothing 1111 "bob" ""
          tags = buildCommentTags articleRef (Just parentRef)
          c = commentOf (comment tags)
      fmap cmRoot c `shouldBe` Just articleRef {refRelay = "wss://r"}
      fmap (refId . cmParent) c `shouldBe` Just (Just "comment-1")

    it "rejects other kinds and scopeless comments" $ do
      commentOf (comment []) {evKind = 1} `shouldBe` Nothing
      commentOf (comment [["K", "30023"], ["k", "30023"]]) `shouldBe` Nothing
      commentOf (comment [["E", "x"], ["e", "x"]]) `shouldBe` Nothing

  describe "buildCommentTags" $ do
    it "addresses plain events by id alone" $
      buildCommentTags (ItemRef (Just "note-9") Nothing 42 "carol" "") Nothing
        `shouldBe`
          [ ["E", "note-9", "", "carol"]
          , ["K", "42"]
          , ["P", "carol", ""]
          , ["e", "note-9", "", "carol"]
          , ["k", "42"]
          , ["p", "carol", ""]
          ]

    it "addresses articles by coordinate plus version" $
      buildCommentTags articleRef Nothing
        `shouldBe`
          [ ["A", "30023:alice:slug", "wss://r"]
          , ["E", "article-v1", "wss://r", "alice"]
          , ["K", "30023"]
          , ["P", "alice", "wss://r"]
          , ["a", "30023:alice:slug", "wss://r"]
          , ["e", "article-v1", "wss://r", "alice"]
          , ["k", "30023"]
          , ["p", "alice", "wss://r"]
          ]

    it "drops the author tag when unknown" $
      buildCommentTags (ItemRef (Just "x") Nothing 42 "" "") Nothing
        `shouldSatisfy` (notElem ["P", "", ""] . id)
