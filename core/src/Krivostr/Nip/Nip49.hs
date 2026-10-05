{-# LANGUAGE OverloadedStrings #-}

-- | NIP-49 encrypted private keys: the @ncryptsec1@ bech32 payload.
--
-- This is a transport encoding, NOT encryption at rest. The payload carries the
-- password-derived key's cost parameters in the clear, so anybody who holds the
-- @ncryptsec1@ string can attack the password offline at leisure, and a
-- published @ncryptsec1@ hands an attacker one target per guess. Keep the
-- decrypted secret in a store that protects it on disk; use this to move it
-- between machines, and nothing else.
--
-- The scheme is @scrypt@ followed by XChaCha20-Poly1305:
--
-- > SYMMETRIC_KEY = scrypt(password, salt, n = 2^LOG_N, r = 8, p = 1)
-- > CIPHERTEXT    = XChaCha20-Poly1305(key     = SYMMETRIC_KEY,
-- >                                   nonce    = NONCE,
-- >                                   aad      = KEY_SECURITY_BYTE,
-- >                                   plaintext = PRIVATE_KEY)
--
-- and the bech32 payload is, byte for byte:
--
-- > version(1) = 0x02 || log_n(1) || salt(16) || nonce(24)
-- >            || key_security_byte(1) || ciphertext(32) || tag(16)
--
-- which is 91 bytes before bech32 and 152 characters after it. Both @log_n@ and
-- the key security byte travel in the clear because a decryptor has to
-- reproduce the key derivation, and because the security byte is authenticated
-- data rather than a secret.
--
-- The salt and the nonce are injected rather than generated, which is what keeps
-- this module pure and the spec's published vector reproducible: the caller
-- draws both from the OS CSPRNG. Every failure is a 'Left' -- no @error@, no
-- exceptions, no @unsafePerformIO@ on any path.
module Krivostr.Nip.Nip49
  ( -- * scrypt parameters
    ScryptParams(..)
  , defaultScryptParams
  , minLogN
  , maxLogN
  , maxLogP
  , maxScryptMemoryBytes
    -- * Sizes
  , saltLength
  , nonceLength
  , tagLength
  , privateKeyLength
  , ciphertextLength
  , payloadLength
  , maxNcryptsecChars
    -- * Key security
  , KeySecurity(..)
  , keySecurityByte
  , keySecurityFromByte
    -- * Key derivation
  , symmetricKey
    -- * Payload
  , Ncryptsec(..)
  , encrypt
  , decrypt
  ) where

import qualified Crypto.Cipher.ChaChaPoly1305 as CP
import Crypto.Error (CryptoFailable, eitherCryptoError)
import qualified Crypto.KDF.Scrypt as Scrypt
import qualified Crypto.MAC.Poly1305 as P1305
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64, Word8)
import Krivostr.Key

-- | The version byte every NIP-49 payload leads with. The spec defines only
-- @0x02@, so any other byte is a payload from a version of the scheme we do not
-- implement -- there is nothing to fall back to.
ncryptsecVersion :: Word8
ncryptsecVersion = 0x02

-- | The bech32 human-readable part.
hrp :: Text
hrp = "ncryptsec"

-- | Salt length in bytes. Fixed by the spec at 16 and not chosen by the caller:
-- the salt is a nonce for the KDF here, not a security parameter.
saltLength :: Int
saltLength = 16

-- | XChaCha nonce length in bytes. The extended 24-byte nonce is what lets the
-- caller draw a nonce at random per encryption rather than counting blocks.
nonceLength :: Int
nonceLength = 24

-- | Poly1305 tag length in bytes.
tagLength :: Int
tagLength = 16

-- | The plaintext is a raw secp256k1 secret: exactly 32 bytes, no prefix and no
-- hex. (@1 || key@ is how an @nsec@ payload encodes a key; this one does not.)
privateKeyLength :: Int
privateKeyLength = 32

