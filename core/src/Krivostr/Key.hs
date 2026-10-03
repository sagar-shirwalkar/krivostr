{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
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
  , exportNsec
  , exportNpub
  , importNsec
  , importNpub
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Crypto.Secp256k1
import System.IO.Unsafe (unsafePerformIO)
import Codec.Binary.Bech32
import Codec.Binary.Bech32.TH
import Data.Maybe (fromMaybe)

newtype PrivateKey = PrivateKey SecKey
  deriving (Show, Eq)

newtype PublicKey = PublicKey PubKey
  deriving (Show, Eq)

generatePrivateKey :: IO PrivateKey
generatePrivateKey = PrivateKey <$> secKeyGen

derivePublicKey :: PrivateKey -> PublicKey
derivePublicKey (PrivateKey sk) =
  let PubKey bytes = derivePubKey sk
  in PublicKey (PubKey (BS.drop 1 bytes))

pubKeyBytes :: PublicKey -> BS.ByteString
pubKeyBytes (PublicKey (PubKey bs)) = bs

pubKeyHex :: PublicKey -> Text
pubKeyHex = TE.decodeUtf8 . B16.encode . pubKeyBytes

signSchnorr :: PrivateKey -> BS.ByteString -> BS.ByteString
signSchnorr (PrivateKey sk) msg = unsafePerformIO $ do
  sig <- schnorrSignMsg sk msg
  pure (exportSig sig)
{-# NOINLINE signSchnorr #-}

verifySchnorr :: PublicKey -> BS.ByteString -> BS.ByteString -> Bool
verifySchnorr pk msg sigBytes =
  case importSig sigBytes of
    Nothing -> False
    Just sig ->
      let xonly = pubKeyBytes pk
          pkFull = fromMaybe (PubKey BS.empty) (importPubKey (BS.cons 0x02 xonly))
      in schnorrVerify sig pkFull msg

importHex :: Text -> Either String PrivateKey
importHex t =
  case B16.decode (TE.encodeUtf8 t) of
    Left e   -> Left e
    Right bs -> case secKeyImport bs of
      Nothing -> Left "invalid secp256k1 secret key"
      Just sk -> Right (PrivateKey sk)

exportHex :: PrivateKey -> Text
exportHex (PrivateKey sk) = TE.decodeUtf8 (B16.encode (exportSecKey sk))

-- | nsec bech32 (BIP-173).
exportNsec :: PrivateKey -> Text
exportNsec (PrivateKey sk) =
  let bytes = exportSecKey sk
      dp    = dataPartFromBytes bytes
  in case encode (humanReadablePartToText [nsecHrp|nsec|]) dp of
       Left _  -> ""
       Right t -> t

-- | npub bech32.
exportNpub :: PublicKey -> Text
exportNpub pk =
  let bytes = pubKeyBytes pk
      dp    = dataPartFromBytes bytes
  in case encode (humanReadablePartToText [npubHrp|npub|]) dp of
       Left _  -> ""
       Right t -> t

importNsec :: Text -> Either String PrivateKey
importNsec t = case decode t of
  Left e -> Left (show e)
  Right (hrp, dp) | humanReadablePartToText hrp == "nsec" ->
    let bs = dataPartToBytes dp
    in case secKeyImport bs of
         Nothing -> Left "bad nsec"
         Just sk -> Right (PrivateKey sk)
  _ -> Left "wrong hrp"

importNpub :: Text -> Either String PublicKey
importNpub t = case decode t of
  Left e -> Left (show e)
  Right (hrp, dp) | humanReadablePartToText hrp == "npub" ->
    let bs = dataPartToBytes dp
        pk = PubKey (BS.cons 0x02 bs)
    in Right (PublicKey pk)
  _ -> Left "wrong hrp"

  publicKeyFromBytes :: BS.ByteString -> Maybe PublicKey
  publicKeyFromBytes bs = do
    full <- importPubKey (BS.cons 0x02 bs)
    let PubKey raw = full
    pure (PublicKey (PubKey (BS.drop 1 raw)))
