{-# LANGUAGE OverloadedStrings #-}

-- | NIP-19 entities: @nevent@ and @naddr@ TLV pointers.
module Nip19Spec (nip19Spec) where

import Data.Text (Text)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Krivostr.Key (decodeNip19, encodeNip19)
import Krivostr.Nip.Nip19
import Test.Hspec

hexBytes :: Text -> BS.ByteString
hexBytes t = case B16.decode (TE.encodeUtf8 t) of
  Right bs -> bs
  Left _   -> error "bad hex"

eidHex :: Text
eidHex = T.replicate 32 "ab"

authorHex :: Text
authorHex = T.replicate 32 "cd"

pointer :: EventPointer
pointer = EventPointer
  { epId = eidHex
  , epRelays = ["wss://r.ly"]
  , epAuthor = Just authorHex
  , epKind = Just 1
  }

addr :: AddrPointer
addr = AddrPointer
  { apIdentifier = "my-post"
  , apRelays = ["wss://r.ly"]
  , apAuthor = authorHex
  , apKind = 30023
  }

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False

nip19Spec :: Spec
nip19Spec = describe "NIP-19 entities" $ do
  describe "nevent" $ do
    it "round-trips a full pointer" $
      decodeNevent (either error id (encodeNevent pointer)) `shouldBe` Right pointer

    it "round-trips a bare pointer" $
      decodeNevent (either error id (encodeNevent (EventPointer eidHex [] Nothing Nothing)))
        `shouldBe` Right (EventPointer eidHex [] Nothing Nothing)

    it "carries the nevent hrp" $
      either error id (encodeNevent pointer) `shouldSatisfy` T.isPrefixOf "nevent1"

    it "rejects the wrong hrp and garbage" $ do
      decodeNevent ("npub1" <> T.drop 7 (either error id (encodeNevent pointer)))
        `shouldSatisfy` isLeft
      decodeNevent "not-bech32!!" `shouldSatisfy` isLeft

    it "rejects a pointer without an id" $
      decodeNevent (encodeNip19For "nevent" [(1, TE.encodeUtf8 "wss://r.ly")]) `shouldSatisfy` isLeft

  describe "naddr" $ do
    it "round-trips a full pointer" $
      decodeNaddr (either error id (encodeNaddr addr)) `shouldBe` Right addr

    it "carries the naddr hrp" $
      either error id (encodeNaddr addr) `shouldSatisfy` T.isPrefixOf "naddr1"

    it "names the kind:pubkey:d coordinate" $
      naddrAddress addr `shouldBe` "30023:" <> authorHex <> ":my-post"

    it "rejects missing identifier, author, and kind" $ do
      decodeNaddr (encodeNip19For "naddr" [(2, hexBytes authorHex), (3, kindBytes 30023)])
        `shouldSatisfy` isLeft
      decodeNaddr (encodeNip19For "naddr" [(0, TE.encodeUtf8 "my-post"), (3, kindBytes 30023)])
        `shouldSatisfy` isLeft
      decodeNaddr (encodeNip19For "naddr" [(0, TE.encodeUtf8 "my-post"), (2, hexBytes authorHex)])
        `shouldSatisfy` isLeft
      encodeNaddr (addr { apIdentifier = "" }) `shouldSatisfy` isLeft

kindBytes :: Int -> BS.ByteString
kindBytes n = BS.pack [fromIntegral ((n `div` 256 ^ i) `mod` 256) | i <- [3, 2, 1, 0]]

-- | Hand-built TLV payloads for the malformed cases: (type, raw bytes).
encodeNip19For :: Text -> [(Int, BS.ByteString)] -> Text
encodeNip19For hrp fields = encodeNip19 hrp (BS.concat (map entry fields))
  where
    entry (t, v) = BS.pack [fromIntegral t, fromIntegral (BS.length v)] <> v