-- | @ciphertext@ on the wire, tag included.
ciphertextLength :: Int
ciphertextLength = privateKeyLength + tagLength

-- | Payload length before bech32: version, @log_n@, salt, nonce, security byte
-- and ciphertext. The spec fixes this at 91, which is what lets a length check
-- be a real structural check rather than a heuristic.
payloadLength :: Int
payloadLength = 1 + 1 + saltLength + nonceLength + 1 + ciphertextLength

-- | Longest @ncryptsec1@ text we will even attempt to decode, in characters.
--
-- A resource guard, not a spec limit, and it belongs /before/ the bech32 decoder
-- runs: decoding allocates per input character and this string is
-- attacker-supplied, so without the bound one oversized frame costs
-- unauthenticated heap. A real payload is 'payloadLength' bytes, which is 152
-- characters, so this leaves generous room for a future version marker.
maxNcryptsecChars :: Int
maxNcryptsecChars = 1024

-- | Smallest @n = 2^log_n@ scrypt admits. @n = 1@ is not a power of two greater
-- than one and crypton rejects it.
minLogN :: Word8
minLogN = 1

-- | Largest @log_n@ accepted. @2^22@ is the top of the spec's own table at 4 GiB
-- of memory; above that it stops being a trade-off and becomes a denial of
-- service on whoever opens the payload.
maxLogN :: Word8
maxLogN = 22

-- | Largest @log_p@ accepted, giving @p = 2^log_p@ up to 256.
maxLogP :: Word8
maxLogP = 8

-- | Hard ceiling on scrypt's memory footprint in bytes: @128 * n * r@ for @B@
-- plus @256 * r * p@ for @XY@, with @r = 8@.
--
-- @2^32@ is 4 GiB, the cost of the spec's largest @log_n@. It is checked in
-- addition to the per-field bounds because @log_n@ and @log_p@ are independent:
-- a caller can pair two legal values and still ask for an unreasonable amount of
-- work.
maxScryptMemoryBytes :: Integer
maxScryptMemoryBytes = 4294967296

-- | scrypt parameters for one derivation.
--
-- @spLogN@ is the exponent written into the payload as @log_n@; a decryptor
-- reads it back rather than being told. @spLogP@ is /not/ carried in the
-- payload, because NIP-49 fixes @p = 1@ -- that is @spLogP = 0@ -- so the field
-- exists to be validated, and to keep the door open for a revision that does
-- record it. 'defaultScryptParams' is the only value that interoperates with
-- other implementations today.
data ScryptParams = ScryptParams
  { spLogN :: !Word8
  , spLogP :: !Word8
  }
  deriving (Show, Eq)

-- | @log_n = 16@, @log_p = 0@: 64 MiB of memory and roughly 100 ms on a fast
-- machine. This is the spec's recommended default and what the published vector
-- uses.
defaultScryptParams :: ScryptParams
defaultScryptParams = ScryptParams {spLogN = 16, spLogP = 0}

-- | Whether the caller believes the secret was ever handled in the clear.
--
-- This is authenticated data, not a secret: it is the AEAD's associated data, so
-- flipping it invalidates the tag rather than changing the recovered key. That is
-- deliberate -- the byte is a claim about provenance, and a claim that can be
-- edited after the fact is worth nothing.
data KeySecurity
  = -- | @0x00@: known to have been handled insecurely -- stored unencrypted,
    -- pasted unencrypted, and so on.
    KeyHandledInsecurely
  | -- | @0x01@: not known to have been handled insecurely. Not a positive claim
    -- of safety, only the absence of a known exposure.
    KeyHandledSecurely
  | -- | @0x02@: the client does not track this.
    KeyHandlingUntracked
  deriving (Show, Eq)

-- | The on-wire byte for a 'KeySecurity'.
keySecurityByte :: KeySecurity -> Word8
keySecurityByte KeyHandledInsecurely = 0x00
keySecurityByte KeyHandledSecurely = 0x01
keySecurityByte KeyHandlingUntracked = 0x02

