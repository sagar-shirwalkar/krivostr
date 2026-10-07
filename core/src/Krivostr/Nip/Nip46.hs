{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | NIP-46: nostr-connect, the remote-signer protocol.
--
-- This module is the protocol layer and nothing else. There is no socket, no
-- relay pool and no timer here: those belong in @client/@, which owns all IO.
-- What lives here is the JSON-RPC-ish payload, the kind 24133 wrap, and the
-- NIP-44 conversation that carries them.
--
-- Two things about the current spec contradict older descriptions of NIP-46
-- that are still widely copied, so they are stated up front:
--
-- * There is no @[\"NOSTR\",\"NIP42\",pubkey,payload]@ envelope. Requests and
--   responses are both kind 24133 events whose @content@ is a NIP-44 v2 payload
--   wrapping a JSON object. The conversation is keyed by ECDH between the two
--   peers, not by the legacy NIP-04 shared secret.
--
-- * @sign_message@, @get_relays@ and @close@ are /not/ methods. The method table
--   is 'allMethods'; anything outside it is an unknown method, and the spec
--   requires an unknown method to be answered with an error -- which is what
--   'rejectPayload' is for.
--
-- The @p@ tag addresses every NIP-46 event and it names a /different/ peer
-- depending on the direction: a request @p@-tags the remote signer, a response
-- @p@-tags the client. The half of the NIP-44 conversation key that we do not
-- hold is therefore the @p@ tag of a request and the /author/ of a response.
-- 'requestPeer' and 'responsePeer' exist so that distinction cannot be got
-- wrong at a call site.
--
-- @nip04_encrypt@ and @nip04_decrypt@ are in the method table and are decoded
-- and answered, but this module cannot perform them. NIP-04 is AES-256-CBC over
-- an ECDH secret with a fresh 16-byte IV per message, the IV comes from the OS
-- CSPRNG, and the cipher layer already lives in
-- @client/src/Krivostr/Cli/Nostr.hs@. 'performMethod' returns a @Left@ that says
-- so, rather than a half-implementation that would interoperate with nothing.
module Krivostr.Nip.Nip46
  ( -- * Protocol constant
    requestEventKind
    -- * Connection URIs
  , BunkerUri(..)
  , parseBunkerUri
  , renderBunkerUri
    -- * Methods
  , Method(..)
  , allMethods
  , methodFromText
  , methodToText
    -- * Requests
  , ConnectRequest(..)
  , ConnectParams(..)
  , SignEventParams(..)
  , MethodParams(..)
  , ClientMetadata(..)
  , Permission(..)
  , parsePermissions
  , renderPermissions
  , parseRequest
  , encodeRequest
  , decodeParams
  , encodeParams
    -- * Results and responses
  , MethodResult(..)
  , decodeMethodResult
  , renderMethodResult
  , ConnectResponse(..)
  , parseResponse
  , encodeResponse
  , responseResult
  , authChallengeUrl
  , rejectPayload
    -- * Performing a method
  , performMethod
  , signEventFor
    -- * The kind 24133 wrap
  , conversationKey
  , firstP
  , requestPeer
  , responsePeer
  , buildRequestEvent
  , openRequestEvent
  , openRequestEventUnchecked
  , buildResponseEvent
  , openResponseEvent
  , openResponseEventUnchecked
  ) where

import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  , Value
  , eitherDecodeStrict
  , encode
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.!=)
  , (.=)
  )
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Types as AT
import Data.Char (chr)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (POSIXTime)
import Data.Word (Word8)
import Krivostr.Event
  ( Event (..)
  , UnsignedEvent (..)
  , mkEvent
  )
import Krivostr.Key
  ( PrivateKey
  , PublicKey
  , derivePublicKey
  , pubKeyHex
  , publicKeyFromBytes
  )
import Krivostr.Nip.Nip01 (signEvent, verifyEvent)
import qualified Krivostr.Nip.Nip44 as Nip44

-- * Protocol constant

-- | The event kind used for both request and response events.
--
-- @24133@ is @22 + 23133@: the ephemeral range reserved for protocol-level
-- traffic, offset so it cannot collide with an application kind. It is not the
-- NIP-59 gift-wrap kind, which is @1059@; confusing the two is the usual reason
-- a NIP-46 implementation writes to the wrong subscription.
requestEventKind :: Int
requestEventKind = 24133

-- * Pubkeys

-- | Parse a 64-hex-character pubkey and check that it lifts to a curve point.
--
-- Lowercasing first means an upper-case token is accepted and normalised, which
-- also means a record built through here always renders lower-case.
parsePubkeyHex :: Text -> Either String PublicKey
parsePubkeyHex t =
  case B16.decode (TE.encodeUtf8 (T.toLower t)) of
    Left _ -> Left "NIP-46 pubkey is not valid hex"
    Right bytes
      | BS.length bytes /= 32 -> Left "NIP-46 pubkey must be 32 bytes"
      | otherwise ->
          maybe
            (Left "NIP-46 pubkey is not a valid x-only public key")
            Right
            (publicKeyFromBytes bytes)

-- * Connection URIs

