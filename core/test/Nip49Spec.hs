{-# LANGUAGE OverloadedStrings #-}

-- | The NIP-49 test vector, transcribed from the spec's Test Data section.
--
-- This vector is the only thing that pins the scheme down, and being precise
-- about which bytes it fixes is most of the point. The published @ncryptsec1@
-- decodes to 91 bytes laid out as
--
-- > 02 | 10 | 52d7c3f8...4646b | c33f02a7...a7bf | 00 | b8e88034...ee776
-- > ^   ^                    ^                     ^   ^
-- > |   log_n = 16           salt(16)               |   ciphertext(32) + tag(16)
-- > version 0x02
-- >                                    nonce(24) ^  key security
--
-- and the plaintext it hides is a raw 32-byte secret, with no version prefix and
-- no hex. The salt is 16 bytes, @p@ is fixed at 1 so there is no @log_p@ on the
-- wire, and the payload carries a @log_n@ byte and a one-byte key security field
-- that are easy to leave out. Landing on this exact string therefore fixes
-- scrypt at @n = 2^16, r = 8, p = 1@, the XChaCha20-Poly1305 nonce and
-- associated data, the field order, and NIP-19 bech32, all at once -- and a
-- payload that adds up to 91 bytes with the fields in the wrong place would pass
-- every length check while failing here.
--
-- A round trip proves only that this codebase agrees with itself, which is why
-- the byte-for-byte re-encryption below is the deciding assertion and the round
-- trips are supporting evidence.
module Nip49Spec (nip49Spec) where

import Codec.Binary.Bech32 (HumanReadablePart, dataPartFromText, encodeLenient, humanReadablePartFromText)
import Data.Bits (xor)
import qualified Data.ByteArray as BA
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word8)
import Krivostr.Key
import Krivostr.Nip.Nip49
import Test.Hspec

-- | Unwrap an 'Either' for the spec's monad, failing the example with the
-- library's own message. Without it every test either ignores the error channel
-- or hand-rolls a @case@ at each step, and a @Left@ gets reported as an opaque
-- failure far from the call that produced it.
fromRight :: Either String a -> IO a
fromRight = either (ioError . userError) pure

-- | The same unwrap for a top-level constant, where there is no 'IO' to fail in
-- and the value is a literal transcribed from the spec. A mistyped hex digit or
-- bech32 character here is a transcription error in this file, not a runtime
-- condition, so it is right to fail loudly and immediately.
fromRightPure :: Either String a -> a
fromRightPure = either (error . ("bad test vector: " ++)) id

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

-- | Decode an even-length hex 'Text'. A transcription mistake in a vector should
-- be a loud failure, not a test that quietly passes against the wrong bytes.
unhex :: Text -> ByteString
unhex t =
  case B16.decode (TE.encodeUtf8 t) of
    Right bs -> bs
    Left err -> error ("bad hex in test vector: " ++ T.unpack t ++ " (" ++ err ++ ")")

-- | The spec's decryption vector, whole.
--
-- There is no published /encryption/ vector, because encryption is
-- non-deterministic by design: the salt and the nonce are drawn fresh each time.
-- Reproducing the published string on the way back means taking those two fields
-- out of the payload and injecting them again, which is why they are listed
-- separately below.
vectorPassword :: Text
vectorPassword = "nostr"

vectorPayload :: Text
vectorPayload =
  "ncryptsec1qgg9947rlpvqu76pj5ecreduf9jxhselq2nae2kghhvd5g7dgjtcxfqtd67p9m0w57lspw8gsq6yphnm8623nsl8xn9j4jdzz84zm3frztj3z7s35vpzmqf6ksu8r89qk5z2zxfmu5gv8th8wclt0h4p"

-- | Payload bytes 2 through 17. Given as base64, the form the spec quotes it in,
-- and checked against the hex spelling so the two cannot drift apart.
vectorSaltBase64 :: ByteString
vectorSaltBase64 = TE.encodeUtf8 "UtfD+FgOe0GVM4HlvElkaw=="

vectorSalt :: ByteString
vectorSalt = unhex "52d7c3f8580e7b41953381e5bc49646b"

-- | XChaCha nonce the vector used: payload bytes 18 through 41. The extended
-- 24-byte nonce is what lets a sender draw one at random per encryption instead
-- of counting blocks.
vectorNonce :: ByteString
vectorNonce = unhex "c33f02a7dcaac8bdd8da23cd449783240b6ebc12edeea7bf"

