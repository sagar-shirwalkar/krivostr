{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Nostr key material: BIP-340 x-only public keys, plus NIP-19 @nsec@ and
-- @npub@ encoding.
--
-- 'PublicKey' is the x-only field element (32 bytes), not a compressed point,
-- so a key that arrives via @importNpub@, via @nprofile@ or via a NIP-01
-- event's @pubkey@ field is byte-for-byte the same value as one derived from
-- a private key. Previously keys were stored as compressed points and the
-- leading @0x02@ was dropped in some paths but re-attached in others, which is
-- what made derived and imported keys disagree.
module Krivostr.Key
  ( PrivateKey
  , PublicKey
  , generatePrivateKey
  , derivePublicKey
  , signSchnorr
  , verifySchnorr
  , importHex
  , exportHex
  , pubKeyHex
  , pubKeyBytes
  , publicKeyFromBytes
  , exportNsec
  , exportNpub
  , importNsec
  , importNpub
  ) where

import Codec.Binary.Bech32
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Krivostr.Schnorr
import System.IO (IOMode(ReadMode), withBinaryFile)

-- | A secret scalar, always in @[1, groupOrder)@.
newtype PrivateKey = PrivateKey Integer
  deriving (Show, Eq)

-- | A BIP-340 x-only public key: a field element in @[0, p)@ that lifts to a
-- curve point.
newtype PublicKey = PublicKey Integer
  deriving (Show, Eq)

-- | Draw a uniformly random secret scalar.
--
-- This is the only impure function in the pure core. It reads 32 bytes from
-- the operating system's CSPRNG rather than pulling in a dependency, and
-- rejection-samples until the scalar lands in range.
generatePrivateKey :: IO PrivateKey
generatePrivateKey = do
  bytes <- withBinaryFile "/dev/urandom" ReadMode $ \h -> BS.hGet h 32
  let d = intFromBytes' bytes
  if isValidSecret d
    then pure (PrivateKey d)
    else generatePrivateKey

-- | Big-endian encoding of an integer in exactly 32 bytes.
bytes32 :: Integer -> BS.ByteString
bytes32 n =
  BS.pack
    [ fromIntegral (n `div` (256 ^ i) `mod` 256)
    | i <- reverse ([0 .. 31] :: [Int])
    ]

intFromBytes' :: BS.ByteString -> Integer
intFromBytes' = BS.foldl' (\acc w -> acc * 256 + fromIntegral w) 0

-- | Drop a private key to its 32-byte big-endian secret.
privateKeyBytes :: PrivateKey -> BS.ByteString
privateKeyBytes (PrivateKey d) = bytes32 d

derivePublicKey :: PrivateKey -> PublicKey
derivePublicKey (PrivateKey d) =
  case publicKeyX d of
    Nothing -> PublicKey 0
    Just x -> PublicKey x

pubKeyBytes :: PublicKey -> BS.ByteString
pubKeyBytes (PublicKey x) = bytes32 x

pubKeyHex :: PublicKey -> Text
pubKeyHex = TE.decodeUtf8 . B16.encode . pubKeyBytes

-- | Parse a 32-byte x-only key. Fails if the bytes are not a valid length or
-- do not lift to a curve point.
publicKeyFromBytes :: BS.ByteString -> Maybe PublicKey
publicKeyFromBytes bs
  | BS.length bs /= 32 = Nothing
  | otherwise =
      let x = intFromBytes' bs
      in if x < fieldPrime && maybe False (const True) (liftX x)
           then Just (PublicKey x)
           else Nothing

-- | Schnorr-sign a 32-byte message. Pure and deterministic: BIP-340 permits
-- zero auxiliary randomness, and a deterministic core keeps events
-- reproducible.
signSchnorr :: PrivateKey -> BS.ByteString -> BS.ByteString
signSchnorr sk msg =
  case signBip340 (privateScalar sk) (BS.replicate 32 0) msg of
    Right sig -> sig
    Left _ -> BS.replicate 64 0

verifySchnorr :: PublicKey -> BS.ByteString -> BS.ByteString -> Bool
verifySchnorr (PublicKey x) msg sig = verifyBip340 x msg sig

privateScalar :: PrivateKey -> Integer
privateScalar (PrivateKey d) = d

importHex :: Text -> Either String PrivateKey
importHex t =
  case B16.decode (TE.encodeUtf8 t) of
    Left e -> Left e
    Right bs
      | BS.length bs /= 32 -> Left "secret key must be 32 bytes"
      | isValidSecret d -> Right (PrivateKey d)
      | otherwise -> Left "invalid secp256k1 secret key"
      where
        d = intFromBytes' bs

exportHex :: PrivateKey -> Text
exportHex = TE.decodeUtf8 . B16.encode . privateKeyBytes

-- | Bech32 with an arbitrary-length payload.
--
-- 'Codec.Binary.Bech32.encode' and 'decode' enforce BIP-173's 90-character
-- ceiling, which is a segwit-address rule and has no business applying to
-- NIP-19: a single-relay @nprofile@ is already 97 characters. The @Lenient@
-- variants enforce only the minimum length.
encodeNip19 :: Text -> BS.ByteString -> Text
encodeNip19 hrp payload =
  case humanReadablePartFromText hrp of
    Left _ -> ""
    Right h -> encodeLenient h (dataPartFromBytes payload)

decodeNip19 :: Text -> Either String (Text, BS.ByteString)
decodeNip19 t =
  case decodeLenient t of
    Left e -> Left (show e)
    Right (h, dp) ->
      case dataPartToBytes dp of
        Nothing -> Left "bech32 payload is not whole bytes"
        Just bs -> Right (humanReadablePartToText h, bs)

-- | @nsec@ bech32.
exportNsec :: PrivateKey -> Text
exportNsec = encodeNip19 "nsec" . privateKeyBytes

-- | @npub@ bech32.
exportNpub :: PublicKey -> Text
exportNpub = encodeNip19 "npub" . pubKeyBytes

importNsec :: Text -> Either String PrivateKey
importNsec t = case decodeNip19 t of
  Left e -> Left e
  Right (hrp, bs)
    | hrp == "nsec" -> importHex (TE.decodeUtf8 (B16.encode bs))
    | otherwise -> Left "wrong hrp"

-- | Decode an @npub@ into a 32-byte x-only key.
importNpub :: Text -> Either String PublicKey
importNpub t = case decodeNip19 t of
  Left e -> Left e
  Right (hrp, bs)
    | hrp == "npub" ->
        case publicKeyFromBytes bs of
          Nothing -> Left "npub is not a valid x-only public key"
          Just pk -> Right pk
    | otherwise -> Left "wrong hrp"