-- | A @bunker://@ connection token: the remote signer pubkey, the relays to
-- reach it on, and an optional one-shot secret.
data BunkerUri = BunkerUri
  { buPubkey :: !Text
    -- ^ The remote-signer pubkey, lower-case hex. 'parseBunkerUri' canonicalises
    -- it, so two tokens naming the same signer compare equal.
  , buRelays :: ![Text]
    -- ^ One or more relay URLs, in the order given. Never empty after
    -- 'parseBunkerUri'.
  , buSecret :: !(Maybe Text)
    -- ^ Optional. The spec calls it good for a single successfully established
    -- connection only.
  }
  deriving (Show, Eq)

-- | Parse a @bunker://@ token as the spec writes it:
--
-- > bunker://<remote-signer-pubkey>?relay=<wss://relay>?relay=<wss://relay2>&secret=<optional>
--
-- Query values are percent-decoded, and @+@ decodes to a space because the
-- spec's own @nostrconnect://@ example writes @name=My+Client@. Rendering escapes
-- a space as @%20@, so a value survives a round trip either way.
--
-- Only the @bunker@ scheme is accepted. @nostrconnect://@ is the opposite
-- direction -- the /client/ hands a token to the remote signer -- and parsing
-- it here would need the client keypair and the requested permissions, which is
-- the other end of the protocol.
parseBunkerUri :: Text -> Either String BunkerUri
parseBunkerUri raw
  | T.null raw = Left "bunker URI is empty"
  | otherwise = do
      (scheme, rest) <- splitScheme raw
      checkScheme scheme
      let (authority, query) = T.breakOn "?" rest
          host = T.dropWhile (== '/') authority
      checkHost host
      signer <- parsePubkeyHex host
      pairs <- queryParams (T.drop 1 query)
      relays <- nonEmptyRelays pairs
      pure
        BunkerUri
          { buPubkey = pubKeyHex signer
          , buRelays = relays
          , buSecret = firstOf "secret" pairs
          }

-- | Render a token that 'parseBunkerUri' accepts.
--
-- The output is percent-encoded, so @wss://a.example@ comes back as
-- @wss%3A%2F%2Fa.example@. That is the spelling in the spec
-- @nostrconnect://@ example and is what a browser @URLSearchParams@ produces,
-- so it re-parses identically; it is not byte-identical to a token a user
-- pasted with the slashes left bare.
--
-- A 'BunkerUri' with no relays renders a token that will not re-parse.
-- 'parseBunkerUri' cannot produce one, so that only happens if a caller builds
-- the record directly.
renderBunkerUri :: BunkerUri -> Text
renderBunkerUri b =
  T.concat
    [ "bunker://"
    , buPubkey b
    , queryString
      ( [("relay", percentEncode r) | r <- buRelays b]
          <> maybe [] (\s -> [("secret", percentEncode s)]) (buSecret b)
      )
    ]

-- | A whole query string. The first parameter opens it with @?@ and the rest
-- continue it with @&@, which is what makes a repeated @relay@ read back as a
-- list rather than as one value with the separators baked into it.
queryString :: [(Text, Text)] -> Text
queryString [] = ""
queryString ((k, v) : kvs) =
  ("?" <> k <> "=" <> v)
    <> T.concat ["&" <> k' <> "=" <> v' | (k', v') <- kvs]

firstOf :: Text -> [(Text, Text)] -> Maybe Text
firstOf name pairs = case [v | (k, v) <- pairs, k == name, not (T.null v)] of
  (v : _) -> Just v
  [] -> Nothing

-- | The scheme delimiter. 'splitScheme' strips this off before reading the
-- authority, so a @://@ prefix can never reach the host.
schemeDelimiter :: Text
schemeDelimiter = "://"

-- | Split @scheme://rest@, refusing anything without the delimiter.
splitScheme :: Text -> Either String (Text, Text)
splitScheme t =
  let (before, rest) = T.breakOn schemeDelimiter t
   in case T.stripPrefix schemeDelimiter rest of
        Nothing -> Left "URI has no scheme delimiter"
        -- The remainder must be non-empty, or there is no authority to read.
        Just after
          | T.null after -> Left "URI has no scheme delimiter"
          | otherwise -> Right (before, after)

checkScheme :: Text -> Either String ()
checkScheme s
  | T.toLower s == "bunker" = Right ()
  | otherwise =
      Left
        ( "unsupported URI scheme: "
            <> T.unpack s
            <> " (only bunker:// is a remote-signer token)"
        )

checkHost :: Text -> Either String ()
checkHost h
  | T.null h = Left "bunker URI has an empty host"
  | otherwise = Right ()

nonEmptyRelays :: [(Text, Text)] -> Either String [Text]
nonEmptyRelays pairs =
  case [v | (k, v) <- pairs, k == "relay"] of
    [] -> Left "bunker URI has no relay parameter"
    rs
      | any T.null rs -> Left "bunker URI has an empty relay parameter"
      | otherwise -> Right rs

