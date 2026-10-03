{-# LANGUAGE OverloadedStrings #-}
module Krivostr.Nip.Nip01
  ( canonicalBytes
  , computeEventId
  , signEvent
  , verifyEvent
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Aeson (encode)
import Crypto.Hash.SHA256 (hash)
import qualified Data.ByteString.Base16 as B16
import Data.Text (Text)
import Krivostr.Event
import Krivostr.Key

-- | Canonical NIP-01 serialization for the event id:
-- [0, <pubkey-hex>, <created_at>, <kind>, <tags>, <content>]
canonicalBytes :: Event -> BS.ByteString
canonicalBytes e = BS.concat
  [ "[0,\""
  , TE.encodeUtf8 (evPubkey e)
  , "\","
  , BC.pack (show (floor (evCreatedAt e) :: Integer))
  , ","
  , BC.pack (show (evKind e))
  , ","
  , TE.encodeUtf8 (tagsJson (evTags e))
  , ",\""
  , TE.encodeUtf8 (escapeJson (evContent e))
  , "\"]"
  ]
  where
    tagsJson :: [[Text]] -> Text
    tagsJson = TE.decodeUtf8 . BL.toStrict . encode

    -- | NIP-01 requires the standard JSON escapes for @"@, \\ and every
    -- control character in U+0000-U+001F. The previous version only handled
    -- \\n, \\r and \\t, so any content containing e.g. NUL or a form feed
    -- produced a different serialization -- and therefore a different event id
    -- and an unverifiable signature -- from every other Nostr implementation.
    escapeJson :: Text -> Text
    escapeJson = T.concatMap escape
      where
        escape c = case c of
          '"' -> "\\\""
          '\\' -> "\\\\"
          '\b' -> "\\b"
          '\f' -> "\\f"
          '\n' -> "\\n"
          '\r' -> "\\r"
          '\t' -> "\\t"
          _
            | c < ' ' ->
                let n = fromEnum c
                    hex = T.pack [("0123456789abcdef" !! (n `div` 16)), ("0123456789abcdef" !! (n `mod` 16))]
                in T.pack ['\\', 'u', '0', '0', T.index hex 0, T.index hex 1]
            | otherwise -> T.singleton c

computeEventId :: Event -> Text
computeEventId = TE.decodeUtf8 . B16.encode . hash . canonicalBytes

-- | Sign with a private key: (a) fill pubkey from the key, (b) compute id,
-- (c) Schnorr-sign the 32-byte sha256 of the canonical bytes.
signEvent :: PrivateKey -> Event -> Event
signEvent sk e =
  let pub     = pubKeyHex (derivePublicKey sk)
      e1      = e { evPubkey = pub }
      e2      = e1 { evId = computeEventId e1 }
      canonical = canonicalBytes e2
      msgHash   = hash canonical
      sig       = signSchnorr sk msgHash
  in e2 { evSig = TE.decodeUtf8 (B16.encode sig) }

-- | Verify id and signature. Invalid inputs return False.
verifyEvent :: Event -> Bool
verifyEvent e =
  computeEventId e == evId e && sigOk
  where
    sigOk =
      case ( B16.decode (TE.encodeUtf8 (evSig e))
           , B16.decode (TE.encodeUtf8 (evPubkey e)) ) of
        (Right sig, Right pkBytes) ->
          maybe
            False
            (\pk -> verifySchnorr pk (hash (canonicalBytes e)) sig)
            (publicKeyFromBytes pkBytes)
        _ -> False
