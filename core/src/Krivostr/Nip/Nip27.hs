{-# LANGUAGE OverloadedStrings #-}

-- | NIP-27 text note references: @nostr:@ URIs inside event text.
--
-- A mention is @nostr:@ followed by a NIP-19 bech32 string: @npub@ names an
-- author, @note@ names an event, @nprofile@ names an author plus relay
-- hints. Scanning is deliberately dumb -- find @nostr:@, take the bech32
-- run, decode it -- because mentions live inside free text and any grammar
-- stricter than that would miss the ones clients actually write.
--
-- An @nsec@ in text is never a usable mention: decoding it would put a
-- secret key one copy-paste away from publication, so it parses as opaque
-- and no caller should do more with it. @nevent@ and @naddr@ are likewise
-- opaque here; their TLV belongs to the NIP-19 entity work, not to mention
-- scanning.
module Krivostr.Nip.Nip27
  ( Mention(..)
  , MentionKind(..)
  , findMentions
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString as BS
import Data.Word (Word8)
import Krivostr.Key (decodeNip19, importNpub, pubKeyHex)

-- | One @nostr:@ reference found in text: what it means plus the exact
-- source span, so a renderer can highlight the original characters rather
-- than a reconstruction that would differ from what the author wrote.
data Mention = Mention
  { meKind :: !MentionKind
  , meRaw  :: !Text
  } deriving (Show, Eq)

data MentionKind
  = -- | @nostr:npub…@: an author, as hex.
    MentionPubkey !Text
  | -- | @nostr:note…@: an event id, as hex.
    MentionEvent !Text
  | -- | @nostr:nprofile…@: an author plus relay hints.
    MentionProfile !Text ![Text]
  | -- | Anything else bech32 (@nevent@, @naddr@, @nsec@, unknown): named by
    -- hrp so renderers can show it without understanding it.
    MentionOpaque !Text
  deriving (Show, Eq)

-- | Find every @nostr:@ reference in free text, in order. Runs that are not
-- valid bech32 are skipped, not errors: surrounding prose is not our input
-- to validate.
findMentions :: Text -> [Mention]
findMentions t = case T.breakOn "nostr:" t of
  (_, after)
    | T.null after -> []
    | otherwise ->
        let rest = T.drop (T.length "nostr:") after
            (run, tail_) = T.span isBech32Char rest
        in case decodeMention run of
             Just m  -> m : findMentions tail_
             Nothing -> findMentions tail_
  where
    isBech32Char c =
      (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')

-- | Decode one bech32 run into a mention. Bech32 is lowercase by construction
-- (uppercase would be a different checksum), so no folding is needed.
decodeMention :: Text -> Maybe Mention
decodeMention raw = case decodeNip19 raw of
  Left _ -> Nothing
  Right (hrp, bs)
    | hrp == "npub" -> case importNpub raw of
        Right pk -> Just (Mention (MentionPubkey (pubKeyHex pk)) ("nostr:" <> raw))
        Left _   -> Nothing
    | hrp == "note"
    , BS.length bs == 32 ->
        Just (Mention (MentionEvent (hex bs)) ("nostr:" <> raw))
    | hrp == "nprofile" -> case profilePubkey bs of
        Just (pk, relays) ->
          Just (Mention (MentionProfile pk relays) ("nostr:" <> raw))
        Nothing ->
          Just (Mention (MentionOpaque hrp) ("nostr:" <> raw))
    | otherwise ->
        Just (Mention (MentionOpaque hrp) ("nostr:" <> raw))
  where
    hex = TE.decodeUtf8 . B16.encode

-- | The type-0 entry of an @nprofile@ TLV plus every type-1 relay hint.
-- (Relay hints are type 1 in profiles; type 2 belongs to @nevent@ authors.)
-- Anything without a 32-byte type-0 entry is not a profile.
profilePubkey :: BS.ByteString -> Maybe (Text, [Text])
profilePubkey bs = case scanEntries (BS.unpack bs) of
  entries -> case [v | (0, v) <- entries, BS.length v == 32] of
    (pk : _) -> Just (TE.decodeUtf8 (B16.encode pk), [TE.decodeUtf8 v | (1, v) <- entries])
    _        -> Nothing
  where
    scanEntries :: [Word8] -> [(Word8, BS.ByteString)]
    scanEntries (t : l : rest)
      | length rest >= fromIntegral l =
          let (v, remaining) = splitAt (fromIntegral l) rest
          in (t, BS.pack v) : scanEntries remaining
      | otherwise = []
    scanEntries _ = []