-- | Read a key security byte out of a payload, rejecting anything the spec does
-- not define. An undefined value is not a default to guess at: it means we are
-- reading a payload from a version of the scheme we do not know.
keySecurityFromByte :: Word8 -> Either String KeySecurity
keySecurityFromByte 0x00 = Right KeyHandledInsecurely
keySecurityFromByte 0x01 = Right KeyHandledSecurely
keySecurityFromByte 0x02 = Right KeyHandlingUntracked
keySecurityFromByte w = Left ("undefined NIP-49 key security byte " ++ show w)

-- | A decrypted @ncryptsec@ payload.
--
-- @ncLogN@ is reported because the cost of the derivation is part of what the
-- payload says. A client that re-encrypts under a different @log_n@ than it
-- decrypted under silently changes how hard the secret is to attack, so the value
-- belongs with the result rather than being forgotten.
data Ncryptsec = Ncryptsec
  { ncPrivateKey :: PrivateKey
  , ncLogN :: Word8
  , ncKeySecurity :: KeySecurity
  }
  deriving (Show, Eq)

check :: Bool -> String -> Either String ()
check cond msg = if cond then Right () else Left msg

-- | Reject scrypt parameters before they reach crypton.
--
-- 'Scrypt.generate' goes through FFI and calls @error@ -- not an exception this
-- module could catch -- on invalid parameters: @n@ that is not a power of two, or
-- @r * p@ at or above @2^30@. The core is pure, so there is no way to catch that
-- and every bound crypton relies on is checked here and reported as a 'Left'
-- instead.
--
-- The upper bounds are ours rather than crypton's, because @log_n@ arrives inside
-- an attacker-supplied payload: accepting @log_n = 30@ would let a single string
-- ask for a terabyte of allocation.
validateScrypt :: ScryptParams -> Either String ()
validateScrypt params = do
  check
    (spLogN params >= minLogN)
    ("scrypt log_n must be at least " ++ show minLogN)
  check
    (spLogN params <= maxLogN)
    ("scrypt log_n must be at most " ++ show maxLogN)
  check
    (spLogP params <= maxLogP)
    ("scrypt log_p must be at most " ++ show maxLogP)
  check
    (scryptMemoryBytes params <= maxScryptMemoryBytes)
    "scrypt parameters exceed the accepted memory budget"

-- | @128 * n * r + 256 * r * p@ with @r = 8@, in 'Integer' so the bound is
-- checked without overflowing an 'Int' on the way.
scryptMemoryBytes :: ScryptParams -> Integer
scryptMemoryBytes params =
  128 * n * 8 + 256 * 8 * p
  where
    n :: Integer
    n = 2 ^ logN
    p :: Integer
    p = 2 ^ logP
    logN :: Int
    logN = fromIntegral (spLogN params)
    logP :: Int
    logP = fromIntegral (spLogP params)

-- | Derive the 32-byte symmetric key for @password@ and @salt@.
--
-- The result is a 'BA.ScrubbedBytes' rather than a 'ByteString', so it is zeroed
-- when it goes out of scope. That is the spec's "should be zeroed and discarded
-- after use" made into a type: a caller that wants raw bytes has to
-- 'BA.convert' them, and the conversion is the point at which the scrubbing
-- guarantee ends.
--
-- The password is used as its UTF-8 bytes, which is what every other Nostr
-- implementation does. The spec additionally asks for NFKC normalisation first, so
-- that the same password typed on two machines derives the same key; @text@
-- carries no normaliser and the core takes no new dependency for one, so the
-- caller must normalise. Skipping it is only visible for passwords containing
-- compatibility characters, where it yields a key no other client can derive.
symmetricKey
  :: ScryptParams
  -> Text
  -> ByteString
  -> Either String BA.ScrubbedBytes