-- | Parse a query string into decoded key/value pairs.
--
-- A repeated key is not an error: the spec uses a repeated @relay@, and a
-- single-valued key such as @secret@ resolves to its first occurrence.
queryParams :: Text -> Either String [(Text, Text)]
queryParams q
  | T.null q = Right []
  | otherwise = mapM one (filter (not . T.null) (T.splitOn "&" q))
  where
    one piece = case T.breakOn "=" piece of
      (k, v)
        | T.null v -> Left ("query parameter " <> show (T.unpack k) <> " has no value")
        | otherwise -> do
            dk <- percentDecode k
            dv <- percentDecode (T.drop 1 v)
            pure (dk, dv)

plusByte, spaceByte, percentByte :: Word8
plusByte = 0x2b
spaceByte = 0x20
percentByte = 0x25

-- | Upper-case, because that is what the spec example and a browser
-- @URLSearchParams@ both write. Either case decodes back identically.
hexDigit :: Word8 -> Char
hexDigit n = "0123456789ABCDEF" !! fromIntegral n

hexVal :: Word8 -> Maybe Word8
hexVal w
  | w >= 0x30 && w <= 0x39 = Just (w - 0x30)
  | w >= 0x61 && w <= 0x66 = Just (w - 0x61 + 10)
  | w >= 0x41 && w <= 0x46 = Just (w - 0x41 + 10)
  | otherwise = Nothing

isUnreserved :: Word8 -> Bool
isUnreserved w =
  (w >= 0x41 && w <= 0x5a)
    || (w >= 0x61 && w <= 0x7a)
    || (w >= 0x30 && w <= 0x39)
    || w == 0x2d -- '-'
    || w == 0x2e -- '.'
    || w == 0x5f -- '_'
    || w == 0x7e -- '~'

-- | Percent-decode to bytes, then require the result to be UTF-8.
--
-- Decoding to bytes first is deliberate. A lone @%FF@ is not a character, and
-- substituting a replacement byte would turn a malformed token into one that
-- parses to a different secret than the one that was sent.
percentDecode :: Text -> Either String Text
percentDecode t = (BS.pack <$> go (BS.unpack (TE.encodeUtf8 t))) >>= decodeUtf8
  where
    go :: [Word8] -> Either String [Word8]
    go [] = Right []
    go (b : rest)
      | b == plusByte = (spaceByte :) <$> go rest
      | b /= percentByte = (b :) <$> go rest
      | otherwise = case rest of
          (h1 : h2 : more) -> case (hexVal h1, hexVal h2) of
            (Just a, Just c) -> ((a * 16 + c) :) <$> go more
            _ -> Left "malformed percent-escape in query string"
          _ -> Left "truncated percent-escape in query string"

    decodeUtf8 bytes = case TE.decodeUtf8' bytes of
      Left err -> Left ("percent-decoded query value is not valid UTF-8: " <> show err)
      Right v -> Right v

-- | Percent-encode every byte outside the unreserved set.
--
-- A space becomes @%20@ rather than @+@, which is legal in a query and decodes
-- back to a space either way.
percentEncode :: Text -> Text
percentEncode t = T.concat (map encByte (BS.unpack (TE.encodeUtf8 t)))
  where
    encByte :: Word8 -> Text
    encByte w
      | isUnreserved w = T.singleton (chr (fromIntegral w))
      | otherwise = T.pack ['%', hexDigit (w `div` 16), hexDigit (w `mod` 16)]

-- * Methods

-- | The methods the current NIP-46 defines.
--
-- @sign_event@ rather than @sign_message@: a remote signer signs whole events
-- and there is no message-signing method to fall back on.
data Method
  = MConnect
  | MSignEvent
  | MPing
  | MGetPublicKey
  | MNip04Encrypt
  | MNip04Decrypt
  | MNip44Encrypt
  | MNip44Decrypt
  | MSwitchRelays
  | MLogout
  deriving (Show, Eq, Enum, Bounded)

-- | Every method, in the order the spec table lists them.
--
-- Written out rather than derived from 'Bounded' so adding a constructor is a
-- visible edit here instead of a silent widening of the wire vocabulary.
allMethods :: [Method]
allMethods =
  [ MConnect
  , MSignEvent
  , MPing
  , MGetPublicKey
  , MNip04Encrypt
  , MNip04Decrypt
  , MNip44Encrypt
  , MNip44Decrypt
  , MSwitchRelays
  , MLogout
  ]

methodToText :: Method -> Text
methodToText = \case
  MConnect -> "connect"
  MSignEvent -> "sign_event"
  MPing -> "ping"
  MGetPublicKey -> "get_public_key"
  MNip04Encrypt -> "nip04_encrypt"
  MNip04Decrypt -> "nip04_decrypt"
  MNip44Encrypt -> "nip44_encrypt"
  MNip44Decrypt -> "nip44_decrypt"
  MSwitchRelays -> "switch_relays"
  MLogout -> "logout"

-- | Map a wire string onto a method, rejecting anything unrecognised.
--
-- Total by construction: the round trip through 'methodToText' is the identity
-- over 'allMethods', so an unknown method can never be mis-encoded into a
-- different known one.
methodFromText :: Text -> Either String Method
methodFromText t = case lookup t [(methodToText m, m) | m <- allMethods] of
  Just m -> Right m
  Nothing -> Left ("unknown NIP-46 method: " <> T.unpack t)

-- | 'methodFromText' in a parser, so an unknown method fails the parse with its
-- own message instead of a generic "expected string".
methodFromTextParser :: Text -> AT.Parser Method
methodFromTextParser t = case methodFromText t of
  Right m -> pure m
  Left e -> fail e

