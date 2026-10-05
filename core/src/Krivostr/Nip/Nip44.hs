{-# LANGUAGE OverloadedStrings #-}

-- | NIP-44 v2 encrypted payloads.
--
-- The v2 scheme is deliberately not an AEAD: it is raw ChaCha20 for
-- confidentiality plus HMAC-SHA256 for integrity, with the @aad@ supplied as a
-- concatenation rather than through a cipher mode. That is why this module
-- reaches for @Crypto.Cipher.ChaCha@ and @Crypto.MAC.HMAC@ instead of
-- @Crypto.Cipher.ChaChaPoly1305@ -- an AEAD here would put a Poly1305 tag on
-- the wire where the spec expects an HMAC, and every other implementation would
-- reject the payload.
--
-- Wire format, standard base64 with padding:
--
-- > version(1) = 0x02 || nonce(32) || ciphertext(padded_len) || mac(32)
--
-- The nonce is injected rather than generated here so the module stays pure and
-- the published test vectors stay reproducible; the caller draws it from the
-- OS CSPRNG.
module Krivostr.Nip.Nip44
  ( -- * Conversation keys
    conversationKey
  , conversationKeyWithHex
    -- * Message keys
  , MessageKeys(..)
  , messageKeys
    -- * Padding
  , calcPaddedLen
  , pad
  , unpad
    -- * Payload
  , encryptWithNonce
  , decrypt
    -- * Limits
  , maxPlaintextLength
  , maxPayloadBytes
  ) where

import qualified Crypto.Cipher.ChaCha as ChaCha
import qualified Crypto.KDF.HKDF as HKDF
import qualified Crypto.MAC.HMAC as HMAC
import Crypto.Hash.Algorithms (SHA256)
import qualified Data.ByteArray as BA
import qualified Data.ByteArray.Encoding as BAE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text (Text)
import Data.Word (Word32, Word8)
import Krivostr.Key

-- | The version byte that leads every v2 payload. @0x00@ is reserved and
-- @0x01@ is the deprecated version, so neither may be accepted.
payloadVersion :: Word8
payloadVersion = 0x02

-- | HKDF-Extract is salted with the literal UTF-8 bytes of this string. It is
-- not hashed first and it is not a bech32 prefix.
conversationKeySalt :: BS.ByteString
conversationKeySalt = "nip44-v2"

-- | Derive the 32-byte conversation key from our secret and a peer's x-only
-- public key.
--
-- Symmetric by construction: both sides reach the same bytes because ECDH is,
-- and only the x coordinate of the shared point is used -- the y coordinate is
-- discarded, and so is any hashing of the result before HKDF.
--
-- > conversation_key = hkdf_extract(IKM=shared_x, salt="nip44-v2")
conversationKey :: PrivateKey -> PublicKey -> Either String BS.ByteString
conversationKey sk pk =
  case sharedSecret sk pk of
    Nothing -> Left "peer public key is not a valid curve point"
    Just sharedX -> Right (hkdfExtract conversationKeySalt sharedX)

-- | 'conversationKey' for a peer given as the 64-hex-character string that
-- appears in an event's @pubkey@ field. Relayed events carry hex rather than
-- bech32, so this is the form every decrypt path actually has.
conversationKeyWithHex :: PrivateKey -> Text -> Either String BS.ByteString
conversationKeyWithHex sk peerHex =
  case B16.decode (TE.encodeUtf8 peerHex) of
    Left _ -> Left "peer pubkey is not valid hex"
    Right bytes
      | BS.length bytes /= 32 -> Left "peer pubkey must be 32 bytes"
      | otherwise -> case publicKeyFromBytes bytes of
          Nothing -> Left "peer pubkey is not a valid x-only public key"
          Just pk -> conversationKey sk pk

-- | HKDF-SHA256 extract, pinned to 32 bytes of output.
hkdfExtract :: BS.ByteString -> BS.ByteString -> BS.ByteString
hkdfExtract salt ikm = BA.convert (HKDF.extract salt ikm :: HKDF.PRK SHA256)

-- | HKDF-SHA256 expand, pinned to a concrete output length.
hkdfExpand :: BS.ByteString -> BS.ByteString -> Int -> Either String BS.ByteString
hkdfExpand prk info n =
  case HKDF.toPRK prk :: Maybe (HKDF.PRK SHA256) of
    Nothing -> Left "hkdf pseudorandom key must be exactly the hash length"
    Just p -> pure (BA.convert (HKDF.expand p info n :: BS.ByteString))

-- | The three keys one message derives from the conversation key and a
-- per-message nonce.
data MessageKeys = MessageKeys
  { mkChaChaKey :: !BS.ByteString
  , mkChaChaNonce :: !BS.ByteString
  , mkHmacKey :: !BS.ByteString
  } deriving (Show, Eq)

-- | Expand the conversation key into the 76 bytes NIP-44 slices into
-- chacha_key[0:32], chacha_nonce[32:44] and hmac_key[44:76].
--
-- The nonce doubles as the HKDF @info@ and as the HMAC @aad@, which is what
-- binds a ciphertext to the message it was produced under: a payload encrypted
-- under one nonce cannot be replayed as if it belonged to another.
messageKeys :: BS.ByteString -> BS.ByteString -> Either String MessageKeys
messageKeys convKey nonce
  | BS.length convKey /= 32 = Left "conversation key must be 32 bytes"
  | BS.length nonce /= 32 = Left "nonce must be 32 bytes"
  | otherwise = do
      okm <- hkdfExpand convKey nonce 76
      pure
        MessageKeys
          { mkChaChaKey = BS.take 32 okm
          , mkChaChaNonce = BS.take 12 (BS.drop 32 okm)
          , mkHmacKey = BS.drop 44 okm
          }

-- | The largest plaintext NIP-44 can encode. The extended length prefix is a
-- @u32@, so this is the spec's @2^32 - 1@.
maxPlaintextLength :: Integer
maxPlaintextLength = 4294967295

-- | Longest base64 payload we will even attempt to decode, in bytes of the
-- base64 text.
--
-- This is a resource guard rather than a spec limit, and it belongs *before*
-- the base64 decoder runs. A peer controls this string wholesale; decoding it
-- allocates three quarters of its length before anything has been
-- authenticated, so without this check a single oversized frame costs us
-- unauthenticated heap. 1 MiB of base64 is 768 KiB of plaintext, comfortably
-- above the @max_message_length@ that real relays advertise.
maxPayloadBytes :: Int
maxPayloadBytes = 1024 * 1024

-- | Shortest payload that can hold a version byte, a nonce and a mac.
minPayloadBytes :: Int
minPayloadBytes = 132

-- | Smallest padded plaintext the scheme admits, and the floor that
-- 'calcPaddedLen' returns.
minPaddedLength :: Int
minPaddedLength = 32

-- | @calc_padded_len@ from the spec: round the plaintext up to a chunk that
-- grows in steps of 32 up to 256 bytes of plaintext, and in powers of two
-- divided by 8 beyond that.
--
-- Padding exists to hide the plaintext length, and the chunk schedule is what
-- makes the padded length leak only a little: an attacker comparing two payloads
-- learns "same chunk", not "same message length".
calcPaddedLen :: Int -> Int
calcPaddedLen unpaddedLen
  | unpaddedLen <= minPaddedLength = minPaddedLength
  | otherwise = chunk * ((unpaddedLen - 1) `div` chunk + 1)
  where
    nextPower = 2 ^ (floorLog2 (unpaddedLen - 1) + 1)
    chunk = if nextPower <= 256 then 32 else nextPower `div` 8

-- | Prepend the big-endian length prefix, then zero-fill to 'calcPaddedLen'.
--
-- Lengths below 65536 use a 2-byte prefix. From 65536 up they use a 6-byte
-- prefix whose first two bytes are zero, and that leading zero pair is how the
-- reader tells the two forms apart -- @u16 == 0@ is otherwise not a legal
-- length, which is exactly why it can be used as the discriminator.
pad :: BS.ByteString -> Either String BS.ByteString
pad msg
  | len < 1 = Left "plaintext must not be empty"
  | toInteger len > maxPlaintextLength = Left "plaintext exceeds the NIP-44 maximum"
  | otherwise = Right (prefix <> msg <> BS.replicate (paddedLen - len) 0)
  where
    len = BS.length msg
    paddedLen = calcPaddedLen len
    prefix
      | len < 65536 = word16BE len
      | otherwise = BS.pack [0, 0] <> word32BE len

-- | Strip the prefix and padding, rejecting anything whose declared length and
-- trailing zeros do not agree.
--
-- Every check runs before the corresponding slice is used, which is the point:
-- a hostile payload must not be able to make us index out of range or trust a
-- declared length it does not actually carry.
unpad :: BS.ByteString -> Either String BS.ByteString
unpad padded
  | BS.length padded < 2 = Left "padded plaintext is shorter than its length prefix"
  | short /= 0 = withPrefix 2 (toInteger short)
  | otherwise = do
      extended <- readWord32BE padded 2
      withPrefix 6 extended
  where
    short :: Word32
    short = fromIntegral (BS.index padded 0) * 256 + fromIntegral (BS.index padded 1)

    withPrefix :: Int -> Integer -> Either String BS.ByteString
    withPrefix prefixLen declared = do
      check (declared >= 1) "plaintext length prefix is zero"
      check (declared <= maxPlaintextLength) "plaintext exceeds the NIP-44 maximum"
      check
        (declared <= toInteger (maxBound :: Int))
        "plaintext length does not fit in an Int"
      check (prefixLen + 1 <= BS.length padded) "padded plaintext is shorter than its length prefix"
      let len = fromIntegral declared
      check
        (declared <= toInteger (BS.length padded - prefixLen))
        "declared plaintext is longer than the payload"
      let expected = calcPaddedLen len
      check
        (BS.length padded == prefixLen + expected)
        "padded length does not match calc_padded_len"
      check
        (BS.all (== 0) (BS.drop (prefixLen + len) padded))
        "padding is not all zero bytes"
      pure (BS.take len (BS.drop prefixLen padded))

check :: Bool -> String -> Either String ()
check cond msg = if cond then Right () else Left msg

-- | Encrypt @plaintext@ to @peer@ and return the base64 payload.
--
-- The nonce must be 32 fresh random bytes never before used with this
-- conversation key. Reusing one exposes the ChaCha20 keystream and lets an
-- attacker forge the HMAC for a second message, so this function will not
-- generate a nonce for you -- it cannot be made to do so safely.
encryptWithNonce
  :: PrivateKey -> Text -> BS.ByteString -> BS.ByteString -> Either String Text
encryptWithNonce sk peerHex nonce plaintext = do
  convKey <- conversationKeyWithHex sk peerHex
  padded <- pad plaintext
  keys <- messageKeys convKey nonce
  let ciphertext = chacha20 (mkChaChaKey keys) (mkChaChaNonce keys) padded
      mac = hmacAead (mkHmacKey keys) nonce ciphertext
      wire = BS.concat [BS.singleton payloadVersion, nonce, ciphertext, mac]
  pure (TE.decodeUtf8 (BAE.convertToBase BAE.Base64 wire))

-- | Decrypt a base64 payload that @sk@ should be able to read, given the hex
-- pubkey of the sender.
--
-- Order of operations is deliberate. The payload length is bounded before the
-- base64 decoder runs, the minimum length and the version byte are checked
-- before any key material is derived, and the MAC is compared in constant time
-- before the ciphertext is fed to ChaCha20.
decrypt :: PrivateKey -> Text -> Text -> Either String BS.ByteString
decrypt sk peerHex payload
  | BS.length payloadBytes > maxPayloadBytes =
      Left "NIP-44 payload exceeds the accepted size"
  | T.isPrefixOf "#" payload =
      Left "unsupported NIP-44 payload version"
  | BS.length payloadBytes < minPayloadBytes =
      Left "NIP-44 payload is too short to hold a version, nonce and mac"
  | otherwise = do
      raw <- BAE.convertFromBase BAE.Base64 payloadBytes
      let (version, afterVersion) = BS.splitAt 1 raw
      check (BS.length version == 1 && BS.head version == payloadVersion)
        "unsupported NIP-44 payload version"
      let (nonce, rest) = BS.splitAt 32 afterVersion
          (ciphertext, macPart) = BS.splitAt (BS.length rest - 32) rest
      check (BS.length ciphertext >= minPaddedLength) "NIP-44 ciphertext is too short"
      convKey <- conversationKeyWithHex sk peerHex
      keys <- messageKeys convKey nonce
      let mac = hmacAead (mkHmacKey keys) nonce ciphertext
      -- Constant time: the MAC is attacker-supplied, and a short-circuiting
      -- compare leaks how much of a forgery was correct.
      check (BA.constEq mac macPart) "NIP-44 mac mismatch"
      unpad (chacha20 (mkChaChaKey keys) (mkChaChaNonce keys) ciphertext)
  where
    payloadBytes = TE.encodeUtf8 payload

-- | ChaCha20 over a 256-bit key and the 12-byte RFC 8439 nonce, starting from
-- block counter 0.
--
-- The counter is not passed in: crypton's 'ChaCha.initialize' takes a /round
-- count/ (20 for ChaCha20), and its counter begins at zero. That is what NIP-44
-- requires, and it is what makes a payload a pure function of (key, nonce,
-- plaintext) -- which in turn is what makes the published vectors checkable.
chacha20 :: BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString
chacha20 key nonce msg = fst (ChaCha.combine (ChaCha.initialize 20 key nonce) msg)

-- | @hmac_sha256(key, aad || message)@.
--
-- The 32-byte @aad@ precondition is guaranteed by 'messageKeys', which takes
-- the nonce from the payload and checks its length first.
hmacAead :: BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString
hmacAead key aad message =
  BA.convert (HMAC.hmac key (aad <> message) :: HMAC.HMAC SHA256)

word16BE :: Int -> BS.ByteString
word16BE n = BS.pack [hi, lo]
  where
    v = n `mod` 65536
    hi = fromIntegral (v `div` 256) :: Word8
    lo = fromIntegral v :: Word8

word32BE :: Int -> BS.ByteString
word32BE n = BS.pack [b3, b2, b1, b0]
  where
    v = toInteger n :: Integer
    b3 = byteAt 3 v
    b2 = byteAt 2 v
    b1 = byteAt 1 v
    b0 = byteAt 0 v

byteAt :: Int -> Integer -> Word8
byteAt i v = fromIntegral (v `div` (256 ^ i) `mod` 256)

-- | Read a big-endian @u32@ at an offset, refusing to index out of range.
readWord32BE :: BS.ByteString -> Int -> Either String Integer
readWord32BE bs off
  | off < 0 || off + 4 > BS.length bs = Left "payload is too short to hold a length prefix"
  | otherwise =
      Right (sum [fromIntegral (BS.index bs (off + i)) * 256 ^ (3 - i) | i <- [0 .. 3]])

-- | @floor(log2 n)@ for @n >= 1@, without a floating-point log.
floorLog2 :: Int -> Int
floorLog2 = go 0
  where
    go :: Int -> Int -> Int
    go acc n
      | n <= 1 = acc
      | otherwise = go (acc + 1) (n `div` 2)