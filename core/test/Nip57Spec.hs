{-# LANGUAGE OverloadedStrings #-}

-- | NIP-57 zaps: requests, receipts, and invoice amounts.
module Nip57Spec (nip57Spec) where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Krivostr.Event
import Krivostr.Nip.Nip57
import Test.Hspec

request :: Event
request =
  Event
    { evId = "req"
    , evPubkey = "sender"
    , evCreatedAt = 1700000000
    , evKind = 9734
    , evTags =
        [ ["relays", "wss://r"]
        , ["amount", "21000"]
        , ["p", "recipient"]
        , ["e", "note-1"]
        ]
    , evContent = "Zap!"
    , evSig = "sig"
    }

receipt :: Event
receipt =
  Event
    { evId = "rcpt"
    , evPubkey = "wallet"
    , evCreatedAt = 1700000001
    , evKind = 9735
    , evTags =
        [ ["p", "recipient"]
        , ["P", "sender"]
        , ["e", "note-1"]
        , ["bolt11", "lnbc210n1pwhatever"]
        , ["description", TE.decodeUtf8 (BL.toStrict (encode request))]
        ]
    , evContent = ""
    , evSig = "sig"
    }

nip57Spec :: Spec
nip57Spec = describe "NIP-57 zaps" $ do
  describe "zapRequestOf" $ do
    it "parses relays, amount, recipient, event, and comment" $
      zapRequestOf request
        `shouldBe` Just (ZapRequest "recipient" (Just 21000) ["wss://r"] Nothing (Just "note-1") Nothing "Zap!")

    it "rejects other kinds, missing p, and bad amounts" $ do
      zapRequestOf (request {evKind = 1}) `shouldBe` Nothing
      zapRequestOf (request {evTags = [["amount", "21000"]]}) `shouldBe` Nothing
      zapRequestOf (request {evTags = [["p", "recipient"], ["amount", "many"]]}) `shouldBe` Nothing

  describe "buildZapRequestTags" $ do
    it "emits relays, amount, p, and the target" $
      buildZapRequestTags "recipient" 21000 ["wss://r"] Nothing (Just "note-1") Nothing
        `shouldBe`
          [ ["relays", "wss://r"]
          , ["amount", "21000"]
          , ["p", "recipient"]
          , ["e", "note-1"]
          ]

    it "emits lnurl and address when given" $
      buildZapRequestTags "r" 1000 [] (Just "lnurl1...") Nothing (Just "30023:a:b")
        `shouldBe`
          [ ["relays"]
          , ["amount", "1000"]
          , ["p", "r"]
          , ["lnurl", "lnurl1..."]
          , ["a", "30023:a:b"]
          ]

  describe "zapReceiptOf" $ do
    it "parses the receipt and its embedded request" $ do
      let r = zapReceiptOf receipt
      fmap zpRecipient r `shouldBe` Just "recipient"
      fmap zpSender r `shouldBe` Just (Just "sender")
      fmap zpBolt11 r `shouldBe` Just "lnbc210n1pwhatever"
      fmap (fmap zrComment . zpRequest) r `shouldBe` Just (Just "Zap!")

    it "rejects other kinds and tagless receipts" $ do
      zapReceiptOf (receipt {evKind = 1}) `shouldBe` Nothing
      zapReceiptOf (receipt {evTags = [["p", "recipient"]]}) `shouldBe` Nothing

    it "keeps the receipt when the description is not a request" $
      fmap zpRequest (zapReceiptOf (receipt {evTags = [["p", "r"], ["bolt11", "lnbc1x"], ["description", "nope"]]}))
        `shouldBe` Just Nothing

  describe "invoiceAmountMsats" $ do
    it "decodes multipliers to millisats" $ do
      invoiceAmountMsats "lnbc210u1pwhatever" `shouldBe` Just 21000000
      invoiceAmountMsats "lnbc1m1pwhatever" `shouldBe` Just 100000000
      invoiceAmountMsats "lnbc100n1pwhatever" `shouldBe` Just 10000
      invoiceAmountMsats "lnbcrt500p1whatever" `shouldBe` Just 50

    it "returns Nothing for amountless and uneven invoices" $ do
      invoiceAmountMsats "lnbc1pwhatever" `shouldBe` Nothing
      invoiceAmountMsats "lnbc1p1whatever" `shouldBe` Nothing
      invoiceAmountMsats "not-an-invoice" `shouldBe` Nothing

  describe "invoiceAmountSats" $ do
    it "divides whole amounts" $ do
      invoiceAmountSats "lnbc210u1pwhatever" `shouldBe` Just 21000
      invoiceAmountSats "lnbc100p1pwhatever" `shouldBe` Nothing
