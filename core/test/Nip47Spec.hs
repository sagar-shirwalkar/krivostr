{-# LANGUAGE OverloadedStrings #-}

-- | NIP-47 wallet connect: URIs, methods, and JSON codecs.
module Nip47Spec (nip47Spec) where

import Data.Aeson (Value, object, (.=))
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

  describe "parseInfoMethods" $
    it "splits the capability advertisement" $
      parseInfoMethods "pay_invoice get_balance  make_invoice" `shouldBe` ["pay_invoice", "get_balance", "make_invoice"]

  describe "kinds" $
    it "uses 13194, 23194, and 23195" $
      (infoEventKind, requestEventKind, responseEventKind) `shouldBe` (13194, 23194, 23195)