-- * Requests

-- | A request as it travels: an id, a method, and the positional string array
-- exactly as it arrived.
--
-- The typed view of @params@ is 'MethodParams'; keeping the raw list here means
-- a wrong arity is a decode failure with a position in it, rather than a
-- silently absent value.
data ConnectRequest = ConnectRequest
  { crId :: !Text
  , crMethod :: !Method
  , crParams :: ![Text]
  }
  deriving (Show, Eq)

instance FromJSON ConnectRequest where
  parseJSON = withObject "ConnectRequest" $ \o ->
    ConnectRequest
      <$> o .: "id"
      <*> (o .: "method" >>= methodFromTextParser)
      <*> o .: "params"

instance ToJSON ConnectRequest where
  toJSON r =
    object
      [ "id" .= crId r
      , "method" .= methodToText (crMethod r)
      , "params" .= crParams r
      ]

-- | Decode a JSON value as a request.
parseRequest :: Value -> Either String ConnectRequest
parseRequest = AT.parseEither parseJSON

encodeRequest :: ConnectRequest -> Value
encodeRequest = toJSON

-- | The JSON text a request payload wraps, before NIP-44.
requestPayload :: ConnectRequest -> BS.ByteString
requestPayload = BL.toStrict . encode

-- | The four optional fields a client may volunteer at connect time.
--
-- The spec is emphatic that this is a display hint and never an authorisation
-- input: a remote signer knows nothing about the client origin, so it renders
-- these strings and must not decide anything from them.
data ClientMetadata = ClientMetadata
  { cmName :: !(Maybe Text)
  , cmUrl :: !(Maybe Text)
  , cmImage :: !(Maybe Text)
  }
  deriving (Show, Eq)

instance ToJSON ClientMetadata where
  toJSON m = object (catMaybes [name, url, image])
    where
      name = ("name" .=) <$> cmName m
      url = ("url" .=) <$> cmUrl m
      image = ("image" .=) <$> cmImage m

instance FromJSON ClientMetadata where
  parseJSON = withObject "ClientMetadata" $ \o ->
    ClientMetadata
      <$> o .:? "name"
      <*> o .:? "url"
      <*> o .:? "image"

-- | The @method[:params]@ permission format.
--
-- @sign_event:4@ means "sign kind 4", per the spec. The argument is left as
-- text because the spec leaves the parameters of the other methods open.
data Permission = Permission
  { permMethod :: !Method
  , permArg :: !(Maybe Text)
  }
  deriving (Show, Eq)

-- | Parse the comma-separated @optional_requested_perms@ string.
--
-- An empty piece is rejected rather than skipped. It means the client built
-- the list wrong, and quietly dropping it would ask the user to approve less
-- than the client displayed.
parsePermissions :: Text -> Either String [Permission]
parsePermissions t
  | T.null t = Right []
  | otherwise = mapM one (T.splitOn "," t)
  where
    one piece = case T.breakOn ":" piece of
      (name, rest) -> do
        m <- methodFromText name
        case T.uncons rest of
          Nothing -> Right (Permission m Nothing)
          Just (_, "") -> Left "permission has an empty parameter after ':'"
          Just (_, arg) -> Right (Permission m (Just arg))

renderPermissions :: [Permission] -> Text
renderPermissions =
  T.intercalate ","
    . map (\p -> methodToText (permMethod p) <> maybe "" (T.cons ':') (permArg p))

-- | Decode UTF-8 JSON bytes into a type, prefixing any failure with what was
-- being decoded.
--
-- Every param that is itself JSON goes through here, so a malformed
-- @sign_event@ template reports the method rather than an orphaned aeson
-- message.
decodeStrictAs :: AT.FromJSON a => String -> BS.ByteString -> Either String a
decodeStrictAs what bs = case eitherDecodeStrict bs of
  Left e -> Left (what <> ": " <> e)
  Right v -> case AT.parseEither parseJSON v of
    Left e -> Left (what <> ": " <> e)
    Right a -> Right a

-- | Params of @connect@, in the spec positional order.
--
-- The secret is what the remote signer must echo back and the client must
-- check: it is the only thing standing between a spoofed connect response and a
-- client that believes it is talking to the signer the user picked.
data ConnectParams = ConnectParams
  { cpRemoteSigner :: !Text
  , cpSecret :: !(Maybe Text)
  , cpPerms :: !(Maybe [Permission])
  , cpMetadata :: !(Maybe ClientMetadata)
  }
  deriving (Show, Eq)

-- | The @[{kind, content, tags, created_at}]@ a @sign_event@ carries.
--
-- A dedicated type rather than 'UnsignedEvent' because the wire shape has no
-- @pubkey@: the signing key is the remote signer choice, and sending one would
-- be a request to be overridden. It is an unsigned template, so
-- 'signEventFor' is what turns it into an event.
data SignEventParams = SignEventParams
  { spKind :: !Int
  , spContent :: !Text
  , spTags :: ![[Text]]
  , spCreatedAt :: !Integer
  }
  deriving (Show, Eq)

