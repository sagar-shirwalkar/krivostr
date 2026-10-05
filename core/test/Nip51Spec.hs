{-# LANGUAGE OverloadedStrings #-}

-- | NIP-51 lists: mute, pins, bookmarks.
module Nip51Spec (nip51Spec) where

import Data.Text (Text)
import Krivostr.Event
import Krivostr.Nip.Nip51
import Test.Hspec

list :: Int -> [[Text]] -> Event
list kind tags =
  Event
    { evId = "list"
    , evPubkey = "owner"
    , evCreatedAt = 1700000000
    , evKind = kind
    , evTags = tags
    , evContent = ""
    , evSig = "sig"
    }

nip51Spec :: Spec
nip51Spec = describe "NIP-51 lists" $ do
  describe "listEntries" $ do
    it "reads muted pubkeys with relay hints intact" $
      listEntries (list 10000 [["p", "alice", "wss://r"], ["p", "bob"]])
        `shouldBe` Just (ListEntries ["alice", "bob"] [] [] [])

    it "reads pins by event id" $
      listEntries (list 10001 [["e", "note-1"], ["e", "note-2"]])
        `shouldBe` Just (ListEntries [] ["note-1", "note-2"] [] [])

    it "reads bookmarks across e, a, d, and t" $
      listEntries (list 10003 [["e", "n1"], ["a", "30023:x:y"], ["d", "ident"], ["t", "art"]])
        `shouldBe` Just (ListEntries [] ["n1"] ["30023:x:y"] ["ident", "art"])

    it "rejects other kinds" $
      listEntries (list 1 [["p", "alice"]]) `shouldBe` Nothing

  describe "accessors" $ do
    it "read the right channel per kind" $ do
      mutedPubkeys (list 10000 [["p", "alice"]]) `shouldBe` ["alice"]
      mutedPubkeys (list 1 [["p", "alice"]]) `shouldBe` []
      pinnedIds (list 10001 [["e", "n1"]]) `shouldBe` ["n1"]
      bookmarkedIds (list 10003 [["e", "n1"]]) `shouldBe` ["n1"]
      bookmarkedAddresses (list 10003 [["a", "30023:x:y"]]) `shouldBe` ["30023:x:y"]

  describe "addEntry / removeEntry" $ do
    it "adds idempotently" $ do
      addEntry "p" "alice" [] `shouldBe` [["p", "alice"]]
      addEntry "p" "alice" [["p", "alice"]] `shouldBe` [["p", "alice"]]
      addEntry "p" "bob" [["p", "alice"]] `shouldBe` [["p", "alice"], ["p", "bob"]]

    it "removes by name and value regardless of hints" $ do
      removeEntry "p" "alice" [["p", "alice", "wss://r"], ["p", "bob"]]
        `shouldBe` [["p", "bob"]]
      removeEntry "p" "carol" [["p", "alice"]] `shouldBe` [["p", "alice"]]

    it "round-trips through the accessors" $ do
      let tags = addEntry "p" "bob" (addEntry "p" "alice" [])
      mutedPubkeys (list 10000 tags) `shouldBe` ["alice", "bob"]
      mutedPubkeys (list 10000 (removeEntry "p" "alice" tags)) `shouldBe` ["bob"]
