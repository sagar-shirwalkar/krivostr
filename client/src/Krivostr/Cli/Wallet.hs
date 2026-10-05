{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The wallet-client half of NIP-47: one request, one response, then hang up.
--
-- The connection URI carries everything: the service's pubkey, its relays,
-- and our per-connection secret, which is both the signing key and half of
-- the NIP-44 conversation. Each call opens the first listed relay,
-- subscribes to the service's kind-23195 responses, publishes the encrypted
-- kind-23194 request, and waits for the first answer from the service. Calls
-- are single-flight by construction -- one connection per call -- so no
-- request/response correlation beyond "the service answered" is needed.
module Krivostr.Cli.Wallet
  ( walletRequest
  ) where

import Control.Concurrent.STM (atomically, readTQueue)
import Control.Exception (SomeException, try)
import qualified Crypto.Random as RND
import Data.Aeson (Value)
import qualified Data.Text as T
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Krivostr.Cli.Nostr (defaultRelays)
import Krivostr.Event
import Krivostr.Filter
import Krivostr.Key
import Krivostr.Logging
import Krivostr.Nip.Nip01 (signEvent)
import Krivostr.Nip.Nip44 (decrypt, encryptWithNonce)
import Krivostr.Nip.Nip47
import qualified Krivostr.Relay as Relay
import Krivostr.Wire
import System.Timeout (timeout)

-- | Run one wallet method against the service and return its response.
-- Fails on connect, on timeout (30s -- Lightning is not instant), on undecryptable
-- answers, and on wallet-side errors, each with the layer that failed named.
walletRequest :: Logger -> WalletConn -> Method -> Value -> IO (Either String Response)
walletRequest lg conn method params =
  case importHex (wcSecret conn) of
    Left e -> pure (Left ("bad wallet secret: " ++ e))
    Right secret -> do
      let walletHex = wcWalletPubkey conn
      now <- getPOSIXTime
      nonce <- RND.getRandomBytes 32
      case encryptWithNonce secret walletHex nonce (encodeRequest (Request method params)) of
        Left e -> pure (Left ("cannot encrypt request: " ++ e))
        Right content -> do
          let unsigned = UnsignedEvent
                { uePubkey    = pubKeyHex (derivePublicKey secret)
                , ueCreatedAt = now
                , ueKind      = requestEventKind
                , ueTags      = buildRequestTags walletHex
                , ueContent   = content
                }
              req = signEvent secret (mkEvent unsigned)
          attempt (relays conn) secret walletHex req
  where
    relays c
      | null (wcRelays c) = defaultRelays
      | otherwise = wcRelays c

    attempt [] _ _ _ = pure (Left "no wallet relay reachable")
    attempt (url : rest) secret walletHex req = do
      connE <- try (Relay.connect lg url) :: IO (Either SomeException Relay.RelayHandle)
      case connE of
        Left _ -> attempt rest secret walletHex req
        Right rh -> do
          out <- try (runCall rh secret walletHex req) :: IO (Either SomeException (Either String Response))
          Relay.close rh
          case out of
            Left err -> pure (Left ("wallet call failed: " ++ show err))
            Right r  -> pure r

    runCall rh secret walletHex req = do
      -- Subscribe before publishing: the service can answer faster than a
      -- slow reader loops, and a missed answer is a timeout, not a retry.
      Relay.sendClient rh (CReq "nwc" [onlyKinds [responseEventKind]])
      Relay.sendClient rh (CEvent req)
      answered <- timeout (30 * 1000000) (awaitResponse rh secret walletHex)
      pure (maybe (Left "wallet did not answer in 30s") id answered)

    awaitResponse rh secret walletHex = do
      msg <- atomically (readTQueue (Relay.rhInbox rh))
      case msg of
        REvent _ e
          | evKind e == responseEventKind && evPubkey e == walletHex ->
              case decrypt secret walletHex (evContent e) of
                Left err -> pure (Left ("cannot decrypt wallet response: " ++ err))
                Right plain -> case parseResponse plain of
                  Left err -> pure (Left ("bad wallet response: " ++ err))
                  Right res -> pure (checkError res)
        _ -> awaitResponse rh secret walletHex

    checkError res = case resError res of
      Just err -> Left ("wallet refused: " ++ T.unpack (weCode err) ++ ": " ++ T.unpack (weMessage err))
      Nothing  -> Right res