instance ToJSON SignEventParams where
  toJSON p =
    object
      [ "kind" .= spKind p
      , "content" .= spContent p
      , "tags" .= spTags p
      , "created_at" .= spCreatedAt p
      ]

instance FromJSON SignEventParams where
  parseJSON = withObject "SignEventParams" $ \o ->
    SignEventParams
      <$> o .: "kind"
      <*> o .: "content"
      <*> o .: "tags"
      <*> o .: "created_at"

-- | The typed view of a request positional params.
data MethodParams
  = ParamsConnect !ConnectParams
  | ParamsSignEvent !SignEventParams
  | ParamsNoArgs !Method
    -- ^ @ping@, @get_public_key@, @switch_relays@ and @logout@.
  | ParamsCipher !Text !Text
    -- ^ Peer pubkey then plaintext (encrypt) or ciphertext (decrypt), shared by
    -- the @nip04_*@ and @nip44_*@ methods alike.
  deriving (Show, Eq)

-- | Decode the positional params for a given method.
decodeParams :: Method -> [Text] -> Either String MethodParams
decodeParams m params = case m of
  MConnect -> ParamsConnect <$> connectParams params
  MSignEvent -> case params of
    [raw] -> ParamsSignEvent <$> decodeStrictAs "sign_event param is not an unsigned event" (TE.encodeUtf8 raw)
    _ -> arity 1
  MPing -> noParams
  MGetPublicKey -> noParams
  MNip04Encrypt -> cipher
  MNip04Decrypt -> cipher
  MNip44Encrypt -> cipher
  MNip44Decrypt -> cipher
  MSwitchRelays -> noParams
  MLogout -> noParams
  where
    noParams = case params of
      [] -> Right (ParamsNoArgs m)
      _ -> arity 0
    cipher = case params of
      [a, b] -> Right (ParamsCipher a b)
      _ -> arity 2
    arity :: Int -> Either String MethodParams
    arity n =
      Left
        ( T.unpack (methodToText m)
            <> " takes "
            <> show n
            <> " params, got "
            <> show (length params)
        )

-- | The positional params for a request, canonically.
--
-- @connect@ drops trailing empty slots. The spec requires an empty string in
-- the permissions position when metadata is sent without permissions, so that
-- the metadata lands fourth; an empty slot is the absent marker, and dropping
-- only trailing ones keeps the mandated filler in place whenever there is
-- something behind it.
encodeParams :: MethodParams -> [Text]
encodeParams = \case
  ParamsConnect c ->
    dropTrailing
      [ cpRemoteSigner c
      , maybe "" id (cpSecret c)
      , maybe "" renderPermissions (cpPerms c)
      , maybe "" jsonText (cpMetadata c)
      ]
  ParamsSignEvent p -> [jsonText p]
  ParamsNoArgs _ -> []
  ParamsCipher a b -> [a, b]
  where
    jsonText :: AT.ToJSON a => a -> Text
    jsonText = TE.decodeUtf8 . BL.toStrict . encode
    dropTrailing xs = reverse (dropWhile T.null (reverse xs))

-- | Read the @connect@ slots, which are positional after the signer:
-- @\[remote_signer_pubkey, secret, perms, client_metadata\]@.
--
-- @rest@ already starts at the second element, so the secret is slot 0 of it.
connectParams :: [Text] -> Either String ConnectParams
connectParams params = case params of
  (signer : rest) -> do
    signer' <- parsePubkeyHex signer
    let secret = slot 0 rest
        permsText = slot 1 rest
        metadataText = slot 2 rest
    perms <-
      if T.null permsText
        then Right Nothing
        else Just <$> parsePermissions permsText
    metadata <-
      if T.null metadataText
        then Right Nothing
        else Just <$> decodeStrictAs "connect metadata is not an object" (TE.encodeUtf8 metadataText)
    pure
      ConnectParams
        { cpRemoteSigner = pubKeyHex signer'
        , cpSecret = if T.null secret then Nothing else Just secret
        , cpPerms = perms
        , cpMetadata = metadata
        }
  [] -> Left "connect takes at least the remote-signer pubkey"
  where
    -- Slots past the end of the list are the empty string, which is exactly how
    -- the spec spells an absent optional.
    slot i xs = case drop i xs of
      (v : _) -> v
      [] -> ""

-- * Results

-- | A method result, decoded according to the method that produced it.
--
-- The failure path is the @Left@ of the @Either String MethodResult@ a response
-- decodes to: a method can always have been refused, and the spec requires the
-- refusal to travel as an @error@ string rather than as a result.
data MethodResult
  = Ack
    -- ^ @\"ack\"@: @connect@ accepted without an echo, and @logout@.
  | ConnectToken !Text
    -- ^ @connect@ returning the secret the client must check.
  | Pong
  | Pubkey !Text
    -- ^ @get_public_key@: the /user/ pubkey, which need not be the signer's own.
  | Ciphertext !Text
  | Plaintext !Text
  | SignedEvent !Event
  | Relays !(Maybe [Text])
    -- ^ @switch_relays@: a new relay list, or @Nothing@ for the spec @null@,
    -- meaning nothing to change.
  deriving (Show, Eq)

