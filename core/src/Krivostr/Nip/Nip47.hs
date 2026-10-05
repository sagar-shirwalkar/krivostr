{-# LANGUAGE OverloadedStrings #-}

-- | NIP-47 Nostr Wallet Connect: the client side of remote lightning.
--
-- A wallet service publishes a kind 13194 info event naming its methods; a
-- client holding a @nostr+walletconnect://@ URI -- the service's pubkey, the
-- relays it listens on, and a per-connection client secret -- sends kind
-- 23194 requests and reads kind 23195 responses. Both directions encrypt
-- with NIP-44 v2; the legacy NIP-04 mode is not implemented, and a service
-- speaking only NIP-04 will produce payloads this module cannot open rather
-- than a downgraded session negotiated silently.
--
-- This module is the protocol layer and nothing else: URIs, the method
-- table, and the JSON codecs. Sockets, timeouts, and invoice-paying live
-- below the line. The conversation itself reuses 'Krivostr.Nip.Nip44'
-- directly, so there is exactly one NIP-44 implementation to audit.
module Krivostr.Nip.Nip47
  ( -- * Protocol constants
    requestEventKind
  , responseEventKind
  , infoEventKind
    -- * Connection URIs
  , WalletConn(..)
  , parseWalletUri
  , renderWalletUri
    -- * Methods
  , Method(..)
  , allMethods
  , methodFromText
  , methodToText
    -- * Requests
  , Request(..)
  , parseRequest
  , encodeRequest
  , buildRequestTags
    -- * Responses
  , WalletError(..)
  , Response(..)
  , parseResponse
  , encodeResponse
    -- * Info events
  , parseInfoMethods
  ) where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL

-- | Kind 23194: client to wallet service.
requestEventKind :: Int
requestEventKind = 23194

-- | Kind 23195: wallet service to client.
responseEventKind :: Int
responseEventKind = 23195

-- | Kind 13194: the service's replaceable capability advertisement.
infoEventKind :: Int
infoEventKind = 13194

-- | A wallet connection: the service's pubkey, its relays, our
-- per-connection secret, and the optional lud16 the URI carried.
data WalletConn = WalletConn
  { wcWalletPubkey :: !Text
  , wcRelays       :: ![Text]
  , wcSecret       :: !Text
  , wcLud16        :: !(Maybe Text)
  } deriving (Show, Eq)

-- | Parse a @nostr+walletconnect://@ URI. The relay may repeat; @secret@
-- is mandatory. Percent-encoding is decoded, because relay URLs arrive
-- encoded (@wss%3A%2F%2F…@) and matching them literally would connect
-- nowhere. Parsed by hand rather than with a URI library: the shape is
-- fixed (scheme, one path segment, query pairs) and the dependency would
-- outlive its use.
parseWalletUri :: Text -> Either String WalletConn
parseWalletUri raw = do
  rest <- maybe (Left "not a nostr+walletconnect URI") Right
    (T.stripPrefix "nostr+walletconnect://" raw)
  let (hostPart, queryPart) = T.breakOn "?" rest
  check (not (T.null hostPart) && "/" `T.isInfixOf` hostPart == False) "wallet pubkey must be 64 hex characters"
  let pubkey = hostPart
  check (T.length pubkey == 64 && T.all isHex pubkey) "wallet pubkey must be 64 hex characters"
  let pairs = parseQuery (T.drop 1 queryPart)
  secret <- case [v | ("secret", v) <- pairs] of
    (s : _) | T.length s == 64 && T.all isHex s -> Right s
    _ -> Left "secret must be 64 hex characters"
  pure WalletConn
    { wcWalletPubkey = pubkey
    , wcRelays = [v | ("relay", v) <- pairs]
    , wcSecret = secret
    , wcLud16 = case [v | ("lud16", v) <- pairs] of
        (v : _) -> Just v
        _       -> Nothing
    }
  where
    check True _    = Right ()
    check False msg = Left msg
    isHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

    parseQuery q
      | T.null q  = []
      | otherwise = map pair (T.splitOn "&" q)
    pair kv = case T.splitOn "=" kv of
      [k, v] -> (unescape k, unescape v)
      [k]    -> (unescape k, "")
      _      -> ("", "")

    -- Percent-decoding for the query only. Escapes accept both cases, as
    -- encoders vary; a malformed escape fails the whole URI rather than
    -- guessing, because a half-decoded relay URL connects to the wrong
    -- place, which for money is worse than an error.
    unescape t = case T.breakOn "%" t of
      (before, after)
        | T.null after -> before
        | otherwise -> case (T.take 2 (T.drop 1 after), T.drop 3 after) of
            (hex, rest)
              | T.length hex == 2 && T.all isHexDigit hex ->
                  before <> T.singleton (toEnum (hexVal hex)) <> unescape rest
              | otherwise -> before <> "%" <> unescape (T.drop 1 after)
    isHexDigit c = isHex c || (c >= 'A' && c <= 'F')
    hexVal = T.foldl (\a c -> a * 16 + digit c) 0
    digit c
      | c >= '0' && c <= '9' = fromEnum c - fromEnum '0'
      | c >= 'a' = fromEnum c - fromEnum 'a' + 10
      | otherwise = fromEnum c - fromEnum 'A' + 10

-- | Render a connection back to its URI form, encoding relay URLs.
renderWalletUri :: WalletConn -> Text
renderWalletUri c =
  "nostr+walletconnect://"
    <> wcWalletPubkey c
    <> query
  where
    query = case wcRelays c of
      [] -> "?secret=" <> wcSecret c <> lud
      (r : rs) -> "?relay=" <> escape r
        <> T.concat ["&relay=" <> escape r' | r' <- rs]
        <> "&secret=" <> wcSecret c <> lud
    lud = maybe "" ("&lud16=" <>) (wcLud16 c)
    escape = T.concatMap esc
    esc ':' = "%3A"
    esc '/' = "%2F"
    esc '?' = "%3F"
    esc '&' = "%26"
    esc '=' = "%3D"
    esc '#' = "%23"
    esc c   = T.singleton c

-- | The core wallet methods.
data Method
  = MGetInfo
  | MGetBalance
  | MPayInvoice
  | MMUltiPayInvoice
  | MPayKeysend
  | MMakeInvoice
  | MLookupInvoice
  | MListTransactions
  | MSignMessage
  deriving (Show, Eq, Enum, Bounded)

-- | Every method, in spec-table order and written out, so adding one is a
-- visible edit rather than a silent widening.
allMethods :: [Method]
allMethods =
  [ MGetInfo
  , MGetBalance
  , MPayInvoice
  , MMUltiPayInvoice
  , MPayKeysend
  , MMakeInvoice
  , MLookupInvoice
  , MListTransactions
  , MSignMessage
  ]

methodToText :: Method -> Text
methodToText MGetInfo          = "get_info"
methodToText MGetBalance       = "get_balance"
methodToText MPayInvoice       = "pay_invoice"
methodToText MMUltiPayInvoice  = "multi_pay_invoice"
methodToText MPayKeysend       = "pay_keysend"
methodToText MMakeInvoice      = "make_invoice"
methodToText MLookupInvoice    = "lookup_invoice"
methodToText MListTransactions = "list_transactions"
methodToText MSignMessage      = "sign_message"

-- | Map a wire string onto a method, rejecting anything unrecognised.
methodFromText :: Text -> Either String Method
methodFromText t = case lookup t [(methodToText m, m) | m <- allMethods] of
  Just m  -> Right m
  Nothing -> Left ("unknown NIP-47 method: " ++ T.unpack t)

-- | A request payload: the method plus its params object.
data Request = Request
  { reqMethod :: !Method
  , reqParams :: !Value
  } deriving (Show, Eq)

instance ToJSON Request where
  toJSON r = object ["method" .= methodToText (reqMethod r), "params" .= reqParams r]

instance FromJSON Request where
  parseJSON = withObject "Request" $ \o -> do
    methodT <- o .: "method"
    method <- case methodFromText methodT of
      Right m -> pure m
      Left e  -> fail e
    params <- o .: "params"
    pure (Request method params)

-- | Decode a decrypted request payload.
parseRequest :: BS.ByteString -> Either String Request
parseRequest = eitherDecodeStrict

-- | Encode a request payload for encryption.
encodeRequest :: Request -> BS.ByteString
encodeRequest = BL.toStrict . encode

-- | The tags of a request event: NIP-44 mode plus the service's pubkey.
-- The mode tag is what keeps a legacy NIP-04 service from being mistaken
-- for a modern one: without it the service assumes NIP-04, and we refuse to
-- play that game.
buildRequestTags :: Text -> [[Text]]
buildRequestTags walletPubkey =
  [["encryption", "nip44_v2"], ["p", walletPubkey]]

-- | A wallet error: machine code plus human message.
data WalletError = WalletError
  { weCode    :: !Text
  , weMessage :: !Text
  } deriving (Show, Eq)

instance ToJSON WalletError where
  toJSON e = object ["code" .= weCode e, "message" .= weMessage e]

instance FromJSON WalletError where
  parseJSON = withObject "WalletError" $ \o ->
    WalletError <$> o .: "code" <*> o .: "message"

-- | A response payload: the result type plus either a result or an error.
-- The result stays a 'Value' because each method's shape differs and the
-- caller decodes what it asked for; typing every method's result here would
-- invent shapes the spec leaves open.
data Response = Response
  { resType   :: !Method
  , resResult :: !(Maybe Value)
  , resError  :: !(Maybe WalletError)
  } deriving (Show, Eq)

instance ToJSON Response where
  toJSON r = object
    [ "result_type" .= methodToText (resType r)
    , "result" .= resResult r
    , "error" .= resError r
    ]

instance FromJSON Response where
  parseJSON = withObject "Response" $ \o -> do
    typeT <- o .: "result_type"
    method <- case methodFromText typeT of
      Right m -> pure m
      Left e  -> fail e
    Response method <$> o .:? "result" <*> o .:? "error"

-- | Decode a decrypted response payload.
parseResponse :: BS.ByteString -> Either String Response
parseResponse = eitherDecodeStrict

-- | Encode a response payload (the service side, tested for symmetry).
encodeResponse :: Response -> BS.ByteString
encodeResponse = BL.toStrict . encode

-- | The methods a kind-13194 info event advertises: its content split on
-- whitespace. Unknown names pass through as text -- capability discovery is
-- the service's claim, and rejecting the whole advertisement over one
-- experimental method would hide the standard ones.
parseInfoMethods :: Text -> [Text]
parseInfoMethods = T.words