symmetricKey params password salt = do
  validateScrypt params
  check
    (BS.length salt == saltLength)
    ("NIP-49 salt must be " ++ show saltLength ++ " bytes")
  pure
    ( Scrypt.generate
        (Scrypt.Parameters n r p symmetricKeyLength)
        (TE.encodeUtf8 password)
        salt
        :: BA.ScrubbedBytes
    )
  where
    n :: Word64
    n = 2 ^ logN
    r = 8
    p = 2 ^ logP
    logN :: Int
    logN = fromIntegral (spLogN params)
    logP :: Int
    logP = fromIntegral (spLogP params)
    symmetricKeyLength = 32

-- | Encrypt @sk@ under @password@ into a @ncryptsec1@ bech32 payload.
--
-- @salt@ must be 'saltLength' fresh random bytes and @nonce@ 'nonceLength'
-- fresh random bytes, both from the caller's OS CSPRNG and neither reused for
-- another encryption. The nonce in particular is not a counter: a repeated
-- (key, nonce) pair under XChaCha20-Poly1305 leaks the keystream and lets an
-- attacker forge the tag for a second payload, so this function will not
-- generate them -- it cannot make them safely.
--
-- @spLogN params@ goes into the payload. @spLogP params@ is validated and used
-- but not recorded, because NIP-49 fixes @p = 1@.
encrypt
  :: Text
  -> PrivateKey
  -> ScryptParams
  -> KeySecurity
  -> ByteString
  -> ByteString
  -> Either String Text
encrypt password sk params security salt nonce = do
  key <- symmetricKey params password salt
  check
    (BS.length nonce == nonceLength)
    ("NIP-49 nonce must be " ++ show nonceLength ++ " bytes")
  ciphertext <- aeadEncrypt key (keySecurityByte security) nonce (privateKeyBytes sk)
  payload <-
    encodePayload
      ( BS.concat
          [ BS.singleton ncryptsecVersion
          , BS.singleton (spLogN params)
          , salt
          , nonce
          , BS.singleton (keySecurityByte security)
          , ciphertext
          ]
      )
  pure payload

-- | Decrypt a @ncryptsec1@ payload with @password@.
--
-- @spLogP params@ must match what the encryptor used. @spLogN params@ is
-- ignored, because the payload carries its own @log_n@ and that is the value the
-- key is actually derived with -- trusting the caller's copy instead would let a
-- caller ask for a cheap derivation and then fail for no visible reason.
--
-- The order of the checks is deliberate. Length, human-readable part, version,
-- the @log_n@ claim and every field width are settled before a byte of key
-- material is derived, so a malformed payload cannot make us spend scrypt's
-- memory or time. The Poly1305 tag is compared in constant time before the
-- plaintext is returned.
decrypt :: Text -> ScryptParams -> Text -> Either String Ncryptsec
decrypt password params payload
  | T.length payload > maxNcryptsecChars =
      Left "NIP-49 payload exceeds the accepted size"
  | otherwise = do
      (payloadHrp, bytes) <- decodeNip19 payload
      check (payloadHrp == hrp) "wrong hrp"
      check
        (BS.length bytes == payloadLength)
        ("NIP-49 payload must be " ++ show payloadLength ++ " bytes")
      check
        (BS.index bytes 0 == ncryptsecVersion)
        "unsupported NIP-49 payload version"
      let logN = BS.index bytes 1
          (salt, afterSalt) = BS.splitAt saltLength (BS.drop 2 bytes)
          (nonce, afterNonce) = BS.splitAt nonceLength afterSalt
          (securityByte, ciphertext) = BS.splitAt 1 afterNonce
      -- Bound the attacker's own cost claim before deriving anything from it.
      check
        (logN >= minLogN && logN <= maxLogN)
        "NIP-49 payload claims an out-of-range scrypt log_n"
      check
        (BS.length securityByte == 1)
        "NIP-49 payload has no key security byte"
      security <- keySecurityFromByte (BS.head securityByte)
      key <- symmetricKey params {spLogN = logN} password salt
      plaintext <- aeadDecrypt key securityByte nonce ciphertext
      sk <- privateKeyFromBytes plaintext
      pure
        Ncryptsec
          { ncPrivateKey = sk
          , ncLogN = logN
          , ncKeySecurity = security
          }

