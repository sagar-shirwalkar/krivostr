{-# LANGUAGE OverloadedStrings #-}

-- | NIP-47 wallet connect: URIs, methods, and JSON codecs.
module Nip47Spec (nip47Spec) where

import Data.Aeson (Value, eitherDecodeStrict, encode, object, (.=))
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Krivostr.Nip.Nip47
import Test.Hspec

uri :: Text
uri = T.concat
  [ "nostr+walletconnect://"
  , T.replicate 64 "a"
  , "?relay=wss%3A%2F%2Fr1.example&relay=wss%3A%2F%2Fr2.example"
  , "&secret="
  , T.replicate 64 "b"
  , "&lud16=me%40example.com"
  ]

conn :: WalletConn
conn = WalletConn
  { wcWalletPubkey = T.replicate 64 "a"
  , wcRelays = ["wss://r1.example", "wss://r2.example"]
  , wcSecret = T.replicate 64 "b"
  , wcLud16 = Just "me@example.com"
  }

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False

nip47Spec :: Spec
nip47Spec = describe "NIP-47 wallet connect" $ do
  describe "parseWalletUri" $ do
    it "parses pubkey, relays, secret, and lud16" $
      parseWalletUri uri `shouldBe` Right conn

    it "decodes percent-encoded relays and lud16" $ do
      let c = either error id (parseWalletUri uri)
      wcRelays c `shouldBe` ["wss://r1.example", "wss://r2.example"]
      wcLud16 c `shouldBe` Just "me@example.com"

    it "rejects wrong schemes, short keys, and missing secrets" $ do
      parseWalletUri "https://example.com" `shouldSatisfy` isLeft
      parseWalletUri "nostr+walletconnect://abc?secret=def" `shouldSatisfy` isLeft
      parseWalletUri ("nostr+walletconnect://" <> T.replicate 64 "a") `shouldSatisfy` isLeft

    it "round-trips through renderWalletUri" $
      parseWalletUri (renderWalletUri conn) `shouldBe` Right conn

    it "rejects non-hex and uppercase pubkeys" $ do
      parseWalletUri ("nostr+walletconnect://" <> T.replicate 64 "g" <> "?secret=" <> T.replicate 64 "b")
        `shouldSatisfy` isLeft
      parseWalletUri ("nostr+walletconnect://" <> T.replicate 64 "A" <> "?secret=" <> T.replicate 64 "b")
        `shouldSatisfy` isLeft

    it "rejects a pubkey with a path segment" $
      parseWalletUri ("nostr+walletconnect://" <> T.replicate 64 "a" <> "/x?secret=" <> T.replicate 64 "b")
        `shouldSatisfy` isLeft

    it "rejects short and non-hex secrets" $ do
      parseWalletUri ("nostr+walletconnect://" <> T.replicate 64 "a" <> "?secret=short")
        `shouldSatisfy` isLeft
      parseWalletUri ("nostr+walletconnect://" <> T.replicate 64 "a" <> "?secret=" <> T.replicate 64 "z")
        `shouldSatisfy` isLeft

    it "reads a URI with no relays and no lud16" $
      parseWalletUri ("nostr+walletconnect://" <> T.replicate 64 "a" <> "?secret=" <> T.replicate 64 "b")
        `shouldBe` Right (WalletConn (T.replicate 64 "a") [] (T.replicate 64 "b") Nothing)

    it "keeps a bare relay key as an empty value" $ do
      let Right c = parseWalletUri
            ("nostr+walletconnect://" <> T.replicate 64 "a" <> "?relay&secret=" <> T.replicate 64 "b")
      wcRelays c `shouldBe` [""]

    it "ignores pairs with more than one =" $ do
      let Right c = parseWalletUri
            ("nostr+walletconnect://" <> T.replicate 64 "a" <> "?foo=a=b&secret=" <> T.replicate 64 "b")
      wcRelays c `shouldBe` []

    it "leaves malformed escapes alone instead of guessing" $ do
      let Right c = parseWalletUri
            ("nostr+walletconnect://" <> T.replicate 64 "a" <> "?relay=wss%3A%2F%2Fr%zz%2&secret=" <> T.replicate 64 "b")
      wcRelays c `shouldBe` ["wss://r%zz%2"]

    it "decodes lowercase escapes" $ do
      let Right c = parseWalletUri
            ("nostr+walletconnect://" <> T.replicate 64 "a" <> "?relay=wss%3a%2f%2fr.example&secret=" <> T.replicate 64 "b")
      wcRelays c `shouldBe` ["wss://r.example"]

  describe "renderWalletUri variants" $ do
    it "omits the relay params when there are none" $
      renderWalletUri (WalletConn (T.replicate 64 "a") [] (T.replicate 64 "b") Nothing)
        `shouldBe` ("nostr+walletconnect://" <> T.replicate 64 "a" <> "?secret=" <> T.replicate 64 "b")

    it "omits lud16 when absent and keeps it when present" $ do
      renderWalletUri (WalletConn (T.replicate 64 "a") ["wss://r.example"] (T.replicate 64 "b") Nothing)
        `shouldSatisfy` (not . T.isInfixOf "lud16")
      renderWalletUri conn `shouldSatisfy` T.isInfixOf "lud16=me@example.com"

    it "escapes ? & = # in relay urls and reads them back" $ do
      let c = WalletConn (T.replicate 64 "a") ["wss://r.example/feed?x=1&y=2#frag"] (T.replicate 64 "b") Nothing
          t = renderWalletUri c
      t `shouldSatisfy` T.isInfixOf "%3F"
      t `shouldSatisfy` T.isInfixOf "%26"
      t `shouldSatisfy` T.isInfixOf "%3D"
      t `shouldSatisfy` T.isInfixOf "%23"
      parseWalletUri t `shouldBe` Right c

  describe "methods" $ do
    it "knows the core table and nothing else" $ do
      map methodToText allMethods
        `shouldBe` [ "get_info", "get_balance", "pay_invoice", "multi_pay_invoice"
                   , "pay_keysend", "make_invoice", "lookup_invoice"
                   , "list_transactions", "sign_message"
                   ]
      methodFromText "pay_invoice" `shouldBe` Right MPayInvoice
      methodFromText "zap_zap" `shouldSatisfy` isLeft

  describe "request codec" $ do
    it "round-trips method and params" $ do
      let r = Request MPayInvoice (object ["invoice" .= ("lnbc1" :: Text)])
      parseRequest (encodeRequest r) `shouldBe` Right r

    it "rejects unknown methods" $
      parseRequest "{\"method\":\"zap_zap\",\"params\":{}}" `shouldSatisfy` isLeft

    it "rejects payloads that are not JSON or lack params" $ do
      parseRequest "not json" `shouldSatisfy` isLeft
      parseRequest "{\"method\":\"get_info\"}" `shouldSatisfy` isLeft

  describe "buildRequestTags" $
    it "names NIP-44 mode and the service" $
      buildRequestTags (T.replicate 64 "a")
        `shouldBe` [["encryption", "nip44_v2"], ["p", T.replicate 64 "a"]]

  describe "response codec" $ do
    it "round-trips results and errors" $ do
      let ok = Response MGetBalance (Just (object ["balance" .= (10000 :: Int)])) Nothing
          err = Response MPayInvoice Nothing (Just (WalletError "PAYMENT_FAILED" "nope"))
      parseResponse (encodeResponse ok) `shouldBe` Right ok
      parseResponse (encodeResponse err) `shouldBe` Right err

    it "accepts a bare result_type with neither result nor error" $
      parseResponse "{\"result_type\":\"get_info\"}"
        `shouldBe` Right (Response MGetInfo Nothing Nothing)

    it "rejects payloads that are not JSON or lack a result_type" $ do
      parseResponse "not json" `shouldSatisfy` isLeft
      parseResponse "{\"result\":{}}" `shouldSatisfy` isLeft

    it "round-trips WalletError through JSON directly" $
      eitherDecodeStrict (BL.toStrict (encode (WalletError "PAYMENT_FAILED" "nope")))
        `shouldBe` Right (WalletError "PAYMENT_FAILED" "nope")

  describe "parseInfoMethods" $ do
    it "splits the capability advertisement" $
      parseInfoMethods "pay_invoice get_balance  make_invoice" `shouldBe` ["pay_invoice", "get_balance", "make_invoice"]

    it "advertises nothing for an empty string" $
      parseInfoMethods "" `shouldBe` []

  describe "kinds" $
    it "uses 13194, 23194, and 23195" $
      (infoEventKind, requestEventKind, responseEventKind) `shouldBe` (13194, 23194, 23195)
