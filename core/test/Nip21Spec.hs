{-# LANGUAGE OverloadedStrings #-}

-- | NIP-21 @nostr:@ URIs: exactly one reference and nothing else.
module Nip21Spec (nip21Spec) where

import Data.Text (Text)
import Krivostr.Key (derivePublicKey, exportNpub, importHex)
import Krivostr.Nip.Nip21 (parseNostrUri)
import Krivostr.Nip.Nip27 (Mention (..), MentionKind (..))
import Test.Hspec

npubUri :: Text
npubUri = case importHex "0000000000000000000000000000000000000000000000000000000000000001" of
  Right sk -> "nostr:" <> exportNpub (derivePublicKey sk)
  Left e   -> error e

nip21Spec :: Spec
nip21Spec = describe "NIP-21 URIs" $ do
  it "parses a lone reference" $
    fmap meKind (parseNostrUri npubUri)
      `shouldSatisfy` isPubkey

  it "tolerates surrounding whitespace" $
    parseNostrUri ("  " <> npubUri <> "\n") `shouldBe` parseNostrUri npubUri

  it "rejects prose, pairs, and bare text" $ do
    parseNostrUri ("see " <> npubUri) `shouldBe` Nothing
    parseNostrUri (npubUri <> " " <> npubUri) `shouldBe` Nothing
    parseNostrUri "just words" `shouldBe` Nothing
    parseNostrUri "" `shouldBe` Nothing

isPubkey :: Maybe MentionKind -> Bool
isPubkey (Just (MentionPubkey _)) = True
isPubkey _                        = False
