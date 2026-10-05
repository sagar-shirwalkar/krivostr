{-# LANGUAGE OverloadedStrings #-}

-- | NIP-13 proof of work.
--
-- Difficulty is a property of the NIP-01 /id/: the number of leading zero
-- /bits/ in its 32-byte SHA-256. That is the SHA-256 of the canonical bytes,
-- not the canonical bytes themselves. Counting zero /nibbles/ instead of zero
-- bits, or zero /bytes/ instead of zero bits, both give plausible-looking
-- wrong answers at the boundaries, so 'leadingZeroBits' counts bit by bit and
-- 'leadingZeroBitsHex' is a transcription of the spec's JavaScript reference
-- implementation to cross-check it against.
--
-- Mining is a bounded, pure search over the nonce tag's counter. Only the
-- starting point and the give-up point are choices, and both are arguments, so
-- the search itself needs no IO; the client owns the wall-clock budget.
module Krivostr.Nip.Nip13
  ( -- * Difficulty
    leadingZeroBits
  , leadingZeroBitsHex
  , difficultyOfHash
  , difficultyOfEvent
  , difficultyOfId
    -- * The nonce tag
  , nonceTag
  , parseNonce
  , targetDifficulty
    -- * Validation
  , hasWork
  , hasCommittedWork
    -- * Mining
  , mine
  , maxReasonableDifficulty
  ) where

import Crypto.Hash.SHA256 (hash)
import Data.Bits (countLeadingZeros)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word8, Word64)
import Krivostr.Event
import Krivostr.Nip.Nip01

-- | Above this, mining a note is not something to make a user wait for. It
-- bounds the search only; validation still accepts any difficulty.
maxReasonableDifficulty :: Int
maxReasonableDifficulty = 64

-- | Leading zero bits in a 32-byte hash, counting across byte boundaries.
--
-- The answer is the length of the run of zero bytes at the front, times eight,
-- plus the leading zero bits of the single byte that ends that run.
--
-- Both halves are needed and neither is optional. Folding over the whole
-- 'ByteString' sums the leading zeros of /every/ byte and reports more bits than
-- the hash is wide; truncating to the zero run and stopping throws away the
-- partial byte, which is where bits 17 through 24 of a typical difficulty live.
-- A test short enough to end on a byte with no leading zeros hides both bugs.
leadingZeroBits :: BS.ByteString -> Int
leadingZeroBits bs = 8 * BS.length zeros + partial
  where
    zeros = BS.takeWhile (== (0 :: Word8)) bs
    partial = case BS.uncons (BS.drop (BS.length zeros) bs) of
      Nothing    -> 0
      Just (b, _) -> countLeadingZeros b

-- | The spec's JavaScript reference implementation, kept as an independent
-- cross-check. Input is hex with no @0x@ prefix; 'Nothing' if it is empty or
-- contains a non-hex character.
leadingZeroBitsHex :: Text -> Maybe Int
leadingZeroBitsHex t = do
  hexes <- traverse nibble (T.unpack t)
  let zeros = takeWhile (== 0) hexes
      partial = case drop (length zeros) hexes of
        []      -> 0
        (v : _) -> countLeadingZeros (fromIntegral v :: Word8) - 4
  if null hexes
    then Nothing
    else Just (4 * length zeros + partial)
  where
    nibble c
      | c >= '0' && c <= '9' = Just (fromEnum c - fromEnum '0')
      | c >= 'a' && c <= 'f' = Just (fromEnum c - fromEnum 'a' + 10)
      | c >= 'A' && c <= 'F' = Just (fromEnum c - fromEnum 'A' + 10)
      | otherwise = Nothing

difficultyOfHash :: BS.ByteString -> Int
difficultyOfHash = leadingZeroBits

-- | Difficulty of an event, recomputed from its canonical bytes.
--
-- Recomputing rather than reading @evId@ matters: the id is attacker-supplied
-- until 'verifyEvent' has run, and a relay that counted leading zeros in a
-- forged id field would accept zero work.
difficultyOfEvent :: Event -> Int
difficultyOfEvent = leadingZeroBits . hash . canonicalBytes

