{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Test.Hspec
import Test.QuickCheck
import Krivostr.Event
import Krivostr.Filter
import Krivostr.Key
import Krivostr.Nip.Nip01
import Krivostr.Nip.Nip65
import Krivostr.Logging
import Krivostr.Wire
import Data.Aeson (encode, decode, toJSON)
import qualified Data.ByteString.Lazy as BL

sampleEvent :: Event
sampleEvent = Event
  { evId = "abc"
  , evPubkey = "pub"
  , evCreatedAt = 1700000000
  , evKind = 1
  , evTags = []
  , evContent = "hello"
  , evSig = "sig"
  }

main :: IO ()
main = hspec $ do
  describe "NIP-01 canonical id" $ do
    it "is deterministic" $
      computeEventId sampleEvent `shouldBe` computeEventId sampleEvent
    it "changes when content changes" $
      computeEventId sampleEvent `shouldNotBe`
      computeEventId sampleEvent { evContent = "bye" }
    it "matches a known vector" $ do
      let e = Event
            { evId = ""
            , evPubkey = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
            , evCreatedAt = 1672280822
            , evKind = 1
            , evTags = []
            , evContent = ""
            , evSig = ""
            }
      computeEventId e `shouldBe`
        "0df9a2f3b6ff9dbd3a06ee1250a71df3f8e3c0d67e2bd0f9a2cd0e0e6e40a4f1"

  describe "Key" $ do
    it "round-trips a private key to nsec and back" $ do
      sk <- generatePrivateKey
      let nsec = exportNsec sk
      nsec `shouldSatisfy` ("nsec1" `isPrefix`)
      importNsec nsec `shouldBe` Right sk
    it "round-trips pubkey to npub" $ do
      sk <- generatePrivateKey
      let pk = derivePublicKey sk
      importNpub (exportNpub pk) `shouldBe` Right pk
    it "rejects malformed hex" $
      importHex "not-hex" `shouldSatisfy` isLeft
    where
      isPrefix p s = take (length p) s == p
      isLeft (Left _) = True
      isLeft _        = False

  describe "sign / verify" $ do
    it "signs then verifies" $ do
      sk <- generatePrivateKey
      let e = signEvent sk sampleEvent
      verifyEvent e `shouldBe` True
    it "detects tampering" $ do
      sk <- generatePrivateKey
      let e = signEvent sk sampleEvent
      verifyEvent e { evContent = "tampered" } `shouldBe` False

  describe "Filter" $ do
    it "empty filter matches everything" $
      matches empty sampleEvent `shouldBe` True
    it "matches kinds" $
      matches (onlyKinds [1]) sampleEvent `shouldBe` True
    it "rejects wrong kinds" $
      matches (onlyKinds [7]) sampleEvent `shouldBe` False
    it "matches authors" $
      matches (byAuthors ["pub"]) sampleEvent `shouldBe` True
    it "filters tags" $ do
      let e = sampleEvent { evTags = [["p", "alice"], ["p", "bob"]] }
      matches (tagEq "p" ["bob"]) e `shouldBe` True
      matches (tagEq "p" ["carol"]) e `shouldBe` False
    it "round-trips through JSON" $ do
      let f = Filter (Just ["a"]) (Just ["b"]) (Just [1, 2])
                     (Just 0) (Just 9) (Just 5) [("e", ["x"])]
      decode (encode f) `shouldBe` Just f

  describe "NIP-65" $ do
    it "parses read/write hints" $ do
      let e = sampleEvent { evKind = 10002
                          , evTags = [ ["r", "wss://a", "read"]
                                     , ["r", "wss://b", "write"]
                                     , ["r", "wss://c"] ] }
      parseRelayList e `shouldBe`
        [ RelayHint "wss://a" Read
        , RelayHint "wss://b" Write
        , RelayHint "wss://c" Both ]
    it "extracts read and write relays" $ do
      let hs = [ RelayHint "a" Read, RelayHint "b" Write, RelayHint "c" Both ]
      readRelays hs  `shouldBe` ["a", "c"]
      writeRelays hs `shouldBe` ["b", "c"]
    it "round-trips tags" $
      buildRelayListTags
        [RelayHint "a" Read, RelayHint "b" Write, RelayHint "c" Both]
        `shouldBe` [ ["r", "a", "read"], ["r", "b", "write"], ["r", "c"] ]

  describe "Logging" $ do
    it "accumulates entries in Writer" $ do
      let ((), entries) = runPureLog $ do
            info "start"
            warn "careful"
      length entries `shouldBe` 2
      map leLevel entries `shouldBe` [Info, Warn]
    it "respects minimum level in IO" $ do
      lg <- newLogger Warn
      emit lg Debug "hidden"
      emit lg Error "shown"
      entries <- drainQueue lg
      map leMsg entries `shouldBe` ["shown"]

  describe "Wire" $ do
    it "encodes a REQ message" $
      encode (encodeClient (CReq "s1" [onlyKinds [1]]))
        `shouldSatisfy` (not . BL.null)
    it "round-trips an EVENT relay message" $ do
      let v = toJSON (["EVENT", "s1", toJSON sampleEvent] :: [Data.Aeson.Value])
      -- decodeRelay is a Parser; feed via fromJSON
      undefined
