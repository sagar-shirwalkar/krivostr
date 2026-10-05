{-# LANGUAGE OverloadedStrings #-}

-- | NIP-09 deletion requests: parsing, authorship, and address matching.
module Nip09Spec (nip09Spec) where

import Data.Text (Text)
import Krivostr.Event
import Krivostr.Nip.Nip09
import Test.Hspec

note :: Text -> Text -> Int -> [[Text]] -> Event
note eid author kind tags =
  Event
    { evId = eid
    , evPubkey = author
    , evCreatedAt = 1700000000
    , evKind = kind
    , evTags = tags
    , evContent = "hi"
    , evSig = "sig"
    }

nip09Spec :: Spec
nip09Spec = describe "NIP-09 deletion" $ do
  describe "deletionOf" $ do
    it "parses e and a tags" $
      deletionOf (note "d" "alice" 5 [["e", "target-1"], ["a", "30023:alice:slug"]])
        `shouldBe` Just (Deletion ["target-1"] ["30023:alice:slug"])

    it "rejects other kinds and drops empty cites" $ do
      deletionOf (note "d" "alice" 1 [["e", "target-1"]]) `shouldBe` Nothing
      deletionOf (note "d" "alice" 5 [["e", ""], ["p", "bob"]])
        `shouldBe` Just (Deletion [] [])

  describe "parameterizedAddress" $ do
    it "addresses replaceable events as kind:pubkey:d" $
      parameterizedAddress (note "x" "alice" 30023 [["d", "slug"]])
        `shouldBe` Just "30023:alice:slug"

    it "has no address for regular or d-less events" $ do
      parameterizedAddress (note "x" "alice" 1 []) `shouldBe` Nothing
      parameterizedAddress (note "x" "alice" 30023 []) `shouldBe` Nothing

  describe "appliesTo" $ do
    it "matches by id with the same author" $
      appliesTo
        (note "d" "alice" 5 [["e", "target-1"]])
        (note "target-1" "alice" 1 [])
        `shouldBe` True

    it "matches by address" $
      appliesTo
        (note "d" "alice" 5 [["a", "30023:alice:slug"]])
        (note "x" "alice" 30023 [["d", "slug"]])
        `shouldBe` True

    it "refuses another author's request" $
      appliesTo
        (note "d" "mallory" 5 [["e", "target-1"]])
        (note "target-1" "alice" 1 [])
        `shouldBe` False

    it "refuses uncited events and non-deletions" $ do
      appliesTo
        (note "d" "alice" 5 [["e", "other"]])
        (note "target-1" "alice" 1 [])
        `shouldBe` False
      appliesTo
        (note "d" "alice" 7 [["e", "target-1"]])
        (note "target-1" "alice" 1 [])
        `shouldBe` False

  describe "buildDeletionTags" $ do
    it "emits e and a tags, dropping empties" $
      buildDeletionTags ["a", ""] ["30023:x:y", ""]
        `shouldBe` [["e", "a"], ["a", "30023:x:y"]]

    it "round-trips through deletionOf" $ do
      let tags = buildDeletionTags ["t1", "t2"] ["30023:a:b"]
          d = (note "d" "alice" 5 tags)
      deletionTargets d `shouldBe` (["t1", "t2"], ["30023:a:b"])
