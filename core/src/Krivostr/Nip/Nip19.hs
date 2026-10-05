{-# LANGUAGE OverloadedStrings #-}

-- | NIP-19 entities: @nevent@ and @naddr@ pointers.
--
-- @npub@/@nsec@/@note@ are bare 32-byte payloads owned by "Krivostr.Key";
-- the pointer entities are TLV streams instead:
--
-- * @nevent@: type 0 = event id (32 bytes), 1 = relay hints, 2 = author
--   (32 bytes), 3 = kind (4 bytes, big-endian uint32).
-- * @naddr@: type 0 = identifier (the @d@ tag, UTF-8), 1 = relay hints,
--   2 = author (32 bytes), 3 = kind (4 bytes, big-endian uint32).
--
-- Encoding is total but decoding is strict: a pointer without its mandatory
-- field (the id, the identifier) is not a pointer, and trailing garbage
-- after a well-formed prefix fails the whole decode rather than silently
-- truncating it -- a clipped pointer would resolve to the wrong event.
module Krivostr.Nip.Nip19
  ( EventPointer(..)
  , AddrPointer(..)
  , encodeNevent
  , decodeNevent
  , encodeNaddr
  , decodeNaddr
  , naddrAddress
  ) where

import Data.Bits (shiftL, shiftR, (.&.))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import Data.Word (Word8)
import Krivostr.Key (decodeNip19, encodeNip19)

-- | A pointer to one event.
data EventPointer = EventPointer
  { epId     :: !Text
  , epRelays :: ![Text]
  , epAuthor :: !(Maybe Text)
  , epKind   :: !(Maybe Int)
  } deriving (Show, Eq)

-- | A pointer to a parameterized address.
data AddrPointer = AddrPointer
  { apIdentifier :: !Text
  , apRelays     :: ![Text]
  , apAuthor     :: !Text
  , apKind       :: !Int
  } deriving (Show, Eq)

-- | One TLV entry: type, length, value. Lengths above 255 cannot be
-- expressed, so an oversized value is a caller error reported as 'Left'.
tlvEntry :: Word8 -> BS.ByteString -> Either String BS.ByteString
tlvEntry t v
  | BS.length v > 255 = Left "NIP-19 TLV value exceeds 255 bytes"
  | otherwise = Right (BS.pack [t, fromIntegral (BS.length v)] <> v)

-- | Split a TLV stream into entries. A truncated tail -- a type without its
-- length, or a length running past the end -- fails the decode: accepting
-- half an entry would silently drop the relay hint or author it carried.
tlvEntries :: BS.ByteString -> Either String [(Word8, BS.ByteString)]
tlvEntries bs
  | BS.null bs = Right []
  | BS.length bs < 2 = Left "truncated NIP-19 TLV entry"
  | otherwise =
      let t = BS.index bs 0
          l = fromIntegral (BS.index bs 1) :: Int
          rest = BS.drop 2 bs
      in if BS.length rest < l
           then Left "truncated NIP-19 TLV value"
           else ((t, BS.take l rest) :) <$> tlvEntries (BS.drop l rest)

-- | A 4-byte big-endian uint32.
word32BE :: Int -> Either String BS.ByteString
word32BE n
  | n < 0 || n > 4294967295 = Left "NIP-19 kind does not fit in a uint32"
  | otherwise = Right (BS.pack [byte 3, byte 2, byte 1, byte 0])
  where
    byte i = fromIntegral ((n `shiftR` (8 * i)) .&. 0xff)

word32BE' :: BS.ByteString -> Maybe Int
word32BE' bs
  | BS.length bs /= 4 = Nothing
  | otherwise = Just (foldl (\a b -> a `shiftL` 8 + fromIntegral b) 0 (BS.unpack bs))

hexBytes :: Text -> Either String BS.ByteString
hexBytes t
  | T.length t == 64 && T.all isHex t = case B16.decode (TE.encodeUtf8 t) of
      Right bs -> Right bs
      Left _   -> Left "bad hex"
  | otherwise = Left "expected 64 hex characters"
  where
    isHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

hexOf :: BS.ByteString -> Text
hexOf = TE.decodeUtf8 . B16.encode

-- | Encode an event pointer as @nevent@.
encodeNevent :: EventPointer -> Either String Text
encodeNevent p = do
  eid <- hexBytes (epId p)
  kind <- traverse word32BE (epKind p)
  author <- traverse hexBytes (epAuthor p)
  parts <- mapM (uncurry tlvEntry) (concat
    [ [(0, eid)]
    , [(1, TE.encodeUtf8 r) | r <- epRelays p]
    , [(2, a) | a <- maybeToList author]
    , [(3, k) | k <- maybeToList kind]
    ])
  pure (encodeNip19 "nevent" (BS.concat parts))
  where
    maybeToList = maybe [] (: [])

-- | Decode an @nevent@. Rejects the wrong hrp, a missing id, and trailing
-- garbage alike.
decodeNevent :: Text -> Either String EventPointer
decodeNevent t = case decodeNip19 t of
  Left e -> Left e
  Right (hrp, bs)
    | hrp /= "nevent" -> Left "wrong hrp"
    | otherwise -> do
        entries <- tlvEntries bs
        eid <- case [v | (0, v) <- entries, BS.length v == 32] of
          (v : _) -> Right (hexOf v)
          _       -> Left "nevent has no 32-byte id"
        pure EventPointer
          { epId = eid
          , epRelays = [TE.decodeUtf8 v | (1, v) <- entries]
          , epAuthor = case [v | (2, v) <- entries, BS.length v == 32] of
              (v : _) -> Just (hexOf v)
              _       -> Nothing
          , epKind = case [v | (3, v) <- entries] of
              (v : _) -> word32BE' v
              _       -> Nothing
          }

-- | Encode an address pointer as @naddr@. The identifier travels as UTF-8;
-- an empty identifier is not an address and is refused.
encodeNaddr :: AddrPointer -> Either String Text
encodeNaddr p
  | T.null (apIdentifier p) = Left "naddr identifier must not be empty"
  | otherwise = do
      author <- hexBytes (apAuthor p)
      kind <- word32BE (apKind p)
      parts <- mapM (uncurry tlvEntry) (concat
        [ [(0, TE.encodeUtf8 (apIdentifier p))]
        , [(1, TE.encodeUtf8 r) | r <- apRelays p]
        , [(2, author), (3, kind)]
        ])
      pure (encodeNip19 "naddr" (BS.concat parts))

-- | Decode an @naddr@. The identifier, author, and kind are all mandatory:
-- an address without an author names nobody, and one without a kind names
-- no event collection.
decodeNaddr :: Text -> Either String AddrPointer
decodeNaddr t = case decodeNip19 t of
  Left e -> Left e
  Right (hrp, bs)
    | hrp /= "naddr" -> Left "wrong hrp"
    | otherwise -> do
        entries <- tlvEntries bs
        ident <- case [v | (0, v) <- entries, not (BS.null v)] of
          (v : _) -> Right (TE.decodeUtf8 v)
          _       -> Left "naddr has no identifier"
        author <- case [v | (2, v) <- entries, BS.length v == 32] of
          (v : _) -> Right (hexOf v)
          _       -> Left "naddr has no 32-byte author"
        kind <- case [v | (3, v) <- entries] of
          (v : _) -> case word32BE' v of
            Just n  -> Right n
            Nothing -> Left "naddr kind is not a uint32"
          _ -> Left "naddr has no kind"
        pure AddrPointer
          { apIdentifier = ident
          , apRelays = [TE.decodeUtf8 v | (1, v) <- entries]
          , apAuthor = author
          , apKind = kind
          }

-- | The @kind:pubkey:d@ coordinate an address pointer names.
naddrAddress :: AddrPointer -> Text
naddrAddress p = T.intercalate ":" [T.pack (show (apKind p)), apAuthor p, apIdentifier p]
