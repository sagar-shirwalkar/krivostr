{-# LANGUAGE OverloadedStrings #-}

-- | NIP-23 long-form articles: header tags, address, and slugs.
module Nip23Spec (nip23Spec) where

import Data.Text (Text)
import Krivostr.Event
import Krivostr.Nip.Nip23
import Test.Hspec

article :: [[Text]] -> Text -> Event
article tags content =
  Event
    { evId = "article"
    , evPubkey = "author"
    , evCreatedAt = 1700000000
    , evKind = 30023
    , evTags = tags
    , evContent = content
    , evSig = "sig"
    }

nip23Spec :: Spec
nip23Spec = describe "NIP-23 articles" $ do
  describe "articleOf" $ do
    it "parses the header and body" $
      articleOf (article [["d", "my-post"], ["title", "My Post"], ["summary", "hi"], ["published_at", "1699999999"]] "body")
        `shouldBe` Just (Article "my-post" "My Post" "hi" "" (Just 1699999999) "body" "author")

    it "defaults missing header fields" $
      articleOf (article [["d", "slug"]] "body")
        `shouldBe` Just (Article "slug" "" "" "" Nothing "body" "author")

    it "rejects other kinds and slugless articles" $ do
      articleOf (article [["d", "slug"]] "body") {evKind = 1} `shouldBe` Nothing
      articleOf (article [["title", "No Slug"]] "body") `shouldBe` Nothing

    it "ignores a malformed published_at" $
      articleOf (article [["d", "s"], ["published_at", "yesterday"]] "b")
        `shouldBe` Just (Article "s" "" "" "" Nothing "b" "author")

  describe "articleAddress" $ do
    it "addresses 30023:pubkey:slug" $
      articleAddress (article [["d", "my-post"]] "body")
        `shouldBe` Just "30023:author:my-post"

    it "has no address without a slug" $
      articleAddress (article [] "body") `shouldBe` Nothing

  describe "buildArticleTags" $ do
    it "emits d plus the non-empty header" $
      buildArticleTags "my-post" "My Post" "" "" (Just 1699999999)
        `shouldBe` [["d", "my-post"], ["title", "My Post"], ["published_at", "1699999999"]]

    it "omits published_at when absent" $
      buildArticleTags "s" "" "" "" Nothing `shouldBe` [["d", "s"]]

  describe "slugify" $ do
    it "lowercases, dashes, and drops punctuation" $ do
      slugify "Hello, World!" `shouldBe` "hello-world"
      slugify "  NIP-23:  Long-Form  " `shouldBe` "nip-23-long-form"
      slugify "" `shouldBe` ""
