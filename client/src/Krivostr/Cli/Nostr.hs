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
  , awaitOk
  , defaultRelays
  , fetchNip05Doc
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
import Krivostr.Nip.Nip05 (Nip05Doc, wellKnownUrl)
import Krivostr.Relay
import Krivostr.Wire
import qualified Data.Aeson as Aeson
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Client.TLS as TLS
import qualified Network.HTTP.Types as HTTPT
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
--
-- Floors @created_at@ to whole seconds first: callers hand over 'getPOSIXTime'
-- with its fractional part intact, and strict relays reject non-integer
-- timestamps ("event created_at field was not an integer"). Flooring here,
-- once, keeps every send command honest instead of trusting each call site.
signUnsigned :: PrivateKey -> UnsignedEvent -> Event
signUnsigned sk u = signEvent sk (mkEvent u { ueCreatedAt = fromInteger (floor (ueCreatedAt u)) })

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
      res <- timeout waitMicros (awaitOk (rhInbox rh) (evId ev))
      close rh
      pure $ case res of
        Nothing    -> Left "timed out waiting for OK"
        Just (Left e)  -> Left (T.unpack e)
        Just (Right ok) -> Right ok

-- | Read the inbox until the relay accepts or rejects this event id.
--
-- Takes the inbox queue rather than the handle: the logic is pure
-- queue-draining, and a 'TQueue' is constructible in tests while a live
-- 'RelayHandle' is not.
--
-- Every message here is relay-supplied text, so the failure side is Text;
-- 'publishTo' narrows it to String for its caller.
awaitOk :: TQueue RelayMessage -> Text -> IO (Either Text Text)
awaitOk inbox wantId = do
  msg <- atomically $ readTQueue inbox
  case msg of
    -- Match on the event id, not the message: relays routinely answer with
    -- a non-empty message ("duplicate: …", rate-limit notes), and comparing
    -- the message to the wanted id hangs until timeout on every such OK.
    ROk sid ok m
      | sid == wantId ->
          pure $ if ok then Right ("accepted: " <> m) else Left ("rejected: " <> m)
      | otherwise -> awaitOk inbox wantId
    RClosed s m -> pure (Left ("relay closed " <> s <> ": " <> m))
    RNotice m   -> pure (Left ("notice: " <> m))
    _           -> awaitOk inbox wantId

-- | Publish to several relays, keeping the first success.
--
-- One accepting relay is enough for the event to be live, so the remaining
-- attempts are only for the error message. Results are in relay order.
publishAll :: Logger -> Int -> Event -> [Text] -> IO [(Text, Either String Text)]
publishAll lg waitMicros ev =
  mapM (\url -> do
      r <- publishTo lg waitMicros ev url
      pure (url, r))

-- | Fetch a domain's @nostr.json@ over HTTPS. TLS is non-negotiable: the
-- document is a trust decision, and plain HTTP would let anyone on the path
-- hand out any pubkey for any name.
--
-- A non-200 status is a failure, not a document. Some hosts serve a login
-- page with 200 on unknown paths; that fails later at the JSON parse, which
-- is the honest place -- the bytes are not what NIP-05 asks for.
fetchNip05Doc :: Text -> Text -> IO (Either String Nip05Doc)
fetchNip05Doc name domain = do
  manager <- TLS.newTlsManager
  reqE <- try (HTTP.parseRequest (T.unpack (wellKnownUrl name domain)))
  case reqE of
    Left err -> pure (Left ("bad identifier domain: " ++ show (err :: SomeException)))
    Right req0 -> do
      let req = req0 { HTTP.requestHeaders = ("Accept", "application/json") : HTTP.requestHeaders req0
                     , HTTP.responseTimeout = HTTP.responseTimeoutMicro (15 * 1000000)
                     }
      resE <- try (HTTP.httpLbs req manager)
      case resE of
        Left err -> pure (Left ("fetch failed: " ++ show (err :: SomeException)))
        Right res
          | HTTPT.statusCode (HTTP.responseStatus res) /= 200 ->
              pure (Left ("server answered " ++ show (HTTPT.statusCode (HTTP.responseStatus res))))
          | otherwise -> case Aeson.eitherDecode (HTTP.responseBody res) of
              Right doc -> pure (Right doc)
              Left err  -> pure (Left ("not a NIP-05 document: " ++ err))
