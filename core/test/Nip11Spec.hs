{-# LANGUAGE OverloadedStrings #-}
module Nip11Spec (nip11Spec) where

import Data.Aeson
import Data.Text (Text)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import Krivostr.Nip.Nip11
import Test.Hspec
import Data.Either (isLeft)

fromRight :: Either String a -> IO a
fromRight = either (ioError . userError) pure

fullDoc :: BS.ByteString
fullDoc = mconcat
  [ "{"
  , "\"name\": \"Damus\","
  , "\"description\": \"A next generation social network that is powered by Nostr.\","
  , "\"banner\": \"https://damus.io/img/banner.png\","
  , "\"icon\": \"https://damus.io/img/damus.png\","
  , "\"pubkey\": \"aefee970ba97f5d9ca04956b1755dca6ae5f01e0be944e1d1ecff778a1e20a2b\","
  , "\"self\": \"aefee970ba97f5d9ca04956b1755dca6ae5f01e0be944e1d1ecff778a1e20a2b\","
  , "\"contact\": \"mailto:contact@damus.io\","
  , "\"supported_nips\": [1, 2, 3, 4, 5, 6, 7, 9, 11, 12, 13, 16, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 33, 34, 35, 36, 38, 39, 40, 42],"
  , "\"software\": \"https://github.com/damus-io/nostr-rs-relay\","
  , "\"version\": \"0.8.2\","
  , "\"terms_of_service\": \"https://damus.io/terms/\","
  , "\"limitation\": {"
  , "  \"max_message_length\": 16384,"
  , "  \"max_subscriptions\": 300,"
  , "  \"max_filters\": 20,"
  , "  \"max_limit\": 5000,"
  , "  \"max_subid_length\": 100,"
  , "  \"max_event_tags\": 100,"
  , "  \"max_content_length\": 8196,"
  , "  \"min_pow_difficulty\": 30,"
  , "  \"auth_required\": true,"
  , "  \"payment_required\": true,"
  , "  \"restricted_writes\": true,"
  , "  \"created_at_lower_limit\": 31536000,"
  , "  \"created_at_upper_limit\": 3,"
  , "  \"default_limit\": 500"
  , "}"
  , "}"
  ]

nip11Spec :: Spec
nip11Spec = describe "NIP-11" $ do
  it "parses and round-trips a full document from the spec example" $ do
    info <- fromRight $ decodeRelayInfo fullDoc
    name info `shouldBe` Just "Damus"
    description info `shouldBe` Just "A next generation social network that is powered by Nostr."
    banner info `shouldBe` Just "https://damus.io/img/banner.png"
    icon info `shouldBe` Just "https://damus.io/img/damus.png"
    pubkey info `shouldBe` Just "aefee970ba97f5d9ca04956b1755dca6ae5f01e0be944e1d1ecff778a1e20a2b"
    self info `shouldBe` Just "aefee970ba97f5d9ca04956b1755dca6ae5f01e0be944e1d1ecff778a1e20a2b"
    contact info `shouldBe` Just "mailto:contact@damus.io"
    supportedNips info `shouldBe` Just [1,2,3,4,5,6,7,9,11,12,13,16,18,19,20,21,22,23,24,25,26,27,28,29,30,31,33,34,35,36,38,39,40,42]
    software info `shouldBe` Just "https://github.com/damus-io/nostr-rs-relay"
    version info `shouldBe` Just "0.8.2"
    termsOfService info `shouldBe` Just "https://damus.io/terms/"
    case limitation info of
      Just lim -> do
        maxMessageLength lim `shouldBe` Just 16384
        maxSubscriptions lim `shouldBe` Just 300
        maxFilters lim `shouldBe` Just 20
        maxLimit lim `shouldBe` Just 5000
        maxSubidLength lim `shouldBe` Just 100
        maxEventTags lim `shouldBe` Just 100
        maxContentLength lim `shouldBe` Just 8196
        minPowDifficulty lim `shouldBe` Just 30
        authRequired lim `shouldBe` Just True
        paymentRequired lim `shouldBe` Just True
        restrictedWrites lim `shouldBe` Just True
        createdAtLowerLimit lim `shouldBe` Just 31536000
        createdAtUpperLimit lim `shouldBe` Just 3
        defaultLimit lim `shouldBe` Just 500
      Nothing -> expectationFailure "limitation should be present"
    -- round-trip
    let encoded = encodeRelayInfo info
    info2 <- fromRight $ eitherDecodeStrict (BS.toStrict encoded)
    info2 `shouldBe` info

  it "parses a MINIMAL document with just a name" $ do
    info <- fromRight $ decodeRelayInfo "{\"name\":\"test\"}"
    name info `shouldBe` Just "test"
    description info `shouldBe` Nothing
    banner info `shouldBe` Nothing
    icon info `shouldBe` Nothing
    pubkey info `shouldBe` Nothing
    self info `shouldBe` Nothing
    contact info `shouldBe` Nothing
    supportedNips info `shouldBe` Nothing
    software info `shouldBe` Nothing
    version info `shouldBe` Nothing
    termsOfService info `shouldBe` Nothing
    limitation info `shouldBe` Nothing

  it "missing optional fields are absent not defaulted to wrong values" $ do
    info <- fromRight $ decodeRelayInfo "{\"description\":\"hi\",\"supported_nips\":[11]}"
    name info `shouldBe` Nothing
    description info `shouldBe` Just "hi"
    supportedNips info `shouldBe` Just [11]
    supportsNip 11 info `shouldBe` True
    supportsNip 42 info `shouldBe` False

  it "supportsNip true and false cases" $ do
    info1 <- fromRight $ decodeRelayInfo "{\"supported_nips\":[1,11,42]}"
    supportsNip 1 info1 `shouldBe` True
    supportsNip 11 info1 `shouldBe` True
    supportsNip 42 info1 `shouldBe` True
    supportsNip 100 info1 `shouldBe` False
    info2 <- fromRight $ decodeRelayInfo "{}"
    supportsNip 11 info2 `shouldBe` False
    supportsNip 1 info2 `shouldBe` False

  it "an empty supported_nips parses" $ do
    info <- fromRight $ decodeRelayInfo "{\"supported_nips\":[]}"
    supportedNips info `shouldBe` Just []
    supportsNip 11 info `shouldBe` False

  it "malformed JSON returns Left" $ do
    let res = decodeRelayInfo "{\"name\":"
    res `shouldSatisfy` isLeft

  it "a document where a field has the wrong type returns Left" $ do
    let res = decodeRelayInfo "{\"supported_nips\":\"not an array\"}"
    res `shouldSatisfy` isLeft
    let res2 = decodeRelayInfo "{\"name\":123}"
    res2 `shouldSatisfy` isLeft
