{-# LANGUAGE OverloadedStrings #-}

-- | The NIP-44 v2 test vectors, transcribed from the spec's @nip44.vectors.json@
-- (@269ed0f69e4c192512cc779e78c555090cebc7c785b609e338a62afc3ce25040@).
--
-- These vectors are the only thing that pins the scheme down. A payload is a
-- function of conversation key, nonce and plaintext, and every step has to
-- agree with every other Nostr implementation simultaneously to produce them:
-- ECDH, HKDF-Extract with the literal @nip44-v2@ salt, the padding schedule,
-- ChaCha20 at counter 0, HMAC over @aad || ciphertext@, and base64. A
-- round-trip test would happily pass on a scheme only this codebase agrees
-- with.
module Nip44Spec (nip44Spec) where

import Crypto.Hash.SHA256 (hash)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Krivostr.Key
import Krivostr.Nip.Nip44
import Test.Hspec

hexBytes :: ByteString -> ByteString
hexBytes = either (error . ("bad hex: " ++)) id . B16.decode

-- | Unwrap an 'Either' in the spec's monad, failing the example with the
-- library's own message. Without this every test would either ignore the error
-- channel or hand-roll @case@ at each step.
fromRight :: Either String a -> IO a
fromRight = either (ioError . userError) pure

-- | @sec1@ from the vectors: the scalar 1.
sec1 :: PrivateKey
sec1 = importScalar "0000000000000000000000000000000000000000000000000000000000000001"

-- | @sec2@ from the vectors: the scalar 2.
sec2 :: PrivateKey
sec2 = importScalar "0000000000000000000000000000000000000000000000000000000000000002"

-- | An unrelated secret, used to prove the MAC check binds the conversation key
-- rather than merely checking a length.
sec3 :: PrivateKey
sec3 = importScalar "0000000000000000000000000000000000000000000000000000000000000003"

importScalar :: Text -> PrivateKey
importScalar t = either (error . ("bad secret key: " ++)) id (importHex t)

expectedConversationKey :: ByteString
expectedConversationKey =
  hexBytes "c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d"

-- | The canonical @nonce@ every vector shares: 31 zero bytes then @0x01@.
--
-- This is @0x000...0001@, not 32 copies of @0x01@. Transcribing it as the
-- latter is the easy mistake here, and it changes every payload byte.
vectorNonce :: ByteString
vectorNonce = BS.replicate 31 0 <> BS.singleton 1

-- | A nonce of 32 copies of @0x01@, used to check nonce sensitivity without
-- depending on the published vector.
alternateNonce :: ByteString
alternateNonce = BS.replicate 32 1

-- | @sec2@'s public key as the 64-hex-character form an event carries.
sec2PubHex :: Text
sec2PubHex = pubKeyHex (derivePublicKey sec2)

-- | The canonical single-character vector's payload.
canonicalPayload :: Text
canonicalPayload =
  "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb"

-- | The padded-prefix boundary cases, as
-- @(plaintext length, padded length, sha256 plaintext hex, sha256 payload hex)@.
--
-- The digests stay as hex text because that is how they are compared.
--
-- 65535 and 65536 pad to the same /padded/ length but carry different /prefix/
-- lengths, which is precisely the case the 6-byte extended prefix exists for,
-- so both rows matter.
paddingBoundaries :: [(Int, Int, ByteString, ByteString)]
paddingBoundaries =
  [ ( 65535
    , 65536
    , "6e1bebca6a8229364a162a72ef064826c4cd7457bf54f190ef782bd9deff3e42"
    , "6d8c2810d1e870fbaa1f0a0937126cca837a15f9260e27060c331d70a3c0bc84"
    )
  , ( 65536
    , 65536
    , "bf718b6f653bebc184e1479f1935b8da974d701b893afcf49e701f3e2f9f9c5a"
    , "b7b4edb36ba92e267d322d56d9aebc22e7fa96ff52e3c12adc07f07a43cbc616"
    )
  , ( 65537
    , 81920
    , "008ffc88d3c96a9f307524eb361e47c5222a887fc45fa0c1fb8d429c5c23b430"
    , "eeb7c7c5373894ea2c1547cfd3ccb15d5a0b2d619da852e5c79df792dcc9e435"
    )
  ]

-- | Encrypt using the vectors' secret keys, so the whole pipeline runs.
encryptWithVectorKey :: ByteString -> ByteString -> Either String Text
encryptWithVectorKey nonce plaintext =
  encryptWithNonce sec1 sec2PubHex nonce plaintext

-- | The length prefix 'pad' prepends: 2 bytes below 65536, 6 bytes at or above.
prefixLenFor :: Int -> Int
prefixLenFor n = if n < 65536 then 2 else 6

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

nip44Spec :: Spec
nip44Spec = describe "NIP-44 v2" $ do
  describe "conversation key" $ do
    it "matches the published vector" $
      conversationKey sec1 (derivePublicKey sec2)
        `shouldBe` Right expectedConversationKey

    it "is symmetric" $
      conversationKey sec1 (derivePublicKey sec2)
        `shouldBe` conversationKey sec2 (derivePublicKey sec1)

    it "rejects a pubkey that is not on the curve" $
      conversationKeyWithHex sec1 (T.replicate 64 "0")
        `shouldSatisfy` isLeft

    it "rejects a pubkey that is not 64 hex characters" $
      conversationKeyWithHex sec1 "abcd" `shouldSatisfy` isLeft

  describe "padding" $ do
    it "floors at 32 bytes" $
      map calcPaddedLen [1, 16, 32] `shouldBe` [32, 32, 32]

    it "grows in chunks of 32 up to 256 bytes of plaintext" $ do
      calcPaddedLen 33 `shouldBe` 64
      calcPaddedLen 64 `shouldBe` 64
      calcPaddedLen 65 `shouldBe` 96
      calcPaddedLen 257 `shouldBe` 320

    it "matches the spec's padded lengths at the prefix boundaries" $
      mapM_
        (\(len, padded, _, _) -> calcPaddedLen len `shouldBe` padded)
        paddingBoundaries

    it "round-trips through pad and unpad" $
      mapM_
        ( \n -> do
            let plain = BS.replicate n 0x61
            padded <- fromRight (pad plain)
            -- pad returns prefix <> plaintext <> zeros, so the total is the
            -- length prefix *plus* calc_padded_len, not calc_padded_len.
            BS.length padded `shouldBe` prefixLenFor n + calcPaddedLen n
            unpad padded `shouldBe` Right plain
        )
        [1, 31, 32, 33, 255, 256, 1000, 65535, 65536, 65537]

    it "refuses an empty plaintext" $
      pad BS.empty `shouldSatisfy` isLeft

    it "rejects a padded length that disagrees with calc_padded_len" $ do
      padded <- fromRight (pad "a")
      unpad (BS.init padded) `shouldSatisfy` isLeft

    it "rejects non-zero padding bytes" $ do
      padded <- fromRight (pad (BS.replicate 33 0x61))
      unpad (BS.init padded <> BS.singleton 0x41) `shouldSatisfy` isLeft

    it "rejects a declared length longer than the payload" $ do
      padded <- fromRight (pad "a")
      -- Claim 2^32-1 bytes of plaintext inside a 34-byte buffer.
      let forged = BS.pack [0xff, 0xff, 0xff, 0xff, 0xff] <> BS.drop 2 padded
      unpad forged `shouldSatisfy` isLeft

    it "rejects the zero length prefix" $
      unpad (BS.replicate 34 0) `shouldSatisfy` isLeft

    it "rejects a padded plaintext shorter than its prefix" $
      unpad BS.empty `shouldSatisfy` isLeft

  describe "message keys" $ do
    it "slices 76 bytes into 32 + 12 + 32" $ do
      keys <- fromRight (messageKeys expectedConversationKey vectorNonce)
      BS.length (mkChaChaKey keys) `shouldBe` 32
      BS.length (mkChaChaNonce keys) `shouldBe` 12
      BS.length (mkHmacKey keys) `shouldBe` 32

    it "rejects a conversation key that is not 32 bytes" $
      messageKeys (BS.replicate 31 1) vectorNonce `shouldSatisfy` isLeft

    it "rejects a nonce that is not 32 bytes" $
      messageKeys expectedConversationKey (BS.replicate 31 1) `shouldSatisfy` isLeft

    it "derives different keys for different nonces" $ do
      a <- fromRight (messageKeys expectedConversationKey vectorNonce)
      b <- fromRight (messageKeys expectedConversationKey alternateNonce)
      mkChaChaKey a `shouldNotBe` mkChaChaKey b

  describe "payload" $ do
    it "encrypts the canonical vector byte for byte" $
      encryptWithVectorKey vectorNonce "a" `shouldBe` Right canonicalPayload

    it "decrypts the canonical payload back to its plaintext" $
      decrypt sec2 (pubKeyHex (derivePublicKey sec1)) canonicalPayload
        `shouldBe` Right "a"

    it "emits the 0x02 version byte, base64 for 0x02 0x00 0x00" $ do
      payload <- fromRight (encryptWithVectorKey vectorNonce "a")
      T.isPrefixOf "AgAA" payload `shouldBe` True

    it "produces a base64 payload of at least 132 characters" $ do
      payload <- fromRight (encryptWithVectorKey vectorNonce "a")
      T.length payload `shouldSatisfy` (>= 132)

    it "is deterministic for a fixed nonce" $ do
      a <- fromRight (encryptWithVectorKey vectorNonce "hello nostr")
      b <- fromRight (encryptWithVectorKey vectorNonce "hello nostr")
      a `shouldBe` b

    it "differs for a different nonce over the same plaintext" $ do
      a <- fromRight (encryptWithVectorKey vectorNonce "hello nostr")
      b <- fromRight (encryptWithVectorKey alternateNonce "hello nostr")
      a `shouldNotBe` b

    it "round-trips across a range of plaintext lengths" $
      mapM_
        ( \n -> do
            let plain = BS.replicate n 0x61
            payload <- fromRight (encryptWithVectorKey vectorNonce plain)
            decrypt sec2 (pubKeyHex (derivePublicKey sec1)) payload
              `shouldBe` Right plain
        )
        [1, 32, 33, 255, 256, 1000, 65535, 65536, 65537]

    it "matches the published padded and payload digests at the prefix boundaries" $
      mapM_
        ( \(len, padded, plainSha, payloadSha) -> do
            let plain = BS.replicate len 0x61
            B16.encode (hash plain) `shouldBe` plainSha
            paddedBytes <- fromRight (pad plain)
            BS.length paddedBytes `shouldBe` prefixLenFor len + padded
            payload <- fromRight (encryptWithVectorKey vectorNonce plain)
            B16.encode (hash (TE.encodeUtf8 payload)) `shouldBe` payloadSha
        )
        paddingBoundaries

  describe "rejects malformed payloads" $ do
    it "refuses an oversized payload before decoding it" $
      decrypt sec2 sec2PubHex (T.replicate (maxPayloadBytes + 1) "A")
        `shouldBe` Left "NIP-44 payload exceeds the accepted size"

    it "refuses a future version marker" $
      decrypt sec2 sec2PubHex "#somefutureversion" `shouldSatisfy` isLeft

    it "refuses a payload shorter than a version, nonce and mac" $
      decrypt sec2 sec2PubHex "AAAA" `shouldSatisfy` isLeft

    it "refuses a tampered ciphertext" $
      decrypt sec2 (pubKeyHex (derivePublicKey sec1)) (T.replace "ee0G5" "ff0G5" canonicalPayload)
        `shouldSatisfy` isLeft

    it "refuses a payload addressed to a different conversation" $
      -- Same bytes, read with an unrelated key: the conversation key differs,
      -- so the MAC must not verify.
      decrypt sec3 (pubKeyHex (derivePublicKey sec1)) canonicalPayload
        `shouldSatisfy` isLeft

    it "refuses a payload whose nonce was swapped" $ do
      -- Re-splice a different nonce over the original nonce and keep the
      -- original mac: the hmac covers the nonce as aad, so this must fail.
      let swapped = T.take 44 canonicalPayload <> T.drop 76 canonicalPayload
      decrypt sec2 (pubKeyHex (derivePublicKey sec1)) swapped
        `shouldSatisfy` isLeft