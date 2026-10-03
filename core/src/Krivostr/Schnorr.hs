{-# LANGUAGE OverloadedStrings #-}

-- | Pure-Haskell BIP-340: Schnorr signatures over secp256k1.
--
-- This module exists because 'Crypto.Secp256k1' cannot do the job. No published
-- version of secp256k1-haskell exposes BIP-340: there is no @schnorrSignMsg@,
-- @schnorrVerify@, @secKeyGen@, @secKeyImport@ or @exportSecKey@, and no
-- release defines a @schnorr@ flag. Binding to @libsecp256k1@'s
-- @secp256k1_schnorrsig_*@ directly would mean a C dependency for one pair of
-- functions.
--
-- Everything is therefore implemented straight from the BIP-340 reference
-- algorithm, in affine coordinates and using the same @pow(a, p-2, p)@ field
-- inverse, so it can be checked line-for-line against
-- @bip-0340/test-vectors.csv@. The module is pure: no FFI, no @IO@ and no
-- 'unsafePerformIO'.
module Krivostr.Schnorr
  ( -- * Group parameters
    fieldPrime
  , groupOrder
  , generator
  , Point
  , pointAdd
  , pointMul
  , liftX
    -- * Keys
  , isValidSecret
  , publicKeyX
    -- * BIP-340
  , taggedHash
  , signBip340
  , verifyBip340
  ) where

import Crypto.Hash.SHA256 (hash)
import qualified Data.ByteString as BS
import Data.Bits (xor)

-- | The secp256k1 field prime, @p = 2^256 - 2^32 - 977@.
fieldPrime :: Integer
fieldPrime =
  0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F

-- | The order of the generator, @n@.
groupOrder :: Integer
groupOrder =
  0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

-- | An affine curve point, @(x, y)@. The point at infinity has no
-- representation here and is modelled as @Nothing@ throughout.
type Point = (Integer, Integer)

generator :: Point
generator =
  ( 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
  , 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
  )

-- | Modular exponentiation by repeated squaring.
powMod :: Integer -> Integer -> Integer -> Integer
powMod b0 e0 m = go (b0 `mod` m) e0
  where
    go _ 0 = 1
    go b e
      | odd e = (b * go b (e - 1)) `mod` m
      | otherwise = let h = go b (e `div` 2) in (h * h) `mod` m

-- | Field inversion, @a^-1 = a^(p-2)@, as in the BIP-340 reference code.
invert :: Integer -> Integer
invert = \a -> powMod a (fieldPrime - 2) fieldPrime

-- | Point addition in affine coordinates. Returns 'Nothing' for the point at
-- infinity, which is what the reference implementation calls @None@.
pointAdd :: Maybe Point -> Maybe Point -> Maybe Point
pointAdd Nothing p = p
pointAdd p Nothing = p
pointAdd (Just (x1, y1)) (Just (x2, y2))
  | x1 == x2 && y1 /= y2 = Nothing
  | otherwise =
      let lambda
            | x1 == x2 = (3 * x1 * x1) * invert (2 * y1)
            | otherwise = (y2 - y1) * invert (x2 - x1)
          lambda' = lambda `mod` fieldPrime
          x3 = (lambda' * lambda' - x1 - x2) `mod` fieldPrime
          y3 = (lambda' * (x1 - x3) - y1) `mod` fieldPrime
      in Just (x3, y3)

-- | Double-and-add scalar multiplication. 'Nothing' when @n <= 0@.
pointMul :: Point -> Integer -> Maybe Point
pointMul p0 n0
  | n0 <= 0 = Nothing
  | otherwise = loop (Just p0) n0 Nothing
  where
    loop _ 0 acc = acc
    loop mp n acc =
      let doubled = pointAdd mp mp
      in if odd n
           then loop doubled (n `div` 2) (pointAdd acc mp)
           else loop doubled (n `div` 2) acc

-- | Recover the even-y curve point for an x-only public key, or 'Nothing' if
-- no such point exists on the curve.
liftX :: Integer -> Maybe Point
liftX x
  | x >= fieldPrime = Nothing
  | otherwise =
      let ySq = (powMod x 3 fieldPrime + 7) `mod` fieldPrime
          y = powMod ySq ((fieldPrime + 1) `div` 4) fieldPrime
      in if powMod y 2 fieldPrime /= ySq
           then Nothing
           else Just (x, if y `mod` 2 == 0 then y else fieldPrime - y)

isValidSecret :: Integer -> Bool
isValidSecret d = d > 0 && d < groupOrder

-- | The x-only (BIP-340) public key for a secret scalar.
publicKeyX :: Integer -> Maybe Integer
publicKeyX d = fst <$> pointMul generator d

-- | @SHA256(SHA256(tag) || SHA256(tag) || msg)@.
taggedHash :: BS.ByteString -> BS.ByteString -> BS.ByteString
taggedHash tag msg =
  let th = hash tag
  in hash (th <> th <> msg)

-- | Big-endian 32-byte encoding, as in @bytes_from_int@.
--
-- The exponent must run from 31 down to 0: index 0 of the resulting
-- 'BS.ByteString' is the most significant byte.
bytesFromInt :: Integer -> BS.ByteString
bytesFromInt i =
  BS.pack
    [ fromIntegral (i `div` (256 ^ n) `mod` 256)
    | n <- reverse ([0 .. 31] :: [Int])
    ]

intFromBytes :: BS.ByteString -> Integer
intFromBytes = BS.foldl' (\acc w -> acc * 256 + fromIntegral w) 0

xorBytes :: BS.ByteString -> BS.ByteString -> BS.ByteString
xorBytes a b = BS.pack (BS.zipWith xor a b)

-- | Produce a 64-byte BIP-340 signature.
--
-- @auxRand@ is the 32 bytes of auxiliary randomness; callers with no source for
-- it pass 32 zero bytes, which BIP-340 permits (the nonce is then
-- deterministic).
--
-- The message may be any length: @tagged_hash@ accepts arbitrary input, and
-- test vectors 15-18 exercise that. Nostr always passes a 32-byte SHA-256.
signBip340 ::
  Integer ->
  BS.ByteString ->
  BS.ByteString ->
  Either String BS.ByteString
signBip340 d0 aux msg
  | BS.length aux /= 32 = Left "BIP-340: aux_rand must be 32 bytes"
  | not (isValidSecret d0) = Left "BIP-340: secret key out of range"
  | otherwise =
      case pointMul generator d0 of
        Nothing -> Left "BIP-340: secret key has no public point"
        Just (px, py) ->
          -- BIP-340 fixes the secret to the one whose public point has even y,
          -- so negate d0 when 3G-style odd-y points come up. Signing with
          -- x(P) directly instead produces signatures that no verifier -- and
          -- no other Nostr implementation -- accepts.
          let d = if py `mod` 2 == 0 then d0 else groupOrder - d0
              t = xorBytes (bytesFromInt d) (taggedHash "BIP0340/aux" aux)
              k0 =
                intFromBytes
                  (taggedHash "BIP0340/nonce" (t <> bytesFromInt px <> msg))
                  `mod` groupOrder
          in if k0 == 0
               then Left "BIP-340: nonce k_0 is zero"
               else
                 case pointMul generator k0 of
                   Nothing -> Left "BIP-340: nonce has no curve point"
                   Just (rx, ry) ->
                     let k =
                           if ry `mod` 2 == 0
                             then k0
                             else groupOrder - k0
                         e =
                           intFromBytes
                             ( taggedHash
                                 "BIP0340/challenge"
                                 (bytesFromInt rx <> bytesFromInt px <> msg)
                             )
                             `mod` groupOrder
                     in Right
                          ( bytesFromInt rx
                              <> bytesFromInt ((k + e * d) `mod` groupOrder)
                          )

-- | Verify a 64-byte BIP-340 signature against an x-only public key.
verifyBip340 :: Integer -> BS.ByteString -> BS.ByteString -> Bool
verifyBip340 pubX msg sig
  | BS.length sig /= 64 = False
  | r >= fieldPrime = False
  | s >= groupOrder = False
  | otherwise =
      case liftX pubX of
        Nothing -> False
        Just p ->
          let e =
                intFromBytes
                  ( taggedHash
                      "BIP0340/challenge"
                      (BS.take 32 sig <> bytesFromInt pubX <> msg)
                  )
                  `mod` groupOrder
              rp = pointAdd (pointMul generator s) (pointMul p (groupOrder - e))
          in case rp of
               Nothing -> False
               Just (rx, ry) -> ry `mod` 2 == 0 && rx == r
  where
    r = intFromBytes (BS.take 32 sig)
    s = intFromBytes (BS.drop 32 sig)