-- | The key security byte the vector carries, @0x00@: known to have been handled
-- insecurely. It travels in the clear because a decryptor has to reproduce the
-- derivation, and because it is authenticated data rather than a secret.
vectorSecurity :: KeySecurity
vectorSecurity = KeyHandledInsecurely

vectorPlaintextHex :: Text
vectorPlaintextHex = "3501454135014541350145413501453fefb02227e449e57cf4d3a3ce05378683"

vectorKey :: PrivateKey
vectorKey = fromRightPure (importHex vectorPlaintextHex)

vectorBytes :: ByteString
vectorBytes = fromRightPure (snd <$> decodeNip19 vectorPayload)

-- | Ciphertext and tag together, payload bytes 43 onward.
vectorCiphertext :: ByteString
vectorCiphertext = BS.drop 43 vectorBytes

-- | Cheap scrypt parameters for tests about framing rather than cost.
--
-- @log_n = 8@ is @n = 256@, legal and small enough to keep the suite quick. The
-- cost parameters are not what those tests are checking, and 64 MiB per example
-- buys no extra coverage. Tests that must reproduce the vector use the real
-- @log_n = 16@, because there is nothing cheaper that would.
cheapParams :: ScryptParams
cheapParams = defaultScryptParams {spLogN = 8}

-- | @bytestring@ has no 'BS.cycle', and repeating a byte is clearer written out
-- than via @BS.replicate@ plus a fold.
repeatByte :: Word8 -> Int -> ByteString
repeatByte w n = BS.replicate n w

-- | Replace the byte at an offset. Partial in the index, like 'BS.update' in
-- other containers; every offset here is a literal well inside the payload.
replaceAt :: Int -> Word8 -> ByteString -> ByteString
replaceAt i w bs = BS.take i bs <> BS.singleton w <> BS.drop (i + 1) bs

-- | A fixed salt and nonce for the round trips: 16 and 24 bytes of a repeating
-- pattern, so no test needs a CSPRNG and nothing here looks accidental.
fixedSalt :: ByteString
fixedSalt = repeatByte 0x5a saltLength

fixedNonce :: ByteString
fixedNonce = repeatByte 0x2b nonceLength

-- | Re-emit the vector with its bytes rearranged.
--
-- Re-encoding is legitimate: a bech32 checksum is not a signature, and anyone
-- holding a ciphertext can already produce such strings. That is exactly why
-- authentication, and not the checksum, has to be what rejects them.
reforge :: (ByteString -> ByteString) -> Text
reforge f = encodeNip19 "ncryptsec" (f vectorBytes)

-- | Re-emit the vector with its ciphertext and tag changed.
tamperCiphertext :: (ByteString -> ByteString) -> Text
tamperCiphertext f = reforge (\bs -> BS.take 43 bs <> f (BS.drop 43 bs))

ncryptsecHrp :: HumanReadablePart
ncryptsecHrp = either (error . show) id (humanReadablePartFromText "ncryptsec")

-- | Bech32-encode a raw data-part string with a freshly computed checksum.
--
-- 'encodeNip19' takes bytes, so it can only ever emit a data part that is a whole
-- number of bytes -- exactly the property one of these tests needs to violate.
-- Going through the bech32 API with a data part taken verbatim as text is how to
-- reach that branch: append a character and the payload is 765 bits, not a
-- multiple of eight, yet the checksum over it is entirely correct.
reforgeFromDataText :: Text -> Either String Text
reforgeFromDataText dataText = do
  dp <- maybe (Left "bad data part") Right (dataPartFromText dataText)
  pure (encodeLenient ncryptsecHrp dp)

-- | The vector's data part, checksum characters included, as text.
vectorDataText :: Text
vectorDataText = T.drop (T.length "ncryptsec1") vectorPayload

-- | Round-trip a 'BA.ScrubbedBytes' to hex. The spec's derived key is not
-- published; this is here to localise a failure, and 'BA.convert' is the point
-- where the scrubbing guarantee ends, which is why only a test does it.
keyHex :: BA.ScrubbedBytes -> ByteString
keyHex = B16.encode . BA.convert