-- | Decode the result string for the method that produced it.
decodeMethodResult :: Method -> Text -> Either String MethodResult
decodeMethodResult m result = case m of
  MConnect
    | result == "ack" -> Right Ack
    | otherwise -> Right (ConnectToken result)
  MSignEvent -> SignedEvent <$> decodeStrictAs "sign_event result is not a signed event" (TE.encodeUtf8 result)
  MPing
    | result == "pong" -> Right Pong
    | otherwise -> bad "pong"
  MGetPublicKey -> Pubkey . pubKeyHex <$> parsePubkeyHex result
  MNip04Encrypt -> Right (Ciphertext result)
  MNip04Decrypt -> Right (Plaintext result)
  MNip44Encrypt -> Right (Ciphertext result)
  MNip44Decrypt -> Right (Plaintext result)
  MSwitchRelays
    | result == "null" -> Right (Relays Nothing)
    | otherwise ->
        Relays . Just <$> decodeStrictAs "switch_relays result is not a relay list" (TE.encodeUtf8 result)
  MLogout
    | result == "ack" -> Right Ack
    | otherwise -> bad "ack"
  where
    bad expected =
      Left
        ( T.unpack (methodToText m)
            <> " result must be "
            <> show (T.unpack expected)
            <> ", got "
            <> show (T.unpack result)
        )

-- | Render a result back into the string a response carries.
--
-- The fixed strings are checked against the method, so a caller cannot put a
-- @Pong@ in a @logout@ response by mistake.
renderMethodResult :: Method -> MethodResult -> Either String Text
renderMethodResult m r = case r of
  Pong
    | m == MPing -> Right "pong"
    | otherwise -> mismatch
  Ack
    | m == MConnect || m == MLogout -> Right "ack"
    | otherwise -> mismatch
  ConnectToken t -> Right t
  Pubkey t -> Right t
  Ciphertext t -> Right t
  Plaintext t -> Right t
  SignedEvent e -> Right (TE.decodeUtf8 (BL.toStrict (encode e)))
  Relays Nothing -> Right "null"
  Relays (Just rs) -> Right (TE.decodeUtf8 (BL.toStrict (encode rs)))
  where
    mismatch = Left (T.unpack (methodToText m) <> " cannot answer with " <> show r)

-- * Responses

-- | A response payload: the id it answers, the result string, and an optional
-- error string.
--
-- @resResult@ is a 'Text' rather than a @Maybe Text@ because the spec writes an
-- auth challenge as the literal @\"auth_url\"@ in @result@, with the end-user URL
-- in @error@. Keeping the string as the spec has it means all three object
-- shapes encode byte for byte with no special case. Use 'responseResult' for the
-- @Either@ a caller actually wants.
data ConnectResponse = ConnectResponse
  { resId :: !Text
  , resResult :: !Text
  , resError :: !(Maybe Text)
  }
  deriving (Show, Eq)

-- | A response omits @result@ when it is empty. The spec says an @error@ means
-- the call failed, and a bare @\"result\": \"\"@ on the wire reads as a successful
-- empty answer instead. 'FromJSON' still accepts a missing @result@.
instance ToJSON ConnectResponse where
  toJSON r =
    object $
      ["id" .= resId r]
        <> (if T.null (resResult r) then [] else ["result" .= resResult r])
        <> maybe [] (\e -> ["error" .= e]) (resError r)

instance FromJSON ConnectResponse where
  parseJSON = withObject "ConnectResponse" $ \o ->
    ConnectResponse
      <$> o .: "id"
      <*> (o .:? "result" .!= "")
      <*> o .:? "error"

parseResponse :: Value -> Either String ConnectResponse
parseResponse = AT.parseEither parseJSON

encodeResponse :: ConnectResponse -> Value
encodeResponse = toJSON

-- | The result, or the error the remote signer reported.
--
-- An error field always wins: the spec says its presence indicates the request
-- failed, whatever @result@ says.
responseResult :: ConnectResponse -> Either String Text
responseResult r = case resError r of
  -- Unpacked because this module reports failures as 'String' throughout, and
  -- a remote signer's error is a message for a log or a label rather than
  -- something to post back onto the wire.
  Just e -> Left (T.unpack e)
  Nothing -> Right (resResult r)

-- | The URL from an auth challenge, if this response is one.
--
-- The spec puts the literal @\"auth_url\"@ in @result@ and the end-user URL in
-- @error@ -- the two fields are transposed relative to what they mean. That is
-- the spec, so that is the shape this produces and the shape 'parseResponse'
-- recognises; the client shows the URL and then waits for another response
-- carrying the same id.
authChallengeUrl :: ConnectResponse -> Maybe Text
authChallengeUrl r
  | resResult r == "auth_url" && hasError = resError r
  | otherwise = Nothing
  where
    hasError = maybe False (const True) (resError r)

-- | Build the error response the spec requires for a payload we could not parse.
--
-- "Requests made with unknown or unsupported methods MUST be replied with an
-- error" -- and a payload whose @method@ is a number is not a request at all, so
-- there is no 'ConnectRequest' to take an id from. Whatever id is readable is
-- used, so a client can still match the reply to the request that it sent.
rejectPayload :: Value -> Text -> ConnectResponse
rejectPayload v reason = ConnectResponse (payloadId v) "" (Just reason)