-- | Read a decrypted payload's private key, rejecting a plaintext that is not
-- exactly a secp256k1 secret. The length is already implied by the payload
-- length check; the range is not.
privateKeyFromBytes :: ByteString -> Either String PrivateKey
privateKeyFromBytes bytes = do
  check
    (BS.length bytes == privateKeyLength)
    ("decrypted NIP-49 key must be " ++ show privateKeyLength ++ " bytes")
  importHex (TE.decodeUtf8 (B16.encode bytes))

-- | Encode a payload as bech32, refusing the empty string 'encodeNip19' returns
-- when the human-readable part is unusable. Returning that silently would hand
-- the caller a payload that decodes to nothing.
encodePayload :: ByteString -> Either String Text
encodePayload bytes
  | T.null encoded = Left "cannot bech32-encode an NIP-49 payload"
  | otherwise = Right encoded
  where
    encoded = encodeNip19 hrp bytes

-- | XChaCha20-Poly1305 encrypt with the tag appended.
--
-- @finalizeAAD@ has to run between @appendAAD@ and @encrypt@: crypton keys the
-- two lengths it writes into the tag off that point, and calling it afterwards
-- silently produces a tag no other implementation will accept.
aeadEncrypt
  :: BA.ScrubbedBytes
  -> Word8
  -> ByteString
  -> ByteString
  -> Either String ByteString
aeadEncrypt key aadByte nonce plaintext = do
  xnonce <- crypto (CP.nonce24 nonce)
  state <- crypto (CP.initializeX key xnonce)
  let sealed = CP.finalizeAAD (CP.appendAAD (BS.singleton aadByte) state)
      (ciphertext, sealed') = CP.encrypt plaintext sealed
  pure (ciphertext <> tagOf sealed')

-- | XChaCha20-Poly1305 decrypt and authenticate.
--
-- crypton's low-level 'CP.decrypt' returns plaintext whether or not the tag
-- checks out, so the tag is verified here -- in constant time -- before the
-- plaintext is handed back.
aeadDecrypt
  :: BA.ScrubbedBytes
  -> ByteString
  -> ByteString
  -> ByteString
  -> Either String ByteString
aeadDecrypt key aad nonce sealed = do
  check
    (BS.length sealed >= tagLength)
    "NIP-49 ciphertext is shorter than the Poly1305 tag"
  xnonce <- crypto (CP.nonce24 nonce)
  state <- crypto (CP.initializeX key xnonce)
  let (ciphertext, tag) = BS.splitAt (BS.length sealed - tagLength) sealed
      opened = CP.finalizeAAD (CP.appendAAD aad state)
      (plaintext, opened') = CP.decrypt ciphertext opened
  expected <- crypto (P1305.authTag tag)
  -- Constant time: the tag is attacker-supplied, and a short-circuiting compare
  -- would leak how much of a forgery was correct.
  check
    (BA.constEq (tagOf opened') expected)
    "NIP-49 authentication tag mismatch"
  pure plaintext

tagOf :: CP.State -> ByteString
tagOf = BA.convert . CP.finalize

-- | Turn crypton's 'CryptoFailable' into this module's 'Either' 'String'.
--
-- Rendering a 'Crypto.Error.CryptoError' as a string is acceptable here because
-- none of these paths allocate on failure and the result is for a human reading
-- a log, not for control flow.
crypto :: CryptoFailable a -> Either String a
crypto = either (Left . show) Right . eitherCryptoError