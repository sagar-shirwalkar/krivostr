{-# LANGUAGE OverloadedStrings #-}

-- | NIP-36 sensitive content: presence is the signal, the reason advisory.
module Nip36Spec (nip36Spec) where

import Data.Text (Text)
import Krivostr.Event
import Krivostr.Nip.Nip36
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

nip36Spec :: Spec
nip36Spec = describe "NIP-36 sensitive content" $ do
  describe "contentWarningOf" $ do
    it "reads the reason" $
      contentWarningOf (note [["content-warning", "nudity"]]) `shouldBe` Just "nudity"

    it "treats a reasonless tag as still sensitive" $
      contentWarningOf (note [["content-warning"]]) `shouldBe` Just ""

    it "finds no warning without the tag" $
      contentWarningOf (note [["t", "x"]]) `shouldBe` Nothing

  describe "isSensitive" $ do
    it "is true with or without a reason" $ do
      isSensitive (note [["content-warning", "x"]]) `shouldBe` True
      isSensitive (note [["content-warning"]]) `shouldBe` True
      isSensitive (note []) `shouldBe` False

  describe "buildWarningTag" $ do
    it "emits the tag with or without a reason" $ do
      buildWarningTag "spoilers" `shouldBe` ["content-warning", "spoilers"]
      buildWarningTag "" `shouldBe` ["content-warning", ""]