payloadId :: Value -> Text
payloadId (Aeson.Object o) = case KM.lookup "id" o of
  Just (Aeson.String s) -> s
  _ -> ""
payloadId _ = ""

-- * Performing a method

-- | Sign the template a @sign_event@ carries with the user key.
--
-- 'Krivostr.Nip.Nip01.signEvent' fills the pubkey in from the key, so the
-- result is a complete event that verifies against the user pubkey -- not
-- against the client pubkey that carried the request.
signEventFor :: PrivateKey -> SignEventParams -> Event
signEventFor sk p =
  signEvent sk
    Event
      { evId = ""
      , evPubkey = ""
      , evCreatedAt = posixFromSeconds (spCreatedAt p)
      , evKind = spKind p
      , evTags = spTags p
      , evContent = spContent p
      , evSig = ""
      }

-- | Answer a request.
--
-- The nonce is the caller to draw because this module is pure and a NIP-44
-- nonce has to be fresh per message. It is read only by @nip44_encrypt@, whose
-- result is a ciphertext to a third party; the outer response envelope gets its
-- own nonce, supplied to 'buildResponseEvent'. Those are two independent
-- conversations, and reusing one nonce across them is the mistake this split
-- makes hard to commit.
--
-- @nip04_encrypt@ and @nip04_decrypt@ return @Left@: NIP-04 is AES-256-CBC with
-- a fresh 16-byte IV per message, the IV has to come from the OS CSPRNG, and the
-- cipher layer is in @client/src/Krivostr/Cli/Nostr.hs@.
--
-- @connect@ and @switch_relays@ can only be answered from the request, which is
-- not the whole truth about either. A real remote signer has to consult its
-- stored session, its per-user approval, and its own current relay list; this
-- is the plumbing around that decision, so callers should override 'Ack' and
-- @Relays Nothing@ with what they actually decided.
performMethod :: BS.ByteString -> PrivateKey -> ConnectRequest -> Either String MethodResult
performMethod nonce sk req = case crMethod req of
  MConnect -> Ack <$ decodeParams MConnect (crParams req)
  MSignEvent -> do
    p <- decodeParams MSignEvent (crParams req)
    case p of
      ParamsSignEvent u -> pure (SignedEvent (signEventFor sk u))
      _ -> Left "sign_event params did not decode"
  MPing -> Pong <$ decodeParams MPing (crParams req)
  MGetPublicKey -> do
    _ <- decodeParams MGetPublicKey (crParams req)
    pure (Pubkey (pubKeyHex (derivePublicKey sk)))
  MNip04Encrypt -> notImplemented "nip04_encrypt"
  MNip04Decrypt -> notImplemented "nip04_decrypt"
  MNip44Encrypt -> do
    p <- decodeParams MNip44Encrypt (crParams req)
    case p of
      ParamsCipher peer plaintext ->
        Ciphertext <$> Nip44.encryptWithNonce sk peer nonce (TE.encodeUtf8 plaintext)
      _ -> Left "nip44_encrypt params did not decode"
  MNip44Decrypt -> do
    p <- decodeParams MNip44Decrypt (crParams req)
    case p of
      ParamsCipher peer ciphertext -> do
        plain <- Nip44.decrypt sk peer ciphertext
        Plaintext <$> utf8 plain
      _ -> Left "nip44_decrypt params did not decode"
  MSwitchRelays -> Relays Nothing <$ decodeParams MSwitchRelays (crParams req)
  MLogout -> Ack <$ decodeParams MLogout (crParams req)
  where
    -- A decrypted payload that is not UTF-8 is a protocol violation, not
    -- something to paper over with a replacement character.
    utf8 bytes = case TE.decodeUtf8' bytes of
      Left err -> Left ("decrypted plaintext is not UTF-8: " <> show err)
      Right t -> Right t

    notImplemented name =
      Left
        ( name
            <> " is not implemented: NIP-04 needs AES-256-CBC with a fresh random IV,"
            <> " which is IO and lives in client/src/Krivostr/Cli/Nostr.hs"
        )

-- * The kind 24133 wrap

-- | The NIP-44 conversation key shared with the remote signer.
--
-- Named here so a caller does not have to know this is NIP-44 own derivation;
-- the implementation is 'Krivostr.Nip.Nip44.conversationKeyWithHex' and there
-- is no second derivation here to drift from it.
conversationKey :: PrivateKey -> Text -> Either String BS.ByteString
conversationKey = Nip44.conversationKeyWithHex

-- | The first @p@ tag on an event, if any.
--
-- NIP-46 needs exactly one, and it names the other end of the conversation.
-- Extra @p@ tags are ignored rather than rejected: they are legal on a NIP-01
-- event, and a peer that adds one has not misbehaved.
firstP :: Event -> Maybe Text
firstP ev = case [t | tag <- evTags ev, Just t <- [tagValue "p" tag]] of
  (t : _) -> Just t
  [] -> Nothing
  where
    tagValue name tag = case tag of
      (n : v : _) | n == name -> Just v
      _ -> Nothing

