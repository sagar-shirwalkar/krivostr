{-# LANGUAGE OverloadedStrings #-}

-- | NIP-05 DNS identifiers: parsing, URL building, and the trust decision.
--
-- Fetching is IO and lives below the purity line; these tests pin the pure
-- half against a hand-written document.
module Nip05Spec (nip05Spec) where

import Data.Map.Strict (fromList)
import Krivostr.Nip.Nip05
import Test.Hspec

doc :: Nip05Doc
doc = Nip05Doc
  { nip05Names = fromList [("alice", "aaa"), ("_", "bbb")]
  , nip05Relays = fromList [("aaa", ["wss://r"])]
  }

nip05Spec :: Spec
nip05Spec = describe "NIP-05 identifiers" $ do
  describe "parseIdentifier" $ do
    it "splits name and domain" $
      parseIdentifier "alice@example.com" `shouldBe` Right ("alice", "example.com")

    it "reads a bare domain as the _ name" $
      parseIdentifier "example.com" `shouldBe` Right ("_", "example.com")

    it "rejects empty sides and double @ signs" $ do
      parseIdentifier "@example.com" `shouldSatisfy` isLeft'
      parseIdentifier "alice@" `shouldSatisfy` isLeft'
      parseIdentifier "a@b@c" `shouldSatisfy` isLeft'
      parseIdentifier "" `shouldSatisfy` isLeft'

  describe "wellKnownUrl" $ do
    it "is always HTTPS with the name query" $
      wellKnownUrl "alice" "example.com"
        `shouldBe` "https://example.com/.well-known/nostr.json?name=alice"

    it "never emits HTTP" $
      wellKnownUrl "alice" "example.com" `shouldSatisfy` (/= "http://example.com/.well-known/nostr.json")

  describe "verifyName" $ do
    it "accepts the mapped pubkey" $
      verifyName "alice" "aaa" doc `shouldBe` Right ()

    it "accepts the _ name for a bare domain" $
      verifyName "_" "bbb" doc `shouldBe` Right ()

    it "rejects a wrong pubkey without saying the name exists" $
      verifyName "alice" "zzz" doc
        `shouldBe` Left "identifier does not match this pubkey: alice"

    it "rejects an unmapped name the same way" $
      verifyName "mallory" "aaa" doc
        `shouldBe` Left "identifier does not match this pubkey: mallory"

    it "is case-sensitive" $
      verifyName "Alice" "aaa" doc `shouldSatisfy` isLeft'

isLeft' :: Either a b -> Bool
isLeft' (Left _) = True
isLeft' _        = False