nip49Spec :: Spec
nip49Spec = describe "NIP-49 ncryptsec" $ do
  describe "the published vector" $ do
    it "decodes to 91 bytes" $
      BS.length vectorBytes `shouldBe` payloadLength

    it "leads with version 0x02 and log_n 16" $ do
      BS.index vectorBytes 0 `shouldBe` 0x02
      BS.index vectorBytes 1 `shouldBe` 16

    it "puts a 16-byte salt at offset 2 and a 24-byte nonce after it" $ do
      BS.take saltLength (BS.drop 2 vectorBytes) `shouldBe` vectorSalt
      BS.take nonceLength (BS.drop (2 + saltLength) vectorBytes) `shouldBe` vectorNonce

    it "spells that salt the same in hex and base64" $
      fromRightPure (BAE.convertFromBase BAE.Base64 vectorSaltBase64)
        `shouldBe` vectorSalt

    it "is 162 characters, as 91 bytes of bech32 should be" $ do
      -- 10 for the prefix, 146 for 91 bytes at 5 bits each, 6 for the checksum.
      T.length vectorPayload `shouldBe` 162
      T.length vectorDataText `shouldBe` 152

    it "carries 48 bytes of ciphertext, tag included" $
      BS.length vectorCiphertext `shouldBe` (privateKeyLength + tagLength)

    it "decrypts to the published private key" $
      ncPrivateKey <$> decrypt vectorPassword defaultScryptParams vectorPayload
        `shouldBe` Right vectorKey

    it "reports the log_n and key security byte it carries" $ do
      decrypted <- fromRight (decrypt vectorPassword defaultScryptParams vectorPayload)
      ncLogN decrypted `shouldBe` 16
      ncKeySecurity decrypted `shouldBe` vectorSecurity

    it "re-encrypts to the published payload byte for byte" $
      encrypt
        vectorPassword
        vectorKey
        defaultScryptParams
        vectorSecurity
        vectorSalt
        vectorNonce
        `shouldBe` Right vectorPayload

    it "derives the key that ciphertext was sealed under" $ do
      -- Not a published constant, so it cannot be the deciding assertion. It is
      -- here so that a failure says which step broke: if this changes, the
      -- ciphertext stops authenticating rather than becoming something else.
      key <- fromRight (symmetricKey defaultScryptParams vectorPassword vectorSalt)
      keyHex key
        `shouldBe` "6d1e8b279f52b3a9ba60a2b43cab50804a67ac763ff4bafa782475efb0722aff"

    it "does not decrypt under the wrong password" $
      decrypt "not-nostr" defaultScryptParams vectorPayload `shouldSatisfy` isLeft

  describe "round trips" $ do
    it "recovers the key it was given" $ do
      payload <-
        fromRight
          ( encrypt
              vectorPassword
              vectorKey
              cheapParams
              KeyHandlingUntracked
              fixedSalt
              fixedNonce
          )
      ncPrivateKey <$> decrypt vectorPassword cheapParams payload
        `shouldBe` Right vectorKey

    it "is byte-for-byte reproducible for a fixed salt and nonce" $ do
      let encryptWith =
            encrypt vectorPassword vectorKey cheapParams KeyHandledSecurely fixedSalt fixedNonce
      a <- fromRight encryptWith
      b <- fromRight encryptWith
      a `shouldBe` b

    it "differs when only the nonce changes" $ do
      a <-
        fromRight
          (encrypt vectorPassword vectorKey cheapParams KeyHandledSecurely fixedSalt fixedNonce)
      b <-
        fromRight
          ( encrypt
              vectorPassword
              vectorKey
              cheapParams
              KeyHandledSecurely
              fixedSalt
              (BS.init fixedNonce <> BS.singleton 0x2c)
          )
      a `shouldNotBe` b

    it "differs when only the salt changes" $ do
      a <-
        fromRight
          (encrypt vectorPassword vectorKey cheapParams KeyHandledSecurely fixedSalt fixedNonce)
      b <-
        fromRight
          ( encrypt
              vectorPassword
              vectorKey
              cheapParams
              KeyHandledSecurely
              (BS.init fixedSalt <> BS.singleton 0x5b)
              fixedNonce
          )
      a `shouldNotBe` b

    it "emits 91 payload bytes and 162 characters" $ do
      payload <-
        fromRight
          (encrypt vectorPassword vectorKey cheapParams KeyHandledSecurely fixedSalt fixedNonce)
      (_, bytes) <- fromRight (decodeNip19 payload)
      BS.length bytes `shouldBe` payloadLength
      T.length payload `shouldBe` 162

    it "carries the log_n it was encrypted with" $ do
      let params = cheapParams {spLogN = 10}
      payload <-
        fromRight (encrypt vectorPassword vectorKey params KeyHandledSecurely fixedSalt fixedNonce)
      ncLogN <$> decrypt vectorPassword cheapParams payload `shouldBe` Right 10

    it "takes log_n from the payload, not from the caller's parameters" $ do
      -- The vector says log_n 16 while cheapParams says 8, and it still has to
      -- decrypt: the payload is the authority on what its key was derived with,
      -- and honouring the caller's copy would fail for no visible reason.
      ncLogN <$> decrypt vectorPassword cheapParams vectorPayload `shouldBe` Right 16

    it "round-trips each key security byte" $
      mapM_
        ( \security -> do
            payload <-
              fromRight
                (encrypt vectorPassword vectorKey cheapParams security fixedSalt fixedNonce)
            decoded <- fromRight (decrypt vectorPassword cheapParams payload)
            ncKeySecurity decoded `shouldBe` security
        )
        [KeyHandledInsecurely, KeyHandledSecurely, KeyHandlingUntracked]

    it "treats the key security byte as authenticated data" $ do
      -- Changing it invalidates the tag rather than the claim. That is the
      -- point: a claim about provenance that can be edited afterwards is worth
      -- nothing.
      decrypt vectorPassword defaultScryptParams (reforge (replaceAt 42 0x01))
        `shouldSatisfy` isLeft

  describe "rejects malformed payloads" $ do
    it "rejects a bad bech32 checksum" $
      -- One character of the data part, nothing else touched.
      decrypt vectorPassword defaultScryptParams (T.replace "qgg9" "qgg8" vectorPayload)
        `shouldSatisfy` isLeft

    it "rejects a character outside the bech32 alphabet" $
      decrypt vectorPassword defaultScryptParams (T.replace "qgg9" "bgg9" vectorPayload)
        `shouldSatisfy` isLeft

    it "rejects a string that mixes cases" $
      -- All-uppercase is legal bech32 and does decode, but upper here and lower
      -- there is not a representation of anything.
      decrypt
        vectorPassword
        defaultScryptParams
        (T.toUpper (T.take 20 vectorPayload) <> T.drop 20 vectorPayload)
        `shouldSatisfy` isLeft

    it "rejects the wrong human-readable part" $
      -- Same bytes, different prefix. bech32 checksums cover the prefix, so this
      -- is a well-formed string for a scheme we do not implement.
      decrypt
        vectorPassword
        defaultScryptParams
        ("nsecret" <> vectorDataText)
        `shouldSatisfy` isLeft

    it "rejects an oversized string before decoding it" $
      decrypt vectorPassword cheapParams (T.replicate (maxNcryptsecChars + 1) "q")
        `shouldBe` Left "NIP-49 payload exceeds the accepted size"

    it "rejects a data part that is not a whole number of bytes" $ do
      -- 153 data characters is 765 bits, not a multiple of eight. The checksum
      -- is correct, so only the conversion to bytes can catch this.
      payload <- fromRight (reforgeFromDataText (vectorDataText <> "q"))
      decrypt vectorPassword cheapParams payload `shouldSatisfy` isLeft

    it "rejects a version byte other than 0x02" $
      mapM_
        (\v -> decrypt vectorPassword defaultScryptParams (reforge (BS.cons v)) `shouldSatisfy` isLeft)
        [0x00, 0x01, 0x03, 0xff]

    it "rejects a payload that is not 91 bytes" $
      mapM_
        ( \bytes ->
            decrypt vectorPassword defaultScryptParams (reforge bytes)
              `shouldSatisfy` isLeft
        )
        [ BS.init
        , BS.drop 1
        , BS.take 90
        , BS.drop 43
        , const (repeatByte 0 payloadLength)
        ]

    it "rejects a truncated ciphertext" $
      -- Dropping whole bytes keeps the field widths legal and the length wrong,
      -- so only the length check can catch it.
      decrypt vectorPassword cheapParams (reforge (BS.take (payloadLength - 1)))
        `shouldSatisfy` isLeft

    it "rejects a ciphertext shorter than the Poly1305 tag" $
      mapM_
        ( \keep ->
            decrypt
              vectorPassword
              cheapParams
              (reforge (\bs -> BS.take (2 + saltLength + nonceLength + 1 + keep) bs))
              `shouldSatisfy` isLeft
        )
        [0, 1, 15, privateKeyLength - 1]

    it "rejects an out-of-range log_n before deriving anything" $
      mapM_
        ( \logN ->
            decrypt vectorPassword cheapParams (reforge (\bs -> replaceAt 1 logN bs))
              `shouldSatisfy` isLeft
        )
        [0x00, maxLogN + 1, 0xff]

    it "rejects an undefined key security byte" $
      mapM_
        (\b -> decrypt vectorPassword cheapParams (reforge (\bs -> replaceAt 42 b bs)) `shouldSatisfy` isLeft)
        [0x03, 0x10, 0xff]

    it "rejects a swapped salt" $
      -- Same shape, same length, different salt: the derivation changes and the
      -- tag cannot match. Log_n is read from the payload, so this really does
      -- run scrypt before failing.
      decrypt
        vectorPassword
        defaultScryptParams
        (reforge (\bs -> BS.take 2 bs <> BS.replicate saltLength 0 <> BS.drop (2 + saltLength) bs))
        `shouldSatisfy` isLeft

    it "rejects a swapped nonce" $
      decrypt
        vectorPassword
        defaultScryptParams
        ( reforge
            (\bs ->
              BS.take (2 + saltLength) bs
                <> BS.replicate nonceLength 0
                <> BS.drop (2 + saltLength + nonceLength) bs
            )
        )
        `shouldSatisfy` isLeft

    it "rejects a single flipped ciphertext bit" $ do
      -- The deciding negative test: one bit in one byte, with salt, nonce and
      -- both header bytes untouched. Only the Poly1305 tag can notice, and it has
      -- to notice without revealing how much of a forgery was correct.
      let tampered = replaceAt 0 (BS.head vectorCiphertext `xor` 0x01) vectorCiphertext
      tampered `shouldNotBe` vectorCiphertext
      decrypt vectorPassword defaultScryptParams (tamperCiphertext (const tampered))
        `shouldSatisfy` isLeft

    it "rejects a single flipped tag bit" $ do
      let tampered = replaceAt (ciphertextLength - 1) 0x00 vectorCiphertext
      decrypt vectorPassword defaultScryptParams (tamperCiphertext (const tampered))
        `shouldSatisfy` isLeft

    it "rejects a swapped ciphertext with its own valid-looking tag" $
      -- Not just bit flips: replacing the whole sealed message must fail too.
      decrypt
        vectorPassword
        defaultScryptParams
        (tamperCiphertext (const (BS.replicate ciphertextLength 0xa5)))
        `shouldSatisfy` isLeft

  describe "rejects bad encryption parameters" $ do
    it "rejects a salt that is not 16 bytes" $
      mapM_
        ( \n ->
            encrypt
              vectorPassword
              vectorKey
              cheapParams
              KeyHandledSecurely
              (BS.replicate n 1)
              fixedNonce
              `shouldSatisfy` isLeft
        )
        [0, 8, 15, 17, 32]

    it "rejects a nonce that is not 24 bytes" $
      mapM_
        ( \n ->
            encrypt
              vectorPassword
              vectorKey
              cheapParams
              KeyHandledSecurely
              fixedSalt
              (BS.replicate n 1)
              `shouldSatisfy` isLeft
        )
        [0, 12, 23, 25, 32]

    it "rejects a salt that is not 16 bytes when deriving" $
      mapM_
        (\n -> symmetricKey cheapParams vectorPassword (BS.replicate n 1) `shouldSatisfy` isLeft)
        [0, 15, 17]

    it "rejects log_n below the scrypt minimum" $
      -- log_n 0 means n = 1, which is not a power of two greater than one.
      -- crypton's Scrypt.generate calls error there -- not an exception this
      -- module could catch -- so a pure core has to refuse before the call.
      symmetricKey cheapParams {spLogN = 0} vectorPassword vectorSalt
        `shouldSatisfy` isLeft

    it "rejects log_n above the memory budget" $
      symmetricKey defaultScryptParams {spLogN = maxLogN + 1} vectorPassword vectorSalt
        `shouldSatisfy` isLeft

    it "rejects log_p above the memory budget" $
      -- p = 1, i.e. log_p 0, is what NIP-49 fixes and what the vector uses; only
      -- larger values are refused, since no other implementation will agree.
      symmetricKey cheapParams {spLogP = maxLogP + 1} vectorPassword vectorSalt
        `shouldSatisfy` isLeft

    it "refuses bad scrypt parameters before touching the KDF" $
      encrypt
        vectorPassword
        vectorKey
        cheapParams {spLogN = 0}
        KeyHandledSecurely
        fixedSalt
        fixedNonce
        `shouldSatisfy` isLeft

    it "rejects an undefined key security byte on its own" $
      mapM_
        (\b -> keySecurityFromByte b `shouldSatisfy` isLeft)
        [0x03, 0x7f, 0xff]

    it "round-trips each defined key security byte" $
      mapM_
        (\security -> keySecurityFromByte (keySecurityByte security) `shouldBe` Right security)
        [KeyHandledInsecurely, KeyHandledSecurely, KeyHandlingUntracked]