-- | Which remote signer a request addresses, from its @p@ tag.
--
-- Routing, not crypto: it answers "who is this for" when a client juggles
-- several bunkers, or "is this for me" for a service. The decryption peer
-- is always the author (see 'openRequestEventUnchecked'), because the
-- shared secret has two halves and the @p@ tag names the opener's own.
requestPeer :: Event -> Either String Text
requestPeer ev = case firstP ev of
  Nothing -> Left "request event has no p tag naming the remote signer"
  Just t -> pubKeyHex <$> parsePubkeyHex t

-- | The remote signer half of the conversation a response answers in.
--
-- From the /author/. A response @p@ tag names the client, not the signer.
responsePeer :: Event -> Either String Text
responsePeer ev = pubKeyHex <$> parsePubkeyHex (evPubkey ev)

checkKind :: Event -> Either String ()
checkKind ev
  | evKind ev == requestEventKind = Right ()
  | otherwise = Left ("expected a kind 24133 event, got kind " <> show (evKind ev))

-- | Build the signed kind 24133 event that carries a request.
--
-- The event is signed with the client keypair: the remote signer uses the
-- author to know who to answer and which session to authorise, so an unsigned
-- request is not merely untidy, it is unauthenticated.
--
-- The @p@ tag and the encryption target are the same canonical pubkey, so the
-- tag cannot disagree with the conversation key that was used.
buildRequestEvent
  :: PrivateKey -> Text -> Integer -> BS.ByteString -> ConnectRequest -> Either String Event
buildRequestEvent clientSk signerHex createdAt nonce req = do
  signer <- parsePubkeyHex signerHex
  let signerText = pubKeyHex signer
  payload <- Nip44.encryptWithNonce clientSk signerText nonce (requestPayload req)
  pure (signEvent clientSk (wrapEvent clientSk signerText createdAt payload))

-- | Read the request out of a kind 24133 event, having checked its signature.
--
-- The check is not optional in practice. An event of the right kind carrying a
-- valid NIP-44 payload can be produced by anyone who knows the client pubkey --
-- the payload itself is not what proves the sender, and a remote signer that
-- skips this is answering a stranger.
openRequestEvent :: PrivateKey -> Event -> Either String ConnectRequest
openRequestEvent sk ev = do
  checkKind ev
  if verifyEvent ev then Right () else Left "request event is not correctly signed"
  openRequestEventUnchecked sk ev

-- | As 'openRequestEvent', for an event already known to verify.
openRequestEventUnchecked :: PrivateKey -> Event -> Either String ConnectRequest
openRequestEventUnchecked sk ev = do
  -- The author, not the @p@ tag: the conversation key has two halves, and
  -- the opener holds one of them, so the other half is whoever signed.
  -- Decrypting with the @p@ tag would ECDH the opener with itself, which is
  -- why only same-key round trips ever passed before.
  plain <- Nip44.decrypt sk (evPubkey ev) (evContent ev)
  parseRequest
    =<< decodeStrictAs "request payload is not JSON" plain

-- | Build the signed kind 24133 event that carries a response.
buildResponseEvent
  :: PrivateKey -> Text -> Integer -> BS.ByteString -> ConnectResponse -> Either String Event
buildResponseEvent signerSk clientHex createdAt nonce resp = do
  client <- parsePubkeyHex clientHex
  let clientText = pubKeyHex client
  payload <-
    Nip44.encryptWithNonce signerSk clientText nonce (BL.toStrict (encode resp))
  pure (signEvent signerSk (wrapEvent signerSk clientText createdAt payload))

-- | Read the response out of a kind 24133 event, having checked its signature.
--
-- This is the check a client has to insist on: nothing on the wire proves the
-- author is the signer the user named, and the connect secret is only one
-- answer to that question, not a proof of identity.
openResponseEvent :: PrivateKey -> Event -> Either String ConnectResponse
openResponseEvent sk ev = do
  checkKind ev
  if verifyEvent ev then Right () else Left "response event is not correctly signed"
  openResponseEventUnchecked sk ev

-- | As 'openResponseEvent', for an event already known to verify.
openResponseEventUnchecked :: PrivateKey -> Event -> Either String ConnectResponse
openResponseEventUnchecked sk ev = do
  peer <- responsePeer ev
  plain <- Nip44.decrypt sk peer (evContent ev)
  parseResponse
    =<< decodeStrictAs "response payload is not JSON" plain

-- | The unsigned shell both wraps share: kind 24133, a @p@ tag naming the
-- peer, and the NIP-44 payload as the content. Signing fills in the rest.
wrapEvent :: PrivateKey -> Text -> Integer -> Text -> Event
wrapEvent sk peerHex createdAt payload =
  mkEvent
    UnsignedEvent
      { uePubkey = pubKeyHex (derivePublicKey sk)
      , ueCreatedAt = posixFromSeconds createdAt
      , ueKind = requestEventKind
      , ueTags = [["p", peerHex]]
      , ueContent = payload
      }

-- | Seconds as a 'POSIXTime'.
--
-- Not 'fromInteger': 'POSIXTime' is a 'NominalDiffTime' whose 'fromInteger'
-- counts /days/, so that would be off by a factor of 86400.
posixFromSeconds :: Integer -> POSIXTime
posixFromSeconds s = realToFrac (fromIntegral s :: Integer)