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
  , escapeJson (evContent e)
  , "\"]"
  ]
  where
    tagsJson :: [[Text]] -> Text
    tagsJson = TE.decodeUtf8 . BL.toStrict . encode
    escapeJson :: Text -> Text
    escapeJson =
        T.replace "\n" "\\n"
      . T.replace "\r" "\\r"
      . T.replace "\t" "\\t"
      . T.replace "\"" "\\\""
      . T.replace "\\" "\\\\"

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
    sigOk = case (B16.decode (TE.encodeUtf8 (evSig e)),
                    B16.decode (TE.encodeUtf8 (evPubkey e))) of
        (Right sig, Right pkBytes) ->
        maybe False (\pk -> verifySchnorr pk (hash (canonicalBytes e)) sig)
                    (publicKeyFromBytes pkBytes)
        _ -> False
