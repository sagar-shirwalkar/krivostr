{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The bits of Nostr that need an effect system: NIP-04 encryption, signing,
-- and waiting for a relay to acknowledge a publish.
module Krivostr.Cli.Nostr
  ( encryptNip04
  , decryptNip04
  , signUnsigned
  , publishTo
  , publishAll
  , defaultRelays
  ) where

import Control.Concurrent.STM
import Control.Exception (SomeException, try)
import Crypto.Cipher.AES (AES256)
-- crypton's API: a cipher is keyed on its own, then used with an explicit IV
-- per operation. There is no `createCipherInit`, and padding lives under
-- Crypto.Data.Padding.
import Crypto.Cipher.Types (BlockCipher (blockSize), cbcDecrypt, cbcEncrypt, cipherInit, makeIV)
import Crypto.Data.Padding (Format (PKCS7), pad, unpad)
import Crypto.Error (CryptoFailable (..))
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text (Text)
import Krivostr.Event
import Krivostr.Key
import Krivostr.Logging
import Krivostr.Nip.Nip01 (signEvent)
import Krivostr.Relay
import Krivostr.Wire
import System.Timeout (timeout)

-- | Relays used when nothing better is known. Same set the bridge defaults to.
defaultRelays :: [Text]
defaultRelays =
  [ "wss://relay.damus.io"
  , "wss://nos.lol"
  , "wss://relay.primal.net"
  ]

-- | NIP-04: AES-256-CBC under the ECDH shared secret, @base64(ct)?iv=base64(iv)@.
--
-- NIP-04 is deprecated in favour of NIP-44, but it is what kind 4 DMs are
-- actually read as by clients in the wild, so it is what we can send.
encryptNip04 :: PrivateKey -> PublicKey -> Text -> IO (Either String Text)
encryptNip04 sk pk plain =
  case sharedSecret sk pk of
    Nothing -> pure (Left "not a valid x-only public key")
    Just ss -> do
      ivBytes <- getRandomBytes 16
      case (cipherInit ss :: CryptoFailable AES256, makeIV ivBytes) of
        (CryptoFailed err, _) ->
          pure (Left ("cipher init failed: " <> show err))
        (CryptoPassed _, Nothing) ->
          pure (Left "generated a 16-byte IV that AES would not accept")
        (CryptoPassed c, Just iv) ->
          let bs  = blockSize c :: Int
              padded = pad (PKCS7 bs) (TE.encodeUtf8 plain) :: BS.ByteString
              ct = cbcEncrypt c iv padded :: BS.ByteString
          in pure $ Right $
               TE.decodeUtf8 (B64.encode ct) <> "?iv=" <> TE.decodeUtf8 (B64.encode ivBytes)

-- | The inverse of 'encryptNip04'.
decryptNip04 :: PrivateKey -> PublicKey -> Text -> IO (Either String Text)
decryptNip04 sk pk payload =
  case sharedSecret sk pk of
    Nothing -> pure (Left "not a valid x-only public key")
    Just ss ->
      case T.breakOn "?iv=" payload of
        (_, "") -> pure (Left "payload has no ?iv= component")
        (ctPart, ivPart) ->
          let ivText = T.drop 4 ivPart
          in case (decodeB64 (T.strip ctPart), decodeB64 ivText) of
               (Right ct, Right ivBytes) ->
                 case (cipherInit ss :: CryptoFailable AES256, makeIV ivBytes) of
                   (CryptoFailed err, _) ->
                     pure (Left ("cipher init failed: " <> show err))
                   (CryptoPassed _, Nothing) ->
                     pure (Left "payload carries an IV of the wrong length")
                   (CryptoPassed c, Just iv) ->
                     case unpad (PKCS7 (blockSize c))
                                (cbcDecrypt c iv ct :: BS.ByteString) :: Maybe BS.ByteString of
                       Nothing ->
                         pure (Left "padding is wrong: not a message encrypted to this key")
                       Just m  ->
                         pure $ case TE.decodeUtf8' m of
                           Left e   -> Left ("plaintext is not utf-8: " ++ show e)
                           Right txt -> Right txt
               (Left e, _) -> pure (Left ("bad base64 ciphertext: " <> e))
               (_, Left e) -> pure (Left ("bad base64 iv: " <> e))

decodeB64 :: Text -> Either String BC.ByteString
decodeB64 t =
  case B64.decode (TE.encodeUtf8 t) of
    Left err -> Left (show err)
    Right bs -> Right bs

-- | Fill in the id and signature of an unsigned event.
signUnsigned :: PrivateKey -> UnsignedEvent -> Event
signUnsigned sk = signEvent sk . mkEvent

-- | Publish to one relay and wait for its @OK@.
--
-- Reports the relay's own rejection message rather than a bare failure: a relay
-- answering @{"OK":false,"message":"blocked: not authenticated"}@ is the single
-- most useful thing this command can tell you.
publishTo :: Logger -> Int -> Event -> Text -> IO (Either String Text)
publishTo lg waitMicros ev url = do
  attempt <- try (connect lg url)
  case attempt of
    Left (e :: SomeException) ->
      pure (Left ("connect failed: " ++ takeWhile (/= '\n') (show e)))
    Right rh -> do
      sendClient rh (CEvent ev)
      res <- timeout waitMicros (awaitOk rh (evId ev))
      close rh
      pure $ case res of
        Nothing    -> Left "timed out waiting for OK"
        Just (Left e)  -> Left (T.unpack e)
        Just (Right ok) -> Right ok

-- | Read the inbox until the relay accepts or rejects this event id.
--
-- Every message here is relay-supplied text, so the failure side is Text;
-- 'publishTo' narrows it to String for its caller.
awaitOk :: RelayHandle -> Text -> IO (Either Text Text)
awaitOk rh wantId = do
  msg <- atomically $ readTQueue (rhInbox rh)
  case msg of
    ROk _ ok m
      | m == wantId || T.null m ->
          pure $ if ok then Right ("accepted: " <> m) else Left ("rejected: " <> m)
    ROk{}       -> awaitOk rh wantId
    RClosed s m -> pure (Left ("relay closed " <> s <> ": " <> m))
    RNotice m   -> pure (Left ("notice: " <> m))
    _           -> awaitOk rh wantId

-- | Publish to several relays, keeping the first success.
--
-- One accepting relay is enough for the event to be live, so the remaining
-- attempts are only for the error message. Results are in relay order.
publishAll :: Logger -> Int -> Event -> [Text] -> IO [(Text, Either String Text)]
publishAll lg waitMicros ev =
  mapM (\url -> do
      r <- publishTo lg waitMicros ev url
      pure (url, r))