-- | Difficulty implied by an id the caller has already verified.
difficultyOfId :: Text -> Maybe Int
difficultyOfId t = leadingZeroBitsHex t

-- | The nonce tag for a counter and a committed target difficulty.
--
-- The third element is the /target/, not the achieved difficulty. Miners
-- commit before mining so a spammer cannot mine cheaply at a low target and
-- pass the result off as high-difficulty work.
nonceTag :: Word64 -> Int -> [Text]
nonceTag counter target =
  ["nonce", T.pack (show counter), T.pack (show target)]

-- | The nonce tag's counter, or 'Nothing' if the tag is absent or the counter
-- is not a plain decimal number.
parseNonce :: Event -> Maybe Word64
parseNonce e = do
  rest <- firstNonce e
  counter <- listToMaybe' rest
  readDecimal counter

-- | The committed target difficulty, or 'Nothing' if the tag is absent or the
-- third element is not a plain decimal number.
targetDifficulty :: Event -> Maybe Int
targetDifficulty e = do
  rest <- firstNonce e
  _counter <- listToMaybe' rest
  target <- maybeRest rest
  readInt target

firstNonce :: Event -> Maybe [Text]
firstNonce e =
  case [rest | ("nonce" : rest) <- evTags e] of
    (rest : _) -> Just rest
    _          -> Nothing

listToMaybe' :: [a] -> Maybe a
listToMaybe' (x : _) = Just x
listToMaybe' []      = Nothing

maybeRest :: [a] -> Maybe a
maybeRest (_ : xs) = listToMaybe' xs
maybeRest []       = Nothing

-- | Does the event carry at least @bits@ of work?
hasWork :: Int -> Event -> Bool
hasWork bits e = bits >= 0 && difficultyOfEvent e >= bits

-- | Does the event carry at least @bits@ of work /and/ commit to a target of at
-- least @bits@?
--
-- A note achieving 40 bits while committing to 30 must be rejected by a caller
-- that wants 40: without the commitment there is no way to tell cheap lucky
-- work from deliberate mining.
hasCommittedWork :: Int -> Event -> Bool
hasCommittedWork bits e =
  hasWork bits e && maybe False (>= bits) (targetDifficulty e)

-- | Search the nonce counter for a note with at least @target@ leading zero
-- bits, giving up after @maxNonce@ attempts.
--
-- Returns the note with one nonce tag and its id filled in. The caller still
-- has to sign it, because the id is only final once signing agrees with it.
-- The spec recommends also varying @created_at@ while mining; that is the
-- caller's choice, since it changes the work being done.
mine :: Int -> Event -> Word64 -> Maybe (Event, Word64)
mine target e maxNonce = go 0
  where
    go n
      | n > maxNonce = Nothing
      | otherwise =
          let candidate = e {evTags = replaceNonce (nonceTag n target)}
              scored = candidate {evId = computeEventId candidate}
          in if difficultyOfEvent scored >= target
               then Just (scored, n)
               else go (n + 1)

    -- Exactly one nonce tag per note. A second one would let the id commit to
    -- a counter that is not the one that did the work.
    replaceNonce new
      | any isNonce (evTags e) = map swapTag (evTags e)
      | otherwise = new : evTags e
      where
        isNonce ("nonce" : _) = True
        isNonce _             = False
        swapTag t = case t of
          ("nonce" : _) -> new
          _             -> t

-- | Strict decimal parse: rejects the empty string, a sign, and trailing junk.
-- 'read' alone accepts all three, and a nonce tag is attacker-controlled.
readDecimal :: Text -> Maybe Word64
readDecimal = decimal
  where
    decimal t
      | T.null t = Nothing
      | T.any (\c -> c < '0' || c > '9') t = Nothing
      | otherwise = case reads (T.unpack t) of
          [(n, "")] -> Just n
          _         -> Nothing

readInt :: Text -> Maybe Int
readInt t
  | T.null t = Nothing
  | T.any (\c -> c < '0' || c > '9') t = Nothing
  | otherwise = case reads (T.unpack t) of
      [(n, "")] -> Just n
      _         -> Nothing