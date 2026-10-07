{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Bip340 (bip340Spec)
import Nip05Spec (nip05Spec)
import Nip09Spec (nip09Spec)
import Nip19Spec (nip19Spec)
import Nip21Spec (nip21Spec)
import Nip47Spec (nip47Spec)
import Nip57Spec (nip57Spec)
import Nip51Spec (nip51Spec)
import Nip22Spec (nip22Spec)
import Nip27Spec (nip27Spec)
import Nip36Spec (nip36Spec)
import Nip23Spec (nip23Spec)
import Nip10Spec (nip10Spec)
import Nip25Spec (nip25Spec)
import Nip11Spec (nip11Spec)
import Nip17Spec (nip17Spec)
import Nip42Spec (nip42Spec)
import Nip46Spec (nip46CoverageSpec, nip46Spec)
import Nip49Spec (nip49Spec)
import Nip59Spec (nip59Spec)
import Nip13Spec (nip13Spec)
import Nip40Spec (nip40Spec)
import Nip44Spec (nip44Spec)
import Data.Aeson (Value, decode, encode, eitherDecodeStrict, object, toJSON, (.=))
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Krivostr.Event
import Krivostr.Filter
import Krivostr.Key
import Krivostr.Logging
import Krivostr.Nip.Nip01
import Krivostr.Nip.Nip65
import Krivostr.Wire
import Test.Hspec

sampleEvent :: Event
sampleEvent =
  Event
    { evId = "abc"
    , evPubkey = "pub"
    , evCreatedAt = 1700000000
    , evKind = 1
    , evTags = []
    , evContent = "hello"
    , evSig = "sig"
    }

-- | The event from the NIP-01 example, whose id is well known.
nip01Example :: Event
nip01Example =
  Event
    { evId = ""
    , evPubkey = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
    , evCreatedAt = 1672280822
    , evKind = 1
    , evTags = []
    , evContent = ""
    , evSig = ""
    }

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

isRight :: Either a b -> Bool
isRight = not . isLeft

hasPrefix :: Text -> Text -> Bool
hasPrefix p s = T.isPrefixOf p s

main :: IO ()
main = hspec $ do
  bip340Spec
  nip05Spec
  nip09Spec
  nip19Spec
  nip21Spec
  nip47Spec
  nip57Spec
  nip51Spec
  nip22Spec
  nip27Spec
  nip36Spec
  nip23Spec
  nip10Spec
  nip25Spec
  nip44Spec
  nip13Spec
  nip11Spec
  nip17Spec
  nip42Spec
  nip46Spec
  nip46CoverageSpec
  nip49Spec
  nip59Spec
  nip40Spec

  describe "NIP-01 canonical serialization" $ do
    it "is deterministic" $
      computeEventId sampleEvent `shouldBe` computeEventId sampleEvent

    it "changes when content changes" $
      computeEventId sampleEvent
        `shouldNotBe` computeEventId sampleEvent {evContent = "bye"}

    it "matches the known NIP-01 example id" $
      -- The expected value is sha256 of
      -- [0,"3bf0...",1672280822,1,[],""] ; the test previously asserted a
      -- hash that no implementation could produce.
      computeEventId nip01Example
        `shouldBe` "1af087cb638c43c2303b54d02466ab73c8712157fe662dc3ad80d8c1709a813c"

    it "emits the exact canonical byte string" $
      canonicalBytes nip01Example
        `shouldBe` "[0,\"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d\",1672280822,1,[],\"\"]"

  describe "NIP-01 control character escaping" $ do
    let bytesOf c = canonicalBytes nip01Example {evContent = T.singleton c}
        shortForms = ['\b', '\f', '\n', '\r', '\t']

    it "escapes NUL as \\u0000" $
      bytesOf '\NUL' `shouldSatisfy` BS.isInfixOf "\\u0000"

    it "escapes every other C0 control as \\u00xx" $
      mapM_
        (\c -> bytesOf c `shouldSatisfy` BS.isInfixOf "\\u00")
        ( filter (< ' ')
            (filter (`notElem` shortForms) ['\NUL' .. '\US'])
        )

    it "uses the short forms for backspace and form feed" $ do
      bytesOf '\b' `shouldSatisfy` BS.isInfixOf "\\b"
      bytesOf '\f' `shouldSatisfy` BS.isInfixOf "\\f"

    it "uses the short forms for newline, carriage return and tab" $ do
      bytesOf '\n' `shouldSatisfy` BS.isInfixOf "\\n"
      bytesOf '\r' `shouldSatisfy` BS.isInfixOf "\\r"
      bytesOf '\t' `shouldSatisfy` BS.isInfixOf "\\t"

    it "does not double-escape the short forms" $ do
      bytesOf '\n' `shouldNotSatisfy` BS.isInfixOf "\\u000a"
      bytesOf '\t' `shouldNotSatisfy` BS.isInfixOf "\\u0009"

    it "leaves ordinary and non-control text alone" $ do
      -- The needle must be built with encodeUtf8, not an OverloadedStrings
      -- literal: IsString ByteString goes through Char8.pack and truncates
      -- anything above U+00FF to a single byte.
      let content = "hello \10009 world"
      canonicalBytes nip01Example {evContent = content}
        `shouldSatisfy` BS.isInfixOf (TE.encodeUtf8 content)
      canonicalBytes nip01Example {evContent = "\8364 euro"}
        `shouldSatisfy` BS.isInfixOf (TE.encodeUtf8 "\8364 euro")

    it "escapes a quote and a backslash" $ do
      bytesOf '"' `shouldSatisfy` BS.isInfixOf "\\\""
      bytesOf '\\' `shouldSatisfy` BS.isInfixOf "\\\\"

    it "changes the id when a control character is present" $
      computeEventId nip01Example {evContent = "\NUL"}
        `shouldNotBe` computeEventId nip01Example

  describe "Key" $ do
    it "round-trips a private key to nsec and back" $ do
      sk <- generatePrivateKey
      let nsec = exportNsec sk
      nsec `shouldSatisfy` hasPrefix "nsec1"
      importNsec nsec `shouldBe` Right sk

    it "round-trips a pubkey to npub and back" $ do
      sk <- generatePrivateKey
      let pk = derivePublicKey sk
      importNpub (exportNpub pk) `shouldBe` Right pk

    it "produces a 32-byte x-only public key" $ do
      sk <- generatePrivateKey
      pubKeyBytes (derivePublicKey sk) `shouldSatisfy` ((== 32) . BS.length)

    it "agrees between derived keys and imported npubs" $ do
      -- The bug this guards: importNpub used to keep the leading 0x02 while
      -- derivePublicKey dropped it, so the two disagreed byte-for-byte.
      sk <- generatePrivateKey
      let pk = derivePublicKey sk
      importNpub (exportNpub pk) `shouldBe` Right pk
      pubKeyHex pk `shouldBe` pubKeyHex (either error id (importNpub (exportNpub pk)))

    it "round-trips a private key through hex" $ do
      sk <- generatePrivateKey
      importHex (exportHex sk) `shouldBe` Right sk

    it "rejects malformed hex" $
      importHex "not-hex" `shouldSatisfy` isLeft

    it "rejects a secret key outside the group order" $ do
      importHex (T.replicate 64 "0") `shouldSatisfy` isLeft
      importHex (T.replicate 64 "f") `shouldSatisfy` isLeft

    it "rejects a public key that is not on the curve" $ do
      -- x = 0 lifts to no curve point, so it cannot be a public key.
      publicKeyFromBytes (BS.replicate 32 0) `shouldBe` Nothing
      publicKeyFromBytes (BS.replicate 31 0) `shouldBe` Nothing
      publicKeyFromBytes (BS.replicate 33 0) `shouldBe` Nothing

  describe "sign / verify" $ do
    it "signs then verifies" $ do
      sk <- generatePrivateKey
      let e = signEvent sk sampleEvent
      verifyEvent e `shouldBe` True

    it "detects tampering with the content" $ do
      sk <- generatePrivateKey
      let e = signEvent sk sampleEvent
      verifyEvent e {evContent = "tampered"} `shouldBe` False

    it "detects tampering with the created_at" $ do
      sk <- generatePrivateKey
      let e = signEvent sk sampleEvent
      verifyEvent e {evCreatedAt = evCreatedAt e + 1} `shouldBe` False

    it "detects tampering with the kind" $ do
      sk <- generatePrivateKey
      let e = signEvent sk sampleEvent
      verifyEvent e {evKind = 7} `shouldBe` False

    it "fills in the pubkey and id when signing" $ do
      sk <- generatePrivateKey
      let pk = pubKeyHex (derivePublicKey sk)
          e = signEvent sk sampleEvent
      evPubkey e `shouldBe` pk
      evId e `shouldBe` computeEventId e
      evSig e `shouldSatisfy` ((== 128) . T.length) -- 64 bytes, hex

    it "signs deterministically" $ do
      sk <- generatePrivateKey
      signEvent sk sampleEvent `shouldBe` signEvent sk sampleEvent

    it "rejects a truncated signature" $ do
      sk <- generatePrivateKey
      let e = signEvent sk sampleEvent
      verifyEvent e {evSig = T.take 100 (evSig e)} `shouldBe` False

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
      let e = sampleEvent {evTags = [["p", "alice"], ["p", "bob"]]}
      matches (tagEq "p" ["bob"]) e `shouldBe` True
      matches (tagEq "p" ["carol"]) e `shouldBe` False

    it "round-trips through JSON" $ do
      let f = Filter (Just ["a"]) (Just ["b"]) (Just [1, 2]) (Just 0) (Just 9) (Just 5) [("e", ["x"])] (Just "hello")
      decode (encode f) `shouldBe` Just f

    it "encodes search under its wire key" $
      BL.toStrict (encode (empty { fSearch = Just "hello" }))
        `shouldSatisfy` BS.isInfixOf "\"search\":\"hello\""

    it "matches search as a case-insensitive substring" $ do
      let f = empty { fSearch = Just "HELLO" }
      matches f sampleEvent `shouldBe` True
      matches (empty { fSearch = Just "goodbye" }) sampleEvent `shouldBe` False

    it "encodes tags under their #e keys" $
      BL.toStrict (encode (tagEq "p" ["bob"]))
        `shouldSatisfy` BS.isInfixOf "#p"

  describe "NIP-65" $ do
    it "parses read/write hints" $ do
      let e =
            sampleEvent
              { evKind = 10002
              , evTags =
                  [ ["r", "wss://a", "read"]
                  , ["r", "wss://b", "write"]
                  , ["r", "wss://c"]
                  ]
              }
      parseRelayList e
        `shouldBe` [ RelayHint "wss://a" Read
                   , RelayHint "wss://b" Write
                   , RelayHint "wss://c" Both
                   ]

    it "ignores tags that are too short" $
      parseRelayList sampleEvent {evTags = [["r"], []]} `shouldBe` []

    it "extracts read and write relays" $ do
      let hs = [RelayHint "a" Read, RelayHint "b" Write, RelayHint "c" Both]
      readRelays hs `shouldBe` ["a", "c"]
      writeRelays hs `shouldBe` ["b", "c"]

    it "round-trips tags" $
      buildRelayListTags [RelayHint "a" Read, RelayHint "b" Write, RelayHint "c" Both]
        `shouldBe` [ ["r", "a", "read"], ["r", "b", "write"], ["r", "c"] ]

  describe "Logging" $ do
    it "accumulates entries in the pure writer" $ do
      let ((), entries) = runPureLog $ do
            info "start"
            warn "careful"
      length entries `shouldBe` 2
      map leLevel entries `shouldBe` [Info, Warn]

    it "respects the minimum level in IO" $ do
      lg <- newLogger Warn
      emit lg Debug "hidden"
      emit lg Error "shown"
      entries <- drainQueue lg
      map leMsg entries `shouldBe` ["shown"]

    it "drains in order and empties the queue" $ do
      lg <- newLogger Debug
      mapM_ (emit lg Info) ["a", "b", "c"]
      entries <- drainQueue lg
      map leMsg entries `shouldBe` ["a", "b", "c"]
      again <- drainQueue lg
      again `shouldBe` []

    it "honours a withLevel override" $ do
      lg <- newLogger Error
      emit (withLevel lg Debug) Debug "visible"
      entries <- drainQueue lg
      map leMsg entries `shouldBe` ["visible"]

  describe "Wire" $ do
    it "encodes a REQ with the filters as trailing elements" $
      -- NIP-01: ["REQ", <subscription_id>, <filters1>, ...]. Relays reject a
      -- nested filter array, so this exact shape is part of the contract.
      BL.toStrict (encode (encodeClient (CReq "s1" [onlyKinds [1]])))
        `shouldBe` "[\"REQ\",\"s1\",{\"kinds\":[1]}]"

    it "encodes every filter of a multi-filter REQ separately" $
      BL.toStrict (encode (encodeClient (CReq "s1" [onlyKinds [1], onlyKinds [2]])))
        `shouldBe` "[\"REQ\",\"s1\",{\"kinds\":[1]},{\"kinds\":[2]}]"

    it "encodes a CLOSE message" $
      BL.toStrict (encode (encodeClient (CClose "s1")))
        `shouldSatisfy` BS.isInfixOf "\"CLOSE\""

    it "encodes COUNT with filters as trailing elements" $
      BL.toStrict (encode (encodeClient (CCount "c1" [onlyKinds [1]])))
        `shouldBe` "[\"COUNT\",\"c1\",{\"kinds\":[1]}]"

    it "decodes an EVENT relay message" $
      Aeson.parseEither decodeRelay (toJSON (["EVENT", "s1", toJSON sampleEvent] :: [Value]))
        `shouldSatisfy` isRight

    it "decodes an OK relay message" $
      Aeson.parseEither decodeRelay (toJSON (["OK", "s1", toJSON True, "ok"] :: [Value]))
        `shouldSatisfy` isRight

    it "decodes EOSE and NOTICE" $ do
      Aeson.parseEither decodeRelay (toJSON (["EOSE", "s1"] :: [Value]))
        `shouldSatisfy` isRight
      Aeson.parseEither decodeRelay (toJSON (["NOTICE", "hi"] :: [Value]))
        `shouldSatisfy` isRight

    it "decodes a COUNT answer" $
      Aeson.parseEither decodeRelay (toJSON (["COUNT", "c1", object ["count" .= (41 :: Int)]] :: [Value]))
        `shouldBe` Right (RCount "c1" 41)

    it "rejects a COUNT without a numeric count" $
      Aeson.parseEither decodeRelay (toJSON (["COUNT", "c1", object ["count" .= ("many" :: Text)]] :: [Value]))
        `shouldSatisfy` isLeft

    it "rejects an unknown relay message" $
      Aeson.parseEither decodeRelay (toJSON (["NOPE"] :: [Value]))
        `shouldSatisfy` isLeft

  describe "Event JSON" $
    it "round-trips through Aeson" $
      eitherDecodeStrict (BL.toStrict (encode sampleEvent)) `shouldBe` Right sampleEvent
