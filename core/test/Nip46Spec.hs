{-# LANGUAGE OverloadedStrings #-}

-- | NIP-46: nostr-connect.
--
-- Two kinds of assertion live here and the difference matters. The wire shapes
-- -- a request payload, a response object, a @sign_event@ template -- are
-- pinned against the JSON text the spec shows, decoded to 'Value' rather than
-- compared as bytes: aeson orders the keys of a multi-key object by hash, so
-- byte equality on such an object would pin this build's hash order rather than
-- the protocol. Arrays and single-key objects have no such freedom, and those
-- /are/ compared byte for byte.
--
-- The cryptographic paths use fixed scalars and a fixed nonce throughout. A
-- round-trip test over a random nonce passes just as happily if both ends share
-- the same wrong conversation key, which is the one thing NIP-46 must not get
-- wrong, so the payload assertions here are all deterministic and the
-- wrong-peer cases are explicit.
module Nip46Spec (nip46Spec) where

import Data.Aeson (ToJSON (toJSON), Value, eitherDecodeStrict, encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Krivostr.Event (Event (..))
import Krivostr.Key
  ( PrivateKey
  , derivePublicKey
  , importHex
  , pubKeyHex
  )
import Krivostr.Nip.Nip01 (signEvent, verifyEvent)
import qualified Krivostr.Nip.Nip44 as Nip44
import Krivostr.Nip.Nip46
import Test.Hspec

-- | Unwrap an 'Either' in the spec monad, failing the example with the library
-- own message.
fromRight :: Either String a -> IO a
fromRight = either (ioError . userError) pure

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

scalar :: Text -> PrivateKey
scalar t = either (error . ("bad secret key: " ++)) id (importHex t)

-- | A fixed nonce: bytes 0x00 through 0x1f, so it is obviously not a vector from
-- the spec and cannot be confused with one.
testNonce :: BS.ByteString
testNonce = BS.pack [0 .. 31]

-- | A second fixed nonce, to show a payload is bound to its message.
otherNonce :: BS.ByteString
otherNonce = BS.pack [31, 30 .. 0]

-- The spec example flow names these pubkeys but gives no secrets, so the
-- cryptographic tests below use fixed scalars of their own and these are used
-- only where the spec text is what is being tested.

-- | The remote-signer (and, in that example, user) pubkey from the spec.
specSigner :: Text
specSigner = "fa984bd7dbb282f07e16e7ae87b26a2a7b9b90b7246a44771f0cf5ae58018f52"

-- | The client pubkey from the spec.
specClient :: Text
specClient = "eff37350d839ce3707332348af4549a96051bd695d3223af4aabce4993531d86"

clientSk, signerSk, userSk, strangerSk, thirdPartySk :: PrivateKey
clientSk = scalar "0000000000000000000000000000000000000000000000000000000000000001"
signerSk = scalar "0000000000000000000000000000000000000000000000000000000000000002"
userSk = scalar "0000000000000000000000000000000000000000000000000000000000000003"
strangerSk = scalar "0000000000000000000000000000000000000000000000000000000000000004"
thirdPartySk = scalar "0000000000000000000000000000000000000000000000000000000000000005"

pubHex :: PrivateKey -> Text
pubHex = pubKeyHex . derivePublicKey

clientHex, signerHex, userHex, strangerHex, thirdPartyHex :: Text
clientHex = pubHex clientSk
signerHex = pubHex signerSk
userHex = pubHex userSk
strangerHex = pubHex strangerSk
thirdPartyHex = pubHex thirdPartySk

-- | The unsigned template inside the spec sign_event example, in the spec own
-- field order. Decoding is order-independent, so the order here only records
-- what the spec shows.
specSignEventParam :: Text
specSignEventParam =
  "{\"content\":\"Hello, I'm signing remotely\",\"kind\":1,"
    <> "\"tags\":[],\"created_at\":1714078911}"

specSignEventParams :: SignEventParams
specSignEventParams =
  SignEventParams
    { spKind = 1
    , spContent = "Hello, I'm signing remotely"
    , spTags = []
    , spCreatedAt = 1714078911
    }

-- | The smallest escape needed to nest one JSON string inside another.
jsonQuote :: Text -> Text
jsonQuote t = "\"" <> T.concatMap esc t <> "\""
  where
    esc c = case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      _ -> T.singleton c

-- | The request payload the spec example shows.
specSignEventRequest :: Text
specSignEventRequest =
  "{\"id\":\"request-1\",\"method\":\"sign_event\",\"params\":["
    <> jsonQuote specSignEventParam
    <> "]}"

isRight :: Either a b -> Bool
isRight = not . isLeft

-- | Parse a JSON literal from the test. Keeps the wire-form assertions readable:
-- the expected value is written as the exact text from the spec.
--
-- Pure, and failing loudly on a malformed literal rather than through
-- 'fromRight', because it appears as an operand in an equality the compiler has
-- to type as a 'Value'. The example at the end of this module checks that the
-- literals are well formed, which is the property that keeps this from being a
-- silent trap.
valueOf :: Text -> Value
valueOf t = case eitherDecodeStrict (TE.encodeUtf8 t) of
  Right v -> v
  Left e -> error ("Nip46Spec.valueOf: not JSON: " <> e <> " in " <> T.unpack t)

-- | The same, as a strict 'BS.ByteString'.
bytesOf :: Text -> BS.ByteString
bytesOf = TE.encodeUtf8

-- | The JSON text of a value: the string a NIP-46 @result@ field carries.
jsonText :: ToJSON a => a -> Text
jsonText = TE.decodeUtf8 . BL.toStrict . encode

nip46Spec :: Spec
nip46Spec = describe "NIP-46" $ do
  describe "bunker URI" $ do
    it "parses the token shape the spec writes" $
      parseBunkerUri
        ("bunker://" <> specSigner <> "?relay=wss://relay1.example.com"
           <> "&relay=wss://relay2.example2.com&secret=0s8j2djs")
        `shouldBe` Right
          BunkerUri
            { buPubkey = specSigner
            , buRelays = ["wss://relay1.example.com", "wss://relay2.example2.com"]
            , buSecret = Just "0s8j2djs"
            }

    it "percent-decodes relay urls the way the spec example encodes them" $
      parseBunkerUri ("bunker://" <> specSigner <> "?relay=wss%3A%2F%2Frelay1.example.com")
        `shouldBe` Right
          BunkerUri
            { buPubkey = specSigner
            , buRelays = ["wss://relay1.example.com"]
            , buSecret = Nothing
            }

    it "percent-decodes a secret containing reserved characters" $
      buSecret
        <$> parseBunkerUri ("bunker://" <> specSigner <> "?relay=wss%3A%2F%2Fa.example&secret=a%2Bb%3Dc%2F")
        `shouldBe` Right (Just "a+b=c/")

    it "treats a missing secret as absent rather than empty" $ do
      r <- fromRight (parseBunkerUri ("bunker://" <> specSigner <> "?relay=wss://a.example"))
      buSecret r `shouldBe` Nothing

    it "keeps the relays in the order the token lists them" $
      buRelays
        <$> parseBunkerUri ("bunker://" <> specSigner <> "?relay=wss://b.example&relay=wss://a.example")
        `shouldBe` Right ["wss://b.example", "wss://a.example"]

    it "rejects a token with no relay parameter" $
      parseBunkerUri ("bunker://" <> specSigner <> "?secret=0s8j2djs")
        `shouldSatisfy` isLeft

    it "rejects an empty relay parameter" $
      parseBunkerUri ("bunker://" <> specSigner <> "?relay=") `shouldSatisfy` isLeft

    it "rejects the nostrconnect scheme, which is the other direction" $
      -- The spec own nostrconnect example. It is a real token, just not a
      -- bunker token: the client hands it to the signer, not the reverse.
      parseBunkerUri
        ( "nostrconnect://83f3b2ae6aa368e8275397b9c26cf550101d63ebaab900d19dd4a4429f5ad8f5"
            <> "?relay=wss%3A%2F%2Frelay1.example.com&secret=0s8j2djs"
        )
        `shouldSatisfy` isLeft

    it "rejects an empty host" $ do
      parseBunkerUri ("bunker://?relay=wss://a.example") `shouldSatisfy` isLeft
      parseBunkerUri "bunker://" `shouldSatisfy` isLeft

    it "rejects a host that is not 64 hex characters" $
      parseBunkerUri "bunker://not-a-pubkey?relay=wss://a.example" `shouldSatisfy` isLeft

    it "rejects a host that is 64 hex characters but not on the curve" $
      parseBunkerUri ("bunker://" <> T.replicate 64 "0" <> "?relay=wss://a.example")
        `shouldSatisfy` isLeft

    it "rejects a token with no scheme delimiter" $
      parseBunkerUri ("bunker:" <> specSigner) `shouldSatisfy` isLeft

    it "rejects a malformed percent escape" $
      parseBunkerUri ("bunker://" <> specSigner <> "?relay=wss%zz")
        `shouldSatisfy` isLeft

    it "rejects a truncated percent escape" $
      parseBunkerUri ("bunker://" <> specSigner <> "?relay=wss%4")
        `shouldSatisfy` isLeft

    it "rejects a percent escape that is not valid UTF-8" $
      parseBunkerUri ("bunker://" <> specSigner <> "?relay=wss%FF")
        `shouldSatisfy` isLeft

    it "rejects a query parameter with no value" $
      parseBunkerUri ("bunker://" <> specSigner <> "?relay") `shouldSatisfy` isLeft

    it "normalises an upper-case host to lower-case hex" $
      buPubkey
        <$> parseBunkerUri ("bunker://" <> T.toUpper specSigner <> "?relay=wss://a.example")
        `shouldBe` Right specSigner

    it "round-trips through render then parse" $
      mapM_
        ( \u -> do
            parsed <- fromRight (parseBunkerUri u)
            parseBunkerUri (renderBunkerUri parsed) `shouldBe` Right parsed
        )
        [ "bunker://" <> specSigner <> "?relay=wss://relay1.example.com&secret=0s8j2djs"
        , "bunker://" <> specSigner <> "?relay=wss%3A%2F%2Fa.example&relay=wss%3A%2F%2Fb.example"
        , "bunker://" <> specSigner <> "?relay=wss%3A%2F%2Fa.example&secret=a%2Bb%3Dc%2F"
        , "bunker://" <> specSigner <> "?relay=wss%3A%2F%2Fa.example&secret=has%20space"
        ]

    it "renders the scheme, host and a percent-encoded query" $
      renderBunkerUri
        (BunkerUri {buPubkey = specSigner, buRelays = ["wss://a.example"], buSecret = Nothing})
        `shouldBe` ("bunker://" <> specSigner <> "?relay=wss%3A%2F%2Fa.example")

    it "omits the secret parameter when there is no secret" $
      T.isInfixOf "secret"
        ( renderBunkerUri
            (BunkerUri {buPubkey = specSigner, buRelays = ["wss://a.example"], buSecret = Nothing})
        )
        `shouldBe` False

  describe "method names" $ do
    it "round-trips every method through its wire string" $
      mapM_ (\m -> methodFromText (methodToText m) `shouldBe` Right m) allMethods

    it "renders exactly the methods the spec table lists" $
      map methodToText allMethods
        `shouldBe` [ "connect"
                   , "sign_event"
                   , "ping"
                   , "get_public_key"
                   , "nip04_encrypt"
                   , "nip04_decrypt"
                   , "nip44_encrypt"
                   , "nip44_decrypt"
                   , "switch_relays"
                   , "logout"
                   ]

    it "rejects the methods the spec removed: sign_message, get_relays, close" $
      mapM_ (\t -> methodFromText t `shouldSatisfy` isLeft) ["sign_message", "get_relays", "close"]

    it "rejects an unknown method" $
      methodFromText "sign_eve" `shouldSatisfy` isLeft

    it "rejects an empty method name" $
      methodFromText "" `shouldSatisfy` isLeft

    it "is case sensitive, as the spec table is lower case throughout" $
      methodFromText "PING" `shouldSatisfy` isLeft

  describe "requested permissions" $ do
    it "parses the comma-separated list from the spec example" $
      parsePermissions "nip44_encrypt,nip44_decrypt,sign_event:13,sign_event:14,sign_event:1059"
        `shouldBe` Right
          [ Permission MNip44Encrypt Nothing
          , Permission MNip44Decrypt Nothing
          , Permission MSignEvent (Just "13")
          , Permission MSignEvent (Just "14")
          , Permission MSignEvent (Just "1059")
          ]

    it "parses the spec's two-method example" $
      parsePermissions "nip44_encrypt,sign_event:4"
        `shouldBe` Right [Permission MNip44Encrypt Nothing, Permission MSignEvent (Just "4")]

    it "round-trips through render then parse" $
      mapM_
        ( \t -> do
            perms <- fromRight (parsePermissions t)
            renderPermissions perms `shouldBe` t
        )
        [ "nip44_encrypt"
        , "sign_event:4"
        , "nip44_encrypt,nip44_decrypt,sign_event:13,sign_event:14,sign_event:1059"
        ]

    it "reads an empty permission list as no permissions" $
      parsePermissions "" `shouldBe` Right []

    it "rejects an unknown method in the list" $
      parsePermissions "sign_message" `shouldSatisfy` isLeft

    it "rejects an empty parameter after the colon" $
      parsePermissions "sign_event:" `shouldSatisfy` isLeft

    it "rejects a trailing comma rather than dropping the empty permission" $
      parsePermissions "sign_event:4," `shouldSatisfy` isLeft

  describe "request payloads" $ do
    it "parses the spec's sign_event example" $ do
      req <- fromRight (parseRequest (valueOf specSignEventRequest))
      crId req `shouldBe` "request-1"
      crMethod req `shouldBe` MSignEvent
      crParams req `shouldBe` [specSignEventParam]

    it "decodes the spec's sign_event template out of its params" $
      decodeParams MSignEvent [specSignEventParam] `shouldBe` Right (ParamsSignEvent specSignEventParams)

    it "parses a ping, the simplest request" $
      parseRequest (valueOf "{\"id\":\"a\",\"method\":\"ping\",\"params\":[]}")
        `shouldBe` Right (ConnectRequest "a" MPing [])

    it "encodes params as a positional array of strings, in order" $
      -- Array element order is part of the contract, so this one is compared as
      -- bytes rather than through a Value.
      encode (toJSON (crParams (ConnectRequest "i" MSignEvent ["first", "second"])))
        `shouldBe` "[\"first\",\"second\"]"

    it "round-trips every method name through a JSON payload" $
      mapM_
        ( \m -> do
            let req = ConnectRequest "r" m []
            parseRequest (encodeRequest req) `shouldBe` Right req
        )
        allMethods

    it "rejects a method that is a number" $
      parseRequest (valueOf "{\"id\":\"a\",\"method\":42,\"params\":[]}")
        `shouldSatisfy` isLeft

    it "rejects a method that is null" $
      parseRequest (valueOf "{\"id\":\"a\",\"method\":null,\"params\":[]}")
        `shouldSatisfy` isLeft

    it "rejects a missing id" $
      parseRequest (valueOf "{\"method\":\"ping\",\"params\":[]}") `shouldSatisfy` isLeft

    it "rejects an unknown method" $
      parseRequest (valueOf "{\"id\":\"a\",\"method\":\"sign_message\",\"params\":[]}")
        `shouldSatisfy` isLeft

    it "rejects params that are not an array" $
      parseRequest (valueOf "{\"id\":\"a\",\"method\":\"ping\",\"params\":\"none\"}")
        `shouldSatisfy` isLeft

    it "rejects params holding a number, since every param is a string" $
      parseRequest (valueOf "{\"id\":\"a\",\"method\":\"ping\",\"params\":[1]}")
        `shouldSatisfy` isLeft

    it "rejects a payload that is not a JSON object" $
      parseRequest (toJSON (["a", "ping"] :: [Text])) `shouldSatisfy` isLeft

    it "rejects a sign_event param that is not an unsigned event" $
      decodeParams MSignEvent ["{\"kind\":1}"] `shouldSatisfy` isLeft

    it "rejects a sign_event param that is not JSON at all" $
      decodeParams MSignEvent ["not json"] `shouldSatisfy` isLeft

    it "rejects the wrong number of params for a no-arg method" $
      decodeParams MPing ["unexpected"] `shouldSatisfy` isLeft

    it "rejects the wrong number of params for a two-arg method" $ do
      decodeParams MNip44Encrypt ["only-one"] `shouldSatisfy` isLeft
      decodeParams MNip44Encrypt ["a", "b", "c"] `shouldSatisfy` isLeft

  describe "connect params" $ do
    it "decodes the spec's four positional slots" $
      decodeParams
        MConnect
        [ specSigner
        , "0s8j2djs"
        , "nip44_encrypt,sign_event:4"
        , "{\"name\":\"My Client\"}"
        ]
        `shouldBe` Right
          ( ParamsConnect
              ConnectParams
                { cpRemoteSigner = specSigner
                , cpSecret = Just "0s8j2djs"
                , cpPerms = Just [Permission MNip44Encrypt Nothing, Permission MSignEvent (Just "4")]
                , cpMetadata = Just (ClientMetadata (Just "My Client") Nothing Nothing)
                }
          )

    it "keeps the empty permissions slot the spec requires when only metadata is sent" $
      -- "To send metadata without requesting permissions, an empty string MUST
      -- be passed for optional_requested_perms so that the metadata occupies the
      -- fourth position."
      decodeParams MConnect [specSigner, "", "", "{\"name\":\"My Client\",\"url\":\"https://c.example\"}"]
        `shouldBe` Right
          ( ParamsConnect
              ConnectParams
                { cpRemoteSigner = specSigner
                , cpSecret = Nothing
                , cpPerms = Nothing
                , cpMetadata =
                    Just (ClientMetadata (Just "My Client") (Just "https://c.example") Nothing)
                }
          )

    it "round-trips the connect params it decodes" $
      mapM_
        ( \params -> do
            decoded <- fromRight (decodeParams MConnect params)
            decodeParams MConnect (encodeParams decoded) `shouldBe` Right decoded
        )
        [ [specSigner]
        , [specSigner, "0s8j2djs"]
        , [specSigner, "0s8j2djs", "sign_event:4"]
        , [specSigner, "", "", "{\"name\":\"My Client\"}"]
        , [specSigner, "0s8j2djs", "sign_event:4", "{\"name\":\"My Client\"}"]
        ]

    it "drops trailing empty slots, so a lone signer is a one-element list" $
      encodeParams
        ( ParamsConnect
            ConnectParams
              { cpRemoteSigner = specSigner
              , cpSecret = Nothing
              , cpPerms = Nothing
              , cpMetadata = Nothing
              }
        )
        `shouldBe` [specSigner]

    it "keeps the permissions slot empty when metadata follows it" $
      encodeParams
        ( ParamsConnect
            ConnectParams
              { cpRemoteSigner = specSigner
              , cpSecret = Nothing
              , cpPerms = Nothing
              , cpMetadata = Just (ClientMetadata (Just "My Client") Nothing Nothing)
              }
        )
        `shouldSatisfy` \ps -> length ps == 4 && T.null (ps !! 2)

    it "omits absent client metadata fields rather than sending nulls" $
      -- A single key, so this one is compared byte for byte.
      encode (toJSON (ClientMetadata (Just "My Client") Nothing Nothing))
        `shouldBe` "{\"name\":\"My Client\"}"

    it "rejects a connect with no params at all" $
      decodeParams MConnect [] `shouldSatisfy` isLeft

    it "rejects a connect naming something that is not a pubkey" $
      decodeParams MConnect ["nope"] `shouldSatisfy` isLeft

    it "rejects connect metadata that is not an object" $
      decodeParams MConnect [specSigner, "", "", "My Client"] `shouldSatisfy` isLeft

  describe "method results" $ do
    it "decodes the connect ack" $
      decodeMethodResult MConnect "ack" `shouldBe` Right Ack

    it "decodes the secret a connect echoes back" $
      decodeMethodResult MConnect "0s8j2djs" `shouldBe` Right (ConnectToken "0s8j2djs")

    it "decodes pong, and refuses anything else for ping" $ do
      decodeMethodResult MPing "pong" `shouldBe` Right Pong
      decodeMethodResult MPing "ack" `shouldSatisfy` isLeft

    it "decodes the user pubkey, which is not the signer pubkey" $
      decodeMethodResult MGetPublicKey specSigner `shouldBe` Right (Pubkey specSigner)

    it "rejects a user pubkey that is not a pubkey" $
      decodeMethodResult MGetPublicKey "whoever" `shouldSatisfy` isLeft

    it "decodes the spec's null switch_relays answer as no change" $
      decodeMethodResult MSwitchRelays "null" `shouldBe` Right (Relays Nothing)

    it "decodes a switch_relays relay list" $
      decodeMethodResult MSwitchRelays "[\"wss://a.example\",\"wss://b.example\"]"
        `shouldBe` Right (Relays (Just ["wss://a.example", "wss://b.example"]))

    it "rejects a switch_relays result that is not a relay list" $
      decodeMethodResult MSwitchRelays "wss://a.example" `shouldSatisfy` isLeft

    it "decodes nip04 and nip44 encrypt and decrypt results" $ do
      decodeMethodResult MNip04Encrypt "cipher" `shouldBe` Right (Ciphertext "cipher")
      decodeMethodResult MNip04Decrypt "plain" `shouldBe` Right (Plaintext "plain")
      decodeMethodResult MNip44Encrypt "cipher" `shouldBe` Right (Ciphertext "cipher")
      decodeMethodResult MNip44Decrypt "plain" `shouldBe` Right (Plaintext "plain")

    it "decodes a signed event out of a sign_event result" $ do
      let signed = signEventFor userSk specSignEventParams
          result = jsonText signed
      decodeMethodResult MSignEvent result `shouldBe` Right (SignedEvent signed)

    it "rejects a sign_event result that is not an event" $
      decodeMethodResult MSignEvent "signed!" `shouldSatisfy` isLeft

    it "round-trips every result through render then decode" $
      mapM_
        ( \(m, r) -> do
            text <- fromRight (renderMethodResult m r)
            decodeMethodResult m text `shouldBe` Right r
        )
        [ (MConnect, Ack)
        , (MConnect, ConnectToken "0s8j2djs")
        , (MPing, Pong)
        , (MGetPublicKey, Pubkey specSigner)
        , (MNip04Encrypt, Ciphertext "cipher")
        , (MNip04Decrypt, Plaintext "plain")
        , (MNip44Encrypt, Ciphertext "cipher")
        , (MNip44Decrypt, Plaintext "plain")
        , (MSwitchRelays, Relays Nothing)
        , (MSwitchRelays, Relays (Just ["wss://a.example"]))
        , (MLogout, Ack)
        ]

    it "refuses to put a pong in a logout response" $
      renderMethodResult MLogout Pong `shouldSatisfy` isLeft

    it "refuses to put an ack in a ping response" $
      renderMethodResult MPing Ack `shouldSatisfy` isLeft

  describe "responses" $ do
    it "encodes the spec's plain response object" $
      encodeResponse (ConnectResponse "request-1" "ack" Nothing)
        `shouldBe` valueOf "{\"id\":\"request-1\",\"result\":\"ack\"}"

    it "encodes the spec's sign_event response object" $
      encodeResponse (ConnectResponse "request-1" specSignEventParam Nothing)
        `shouldBe` valueOf ("{\"id\":\"request-1\",\"result\":" <> jsonQuote specSignEventParam <> "}")

    it "omits an empty result rather than sending a null-ish placeholder" $
      encodeResponse (ConnectResponse "request-1" "" (Just "user refused"))
        `shouldBe` valueOf "{\"id\":\"request-1\",\"error\":\"user refused\"}"

    it "encodes the spec's auth challenge, with the url in the error field" $
      -- The spec puts the literal "auth_url" in result and the end-user URL in
      -- error. Transposed relative to what the fields mean, but that is the
      -- spec, so that is the shape.
      encodeResponse
        (ConnectResponse "request-1" "auth_url" (Just "https://signer.example.com/auth?s=abc"))
        `shouldBe` valueOf
          ( "{\"id\":\"request-1\",\"result\":\"auth_url\","
              <> "\"error\":\"https://signer.example.com/auth?s=abc\"}"
          )

    it "recovers the url from an auth challenge" $
      authChallengeUrl
        (ConnectResponse "r" "auth_url" (Just "https://signer.example.com/auth"))
        `shouldBe` Just "https://signer.example.com/auth"

    it "does not mistake a plain result for an auth challenge" $
      authChallengeUrl (ConnectResponse "r" "ack" Nothing) `shouldBe` Nothing

    it "does not treat an error without the sentinel as a challenge" $
      authChallengeUrl (ConnectResponse "r" "" (Just "some failure")) `shouldBe` Nothing

    it "prefers the error over the result, as the spec says its presence indicates failure" $
      responseResult (ConnectResponse "r" "ack" (Just "user refused"))
        `shouldBe` Left "user refused"

    it "returns the result when there is no error" $
      responseResult (ConnectResponse "r" "ack" Nothing) `shouldBe` Right "ack"

    it "round-trips every response shape through parse" $
      mapM_
        ( \r -> parseResponse (encodeResponse r) `shouldBe` Right r )
        [ ConnectResponse "r" "ack" Nothing
        , ConnectResponse "r" "" (Just "user refused")
        , ConnectResponse "r" "auth_url" (Just "https://signer.example.com/auth")
        ]

    it "defaults a missing result to empty" $
      parseResponse (valueOf "{\"id\":\"r\",\"error\":\"nope\"}")
        `shouldBe` Right (ConnectResponse "r" "" (Just "nope"))

    it "rejects a response with no id" $
      parseResponse (valueOf "{\"result\":\"ack\"}") `shouldSatisfy` isLeft

    it "answers an unknown method with an error, as the spec requires" $ do
      let payload = valueOf "{\"id\":\"request-1\",\"method\":\"sign_message\",\"params\":[]}"
      parseRequest payload `shouldSatisfy` isLeft
      let reply = rejectPayload payload "unknown NIP-46 method: sign_message"
      resId reply `shouldBe` "request-1"
      resError reply `shouldBe` Just "unknown NIP-46 method: sign_message"
      encodeResponse reply
        `shouldBe` valueOf
          "{\"id\":\"request-1\",\"error\":\"unknown NIP-46 method: sign_message\"}"

    it "answers an unreadable payload without inventing an id" $
      resId (rejectPayload (valueOf "{\"method\":42}") "unparseable") `shouldBe` ""

  describe "performing a method" $ do
    it "answers ping with pong" $
      performMethod testNonce userSk (ConnectRequest "r" MPing [])
        `shouldBe` Right Pong

    it "answers get_public_key with the user pubkey, not the client pubkey" $
      performMethod testNonce userSk (ConnectRequest "r" MGetPublicKey [])
        `shouldBe` Right (Pubkey userHex)

    it "answers connect and logout with ack" $ do
      performMethod testNonce userSk (ConnectRequest "r" MConnect [signerHex])
        `shouldBe` Right Ack
      performMethod testNonce userSk (ConnectRequest "r" MLogout []) `shouldBe` Right Ack

    it "answers switch_relays with the spec's null" $
      performMethod testNonce userSk (ConnectRequest "r" MSwitchRelays [])
        `shouldBe` Right (Relays Nothing)

    it "signs a sign_event request into a complete, verifiable NIP-01 event" $ do
      let req = ConnectRequest "r" MSignEvent [specSignEventParam]
      res <- fromRight (performMethod testNonce userSk req)
      case res of
        SignedEvent e -> do
          verifyEvent e `shouldBe` True
          evPubkey e `shouldBe` userHex
          evKind e `shouldBe` 1
          evContent e `shouldBe` "Hello, I'm signing remotely"
          evTags e `shouldBe` []
          -- 1714078911 exactly: a POSIXTime built with fromInteger would be
          -- off by a factor of 86400 here.
          floor (evCreatedAt e) `shouldBe` 1714078911
        _ -> expectationFailure "expected a signed event"

    it "signs deterministically, since BIP-340 auxiliary randomness is zero here" $ do
      let req = ConnectRequest "r" MSignEvent [specSignEventParam]
      a <- fromRight (performMethod testNonce userSk req)
      b <- fromRight (performMethod testNonce userSk req)
      a `shouldBe` b

    it "refuses a request with the wrong arity instead of answering it" $ do
      performMethod testNonce userSk (ConnectRequest "r" MPing ["stray"])
        `shouldSatisfy` isLeft
      performMethod testNonce userSk (ConnectRequest "r" MGetPublicKey ["stray"])
        `shouldSatisfy` isLeft

    it "returns a clear Left for nip04_encrypt and nip04_decrypt" $ do
      let res =
            performMethod testNonce userSk (ConnectRequest "r" MNip04Encrypt [specClient, "hi"])
      res `shouldSatisfy` isLeft
      performMethod testNonce userSk (ConnectRequest "r" MNip04Decrypt [specClient, "hi"])
        `shouldSatisfy` isLeft

    it "names the reason nip04 is unavailable, so the gap is not silent" $ do
      let res =
            performMethod testNonce userSk (ConnectRequest "r" MNip04Encrypt [specClient, "hi"])
      res `shouldBe` Left
        ( "nip04_encrypt is not implemented: NIP-04 needs AES-256-CBC with a fresh random IV,"
            <> " which is IO and lives in client/src/Krivostr/Cli/Nostr.hs"
        )

    it "answers nip44_encrypt with a payload the third party can read" $ do
      let req = ConnectRequest "r" MNip44Encrypt [thirdPartyHex, "hello third party"]
      res <- fromRight (performMethod testNonce userSk req)
      case res of
        Ciphertext c ->
          Nip44.decrypt thirdPartySk userHex c `shouldBe` Right "hello third party"
        _ -> expectationFailure "expected a ciphertext"

    it "answers nip44_decrypt by reading a payload the third party wrote" $ do
      cipher <- fromRight (Nip44.encryptWithNonce thirdPartySk userHex testNonce "hello signer")
      let req = ConnectRequest "r" MNip44Decrypt [thirdPartyHex, cipher]
      performMethod testNonce userSk req `shouldBe` Right (Plaintext "hello signer")

    it "refuses a nip44_decrypt payload addressed to someone else" $ do
      -- Written by the third party for a fourth party, so the signer reads it
      -- with the wrong conversation key.
      cipher <- fromRight (Nip44.encryptWithNonce thirdPartySk strangerHex testNonce "hello")
      performMethod testNonce userSk (ConnectRequest "r" MNip44Decrypt [thirdPartyHex, cipher])
        `shouldSatisfy` isLeft

  describe "the kind 24133 wrap" $ do
    it "is kind 24133" $
      requestEventKind `shouldBe` 24133

    it "round-trips a request through a signed kind 24133 event" $ do
      let req = ConnectRequest "request-1" MSignEvent [specSignEventParam]
      ev <- fromRight (buildRequestEvent clientSk signerHex 1714078911 testNonce req)
      evKind ev `shouldBe` requestEventKind
      openRequestEvent clientSk ev `shouldBe` Right req

    it "round-trips every method through the encrypted wrap" $
      mapM_
        ( \m -> do
            let req = ConnectRequest "r" m (encodeParams (ParamsNoArgs m))
            ev <- fromRight (buildRequestEvent clientSk signerHex 1714078911 testNonce req)
            openRequestEvent clientSk ev `shouldBe` Right req
        )
        [MPing, MGetPublicKey, MSwitchRelays, MLogout]

    it "round-trips a connect request with perms and metadata" $ do
      let params =
            [ signerHex
            , "0s8j2djs"
            , "nip44_encrypt,sign_event:4"
            , "{\"name\":\"My Client\"}"
            ]
          req = ConnectRequest "request-1" MConnect params
      ev <- fromRight (buildRequestEvent clientSk signerHex 1714078911 testNonce req)
      openRequestEvent clientSk ev `shouldBe` Right req

    it "round-trips a response through a signed kind 24133 event" $ do
      let resp = ConnectResponse "request-1" "ack" Nothing
      ev <- fromRight (buildResponseEvent signerSk clientHex 1714078912 otherNonce resp)
      evKind ev `shouldBe` requestEventKind
      openResponseEvent clientSk ev `shouldBe` Right resp

    it "round-trips a sign_event response" $ do
      let resp =
            ConnectResponse
              "request-1"
              (jsonText (signEventFor userSk specSignEventParams))
              Nothing
      ev <- fromRight (buildResponseEvent signerSk clientHex 1714078912 otherNonce resp)
      openResponseEvent clientSk ev `shouldBe` Right resp

    it "p-tags the remote signer on a request, and the client on a response" $ do
      req <- fromRight (buildRequestEvent clientSk signerHex 1 testNonce (ConnectRequest "r" MPing []))
      resp <- fromRight (buildResponseEvent signerSk clientHex 1 testNonce (ConnectResponse "r" "pong" Nothing))
      firstP req `shouldBe` Just signerHex
      firstP resp `shouldBe` Just clientHex
      evTags req `shouldBe` [["p", signerHex]]
      evTags resp `shouldBe` [["p", clientHex]]

    it "signs the wrap with the key it claims" $ do
      req <- fromRight (buildRequestEvent clientSk signerHex 1 testNonce (ConnectRequest "r" MPing []))
      resp <- fromRight (buildResponseEvent signerSk clientHex 1 testNonce (ConnectResponse "r" "pong" Nothing))
      evPubkey req `shouldBe` clientHex
      evPubkey resp `shouldBe` signerHex
      verifyEvent req `shouldBe` True
      verifyEvent resp `shouldBe` True

    it "puts a NIP-44 v2 payload in the content, not the old five-element envelope" $
      -- A NIP-44 v2 payload starts with the version byte 0x02, so its base64
      -- begins "Ag"; with 'testNonce' the first three bytes are 02 00 01, which
      -- is "AgAB". A NIP-04 payload would read "cipher?iv=..." instead, and the
      -- legacy Nostr/NIP42 array is not an event content at all.
      fromRight (buildRequestEvent clientSk signerHex 1 testNonce (ConnectRequest "r" MPing []))
        >>= \ev -> T.isPrefixOf "AgAB" (evContent ev) `shouldBe` True

    it "carries exactly the request JSON inside the payload" $ do
      let req = ConnectRequest "request-1" MSignEvent [specSignEventParam]
      ev <- fromRight (buildRequestEvent clientSk signerHex 1 testNonce req)
      plain <- fromRight (Nip44.decrypt signerSk clientHex (evContent ev))
      plain `shouldBe` bytesOf (jsonText req)

    it "keys the conversation by ECDH between the client and the signer" $ do
      a <- fromRight (conversationKey clientSk signerHex)
      b <- fromRight (conversationKey signerSk clientHex)
      a `shouldBe` b

    it "refuses a payload addressed to a different conversation" $ do
      -- Same bytes, read with an unrelated keypair: the conversation key
      -- differs, so the NIP-44 MAC must not verify.
      let req = ConnectRequest "request-1" MPing []
      ev <- fromRight (buildRequestEvent clientSk signerHex 1 testNonce req)
      openRequestEvent strangerSk ev `shouldSatisfy` isLeft

    it "refuses a request whose p tag has been repointed, even re-signed" $ do
      -- This is the load-bearing case. The p tag *is* the encryption target, so
      -- moving it moves the conversation key. The event is re-signed with the
      -- real client key to prove the signature check is not what caught it.
      let req = ConnectRequest "request-1" MPing []
      ev <- fromRight (buildRequestEvent clientSk signerHex 1 testNonce req)
      let repointed = signEvent clientSk ev {evTags = [["p", thirdPartyHex]]}
      repointed `shouldSatisfy` \e -> verifyEvent e
      openRequestEvent clientSk repointed `shouldSatisfy` isLeft

    it "refuses a response addressed to a different client" $ do
      let resp = ConnectResponse "request-1" "ack" Nothing
      ev <- fromRight (buildResponseEvent signerSk clientHex 1 testNonce resp)
      openResponseEvent strangerSk ev `shouldSatisfy` isLeft

    it "refuses an event of another kind" $ do
      let req = ConnectRequest "r" MPing []
      ev <- fromRight (buildRequestEvent clientSk signerHex 1 testNonce req)
      -- Re-signed so the signature is valid and the kind check is what fails.
      let wrongKind = signEvent clientSk ev {evKind = 1059}
      openRequestEvent clientSk wrongKind
        `shouldBe` Left "expected a kind 24133 event, got kind 1059"

    it "refuses an unsigned request event" $ do
      let req = ConnectRequest "r" MPing []
      ev <- fromRight (buildRequestEvent clientSk signerHex 1 testNonce req)
      openRequestEvent clientSk ev {evSig = ""} `shouldSatisfy` isLeft

    it "refuses a request event whose signature was tampered with" $ do
      let req = ConnectRequest "r" MPing []
      ev <- fromRight (buildRequestEvent clientSk signerHex 1 testNonce req)
      openRequestEvent clientSk ev {evSig = T.replicate 128 "a"} `shouldSatisfy` isLeft

    it "refuses a request event whose content was tampered with" $ do
      let req = ConnectRequest "r" MPing []
      ev <- fromRight (buildRequestEvent clientSk signerHex 1 testNonce req)
      let flipped = T.replace "AgAB" "AgAC" (evContent ev)
      openRequestEvent clientSk ev {evContent = flipped} `shouldSatisfy` isLeft

    it "refuses a request event with no p tag at all" $ do
      let req = ConnectRequest "r" MPing []
      ev <- fromRight (buildRequestEvent clientSk signerHex 1 testNonce req)
      let untagged = signEvent clientSk ev {evTags = [["e", signerHex]]}
      requestPeer untagged
        `shouldBe` Left "request event has no p tag naming the remote signer"
      openRequestEvent clientSk untagged `shouldSatisfy` isLeft

    it "reads the remote signer from the p tag of a request, not from its author" $ do
      let req = ConnectRequest "r" MPing []
      ev <- fromRight (buildRequestEvent clientSk signerHex 1 testNonce req)
      requestPeer ev `shouldBe` Right signerHex
      -- The author is the client, which is the wrong half to decrypt to.
      evPubkey ev `shouldSatisfy` (/= signerHex)

    it "reads the remote signer from the author of a response, not from its p tag" $ do
      let resp = ConnectResponse "r" "pong" Nothing
      ev <- fromRight (buildResponseEvent signerSk clientHex 1 testNonce resp)
      responsePeer ev `shouldBe` Right signerHex
      firstP ev `shouldBe` Just clientHex

    it "gives different conversations to different nonces" $ do
      let req = ConnectRequest "r" MPing []
      a <- fromRight (buildRequestEvent clientSk signerHex 1 testNonce req)
      b <- fromRight (buildRequestEvent clientSk signerHex 1 otherNonce req)
      evContent a `shouldNotBe` evContent b
      openRequestEvent clientSk a `shouldBe` Right req
      openRequestEvent clientSk b `shouldBe` Right req

    it "ignores p tags that are not first, and extra p tags" $ do
      let ev =
            Event
              { evId = "i"
              , evPubkey = clientHex
              , evCreatedAt = 0
              , evKind = requestEventKind
              , evTags = [["e", "x"], ["p", signerHex], ["p", thirdPartyHex], ["p"]]
              , evContent = "c"
              , evSig = "s"
              }
      firstP ev `shouldBe` Just signerHex

    it "reports no p tag when there is none to read" $ do
      let ev =
            Event
              { evId = "i"
              , evPubkey = clientHex
              , evCreatedAt = 0
              , evKind = requestEventKind
              , evTags = [["e", "x"], ["p"], []]
              , evContent = "c"
              , evSig = "s"
              }
      firstP ev `shouldBe` Nothing

  describe "the spec example flow" $ do
    -- The spec names three pubkeys for its signing example but no secrets, so
    -- the pubkeys here are the spec own and the keys are ours: the point is the
    -- protocol shape, not a reproduction of the spec ciphertext.

    it "wraps the spec's signature request with the spec p tag" $ do
      let req = ConnectRequest "any-id" MSignEvent [specSignEventParam]
      ev <- fromRight (buildRequestEvent clientSk specSigner 1714078911 testNonce req)
      evKind ev `shouldBe` requestEventKind
      evPubkey ev `shouldBe` clientHex
      evTags ev `shouldBe` [["p", specSigner]]
      T.isPrefixOf "AgAB" (evContent ev) `shouldBe` True

    -- The spec publishes no secrets for its example keys, so the response side
    -- of this flow has to use our own signer key and address our own client
    -- key: an event sealed to 'specClient' could not be opened by anyone here.
    -- What still matches the spec is the shape, the author being the signer
    -- rather than the client, and the p tag naming the client.
    it "answers it with a signed event the signer authors" $ do
      let signed = signEventFor signerSk specSignEventParams
          resp = ConnectResponse "any-id" (jsonText signed) Nothing
      ev <- fromRight (buildResponseEvent signerSk clientHex 1714078912 otherNonce resp)
      evKind ev `shouldBe` requestEventKind
      evPubkey ev `shouldBe` signerHex
      evTags ev `shouldBe` [["p", clientHex]]
      verifyEvent ev `shouldBe` True
      -- This one is sealed with 'otherNonce', whose first bytes are 1f 1e, so
      -- the payload starts 02 1f 1e -- base64 "Ah8e" -- not the "AgAB" a
      -- zero-leading nonce gives.
      T.isPrefixOf "Ah8e" (evContent ev) `shouldBe` True

    it "decodes the answer back into the spec's signed event" $ do
      let signed = signEventFor signerSk specSignEventParams
          resp = ConnectResponse "any-id" (jsonText signed) Nothing
      ev <- fromRight (buildResponseEvent signerSk clientHex 1714078912 otherNonce resp)
      openResponseEvent clientSk ev `shouldBe` Right resp

  describe "determinism" $
    it "produces the same event bytes for the same keys, nonce and request" $ do
      let req = ConnectRequest "request-1" MSignEvent [specSignEventParam]
      a <- fromRight (buildRequestEvent clientSk signerHex 1714078911 testNonce req)
      b <- fromRight (buildRequestEvent clientSk signerHex 1714078911 testNonce req)
      a `shouldBe` b

  describe "the expected-value helper" $ do
    it "reads the spec literals this file compares against" $
      mapM_
        ( \t ->
            (eitherDecodeStrict (bytesOf t) :: Either String Value)
              `shouldSatisfy` isRight
        )
        [ specSignEventRequest
        , "{\"id\":\"a\",\"method\":\"ping\",\"params\":[]}"
        , "{\"id\":\"request-1\",\"result\":\"ack\"}"
        , "{\"id\":\"request-1\",\"result\":\"auth_url\",\"error\":\"https://signer.example.com/auth?s=abc\"}"
        , "{\"id\":\"request-1\",\"error\":\"user refused\"}"
        ]

    it "does not read a malformed literal" $
      (eitherDecodeStrict (bytesOf "{not json}") :: Either String Value)
        `shouldSatisfy` isLeft