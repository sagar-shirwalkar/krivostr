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
  , isHex64
  , envText
  , loadKey
  , withStore
  , requireEvent
  , relayHints
  , publishNoteResults
  ) where

import Control.Concurrent.STM
import Control.Exception (SomeException, finally, try)
import Control.Monad (unless, when)
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
import Krivostr.Filter (Filter (..))
import Krivostr.Key
import Krivostr.Logging
import Krivostr.Nip.Nip01 (signEvent)
import Krivostr.Nip.Nip05 (Nip05Doc, wellKnownUrl)
import Krivostr.Nip.Nip65 (RelayHint (rhMode, rhUrl), RelayMode (Both, Read, Write), parseRelayList)
-- Hiding Relay.rhUrl: the RelayHandle accessor shares the name with the
-- NIP-65 hint accessor and nothing here uses the former.
import Krivostr.Relay hiding (rhUrl)
import Krivostr.Store (Store, closeStore, getEventById, insertEvent, openStore, queryEvents)
import Krivostr.Wire
import qualified Data.Aeson as Aeson
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Client.TLS as TLS
import qualified Network.HTTP.Types as HTTPT
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Exit (die)
import System.FilePath (takeDirectory)
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

-- ═══════════════════════════════════════════════════ shared send helpers
-- Moved here from Krivostr.Cli so both shells use them: the one-shot CLI
-- prints the verdicts and exits, the TUI maps them onto status and log.
-- Nothing below prints or exits except requireEvent's usage errors, which
-- stay CLI-shaped on purpose (the TUI looks events up through its backend
-- seam instead and never calls it).

-- | 64 lowercase hex characters. Event ids and x-only pubkeys, nothing else.
isHex64 :: Text -> Bool
isHex64 t = T.length t == 64 && T.all isHexDigit t
  where
    isHexDigit c = (c >= '0' && c <= '9')
                || (c >= 'a' && c <= 'f')
                || (c >= 'A' && c <= 'F')

-- | Read an env var, treating missing and blank alike as absent. Callers
-- must not distinguish "unset" from "whitespace": both mean "not given".
envText :: String -> IO (Maybe Text)
envText k = do
  v <- lookupEnv k
  pure $ case v of
    Nothing -> Nothing
    Just s  -> let t = T.strip (T.pack s) in if T.null t then Nothing else Just t

-- | Load the secret key without dying: absent reads as Nothing (read-only
-- mode), malformed reads as Left. `requireKey` in Krivostr.Cli keeps the
-- dying behavior for the one-shot commands.
loadKey :: IO (Either String (Maybe PrivateKey))
loadKey = do
  env <- envText "KRIVOSTR_NSEC"
  case env of
    Nothing -> pure (Right Nothing)
    Just t  -> case importNsec t of
      Right sk -> pure (Right (Just sk))
      Left e   -> pure (Left ("KRIVOSTR_NSEC is not an nsec: " ++ e))

-- | Open the store, creating its directory, and always close it again.
-- Both shells bracket every store access with this; nothing holds a Store
-- across commands.
withStore :: Logger -> FilePath -> (Store -> IO a) -> IO a
withStore lg db act = do
  createDirectoryIfMissing True (takeDirectory db)
  st <- openStore lg db
  act st `finally` closeStore st

-- | Fetch an event from the store by hex id. Bech32 note ids arrive with
-- NIP-27; until then hex is the input and anything else is a usage error,
-- not a lookup miss.
requireEvent :: Logger -> FilePath -> String -> IO Event
requireEvent lg db raw = do
  let eid = T.pack raw
  unless (isHex64 eid) (die "event id must be 64 hex characters")
  withStore lg db $ \st -> do
    found <- getEventById st eid
    case found of
      Just e  -> pure e
      Nothing -> die ("no event " ++ raw ++ " in the local store (try: krivostr feed first)")

-- | Relays named for reading by the newest kind 10002 in the store.
--
-- This is the CLI half of the NIP-65 story: the store already holds the relay
-- list metadata, so the tool follows it instead of carrying its own defaults.
relayHints :: Store -> IO [Text]
relayHints st = do
  evs <- queryEvents st Filter
    { fIds = Nothing, fAuthors = Nothing, fKinds = Just [10002]
    , fSince = Nothing, fUntil = Nothing, fLimit = Just 20, fTags = [], fSearch = Nothing }
  pure $ case evs of
    []   -> []
    list -> [ rhUrl h | ev <- list, h <- parseRelayList ev, readable (rhMode h) ]
  where
    readable Read  = True
    readable Write = False
    readable Both  = True

-- | Publish a signed event and report each relay's answer as data. Resolves
-- targets the same way everywhere (explicit relays, else stored kind-10002
-- read hints, else the compiled-in defaults) and stores the event locally on
-- at least one acceptance. Returns the per-relay verdicts and never prints
-- or exits: the CLI edge reports and exits, the TUI edge posts status and log.
publishNoteResults :: Logger -> FilePath -> Int -> Event -> [Text] -> Text -> IO [(Text, Either String Text)]
publishNoteResults lg db timeoutSecs ev relays what = do
  targets <- case relays of
    [] -> withStore lg db $ \st -> do
      hinted <- relayHints st
      pure (if null hinted then defaultRelays else hinted)
    xs -> pure xs
  emit lg Info (what <> " via " <> T.intercalate ", " targets)
  results <- publishAll lg (timeoutSecs * 1000000) ev targets
  let accepted = any (either (const False) (const True) . snd) results
  when accepted $ withStore lg db $ \st -> insertEvent st ev >> pure ()
  pure results
