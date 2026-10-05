{-# LANGUAGE OverloadedStrings #-}

-- | NIP-59 gift wrap: rumor, seal and gift wrap.
--
-- Three layers, each with a different job, and the privacy of the scheme comes
-- from keeping those jobs separate:
--
-- * a @rumor@ is an unsigned event. It carries the content but no signature, so
--   if it leaks it is rejected by relays and clients and cannot be authenticated.
-- * a @seal@ (@kind 13@) is signed by the note's real author and encrypts the
--   rumor to one recipient. It has no @p@ tag, so nothing public says who the
--   rumor is for.
-- * a @gift wrap@ (@kind 1059@) is signed by a random one-time key and encrypts
--   the seal. Its @p@ tag is the only routing information on the wire.
--
-- A relay sees only the gift wrap. It learns the recipient and nothing else: not
-- the author, not the content, not the kind of the inner event.
--
-- ## Serialization
--
-- The rumor is serialized /without/ a @sig@ field. That is not a shortcut: the
-- spec's own example rumor has no @sig@ key, and the seal's ciphertext is a
-- function of those exact bytes, so an implementation that emits @\"sig\":\"\"@
-- produces a different payload that no other client can open. 'Rumor' therefore
-- has its own 'ToJSON' rather than reusing 'Event''s.
--
-- ## Purity
--
-- Ephemeral keys, the per-layer timestamps and every NIP-44 nonce are
-- parameters. Nothing here reads the clock or the CSPRNG, which is what makes
-- the published vectors reproducible and the round-trip tests deterministic.
module Krivostr.Nip.Nip59
  ( -- * Kinds
    sealKind
  , wrapKind
  , ephemeralWrapKind
    -- * Rumor
  , Rumor(..)
  , createRumor
  , rumorBytes
  , rumorFromJSON
    -- * Seal
  , seal
  , unseal
    -- * Gift wrap
  , wrap
  , wrapEphemeral
  , unwrap
    -- * Inspection
  , isSeal
  , isWrap
  , isEphemeralWrap
  , wrapRecipient
  ) where

import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime)
import Krivostr.Event
import Krivostr.Key
import Krivostr.Nip.Nip01
import Krivostr.Nip.Nip44

-- | @kind 13@. Tags MUST be empty and the inner event MUST be unsigned.
sealKind :: Int
sealKind = 13

-- | @kind 1059@. The persistent gift wrap, used for asynchronous DMs.
wrapKind :: Int
wrapKind = 1059

-- | @kind 21059@. Same shape as 'wrapKind' but ephemeral: relays MUST NOT store
-- it, which suits live chat where only currently-connected recipients matter.
ephemeralWrapKind :: Int
ephemeralWrapKind = 21059

-- | An unsigned event with an id. The id is computed and the signature is not,
-- which is what gives the scheme its deniability: a leaked rumor cannot be
-- authenticated, so it cannot be attributed.
data Rumor = Rumor
  { rumorId :: !Text
  , rumorPubkey :: !Text
  , rumorCreatedAt :: !POSIXTime
  , rumorKind :: !Int
  , rumorTags :: ![[Text]]
  , rumorContent :: !Text
  } deriving (Show, Eq)

-- | A rumor serializes without a @sig@ field.
--
-- This is the one place the module deliberately does not reuse 'Event''s
-- 'ToJSON'. The seal's ciphertext is a function of these bytes, so the field
-- set is part of the wire format rather than an implementation detail.
instance ToJSON Rumor where
  toJSON r = object
    [ "id" .= rumorId r
    , "pubkey" .= rumorPubkey r
    , "created_at" .= rumorCreatedAt r
    , "kind" .= rumorKind r
    , "tags" .= rumorTags r
    , "content" .= rumorContent r
    ]

instance FromJSON Rumor where
  parseJSON = withObject "Rumor" $ \o -> Rumor
    <$> o .: "id"
    <*> o .: "pubkey"
    <*> o .: "created_at"
    <*> o .: "kind"
    <*> o .: "tags"
    <*> o .: "content"

-- | Build a rumor from an unsigned event and its author's key.
--
-- The pubkey is filled in and the id computed, exactly as 'signEvent' would do,
-- but the signature is left blank. The id is part of the rumor -- NIP-17 relies
-- on it to link replies -- while the signature is what a rumor must not have.
createRumor :: PrivateKey -> UnsignedEvent -> Rumor
createRumor sk u =
  let e = mkEvent u {uePubkey = pub}
   in Rumor
        { rumorId = computeEventId e
        , rumorPubkey = pub
        , rumorCreatedAt = ueCreatedAt u
        , rumorKind = ueKind u
        , rumorTags = ueTags u
        , rumorContent = ueContent u
        }
  where
    pub = pubKeyHex (derivePublicKey sk)

-- | The exact bytes a seal or wrap encrypts.
rumorBytes :: Rumor -> BS.ByteString
rumorBytes = BL.toStrict . encode

-- | Parse a rumor out of decrypted bytes.
rumorFromJSON :: BS.ByteString -> Either String Rumor
rumorFromJSON bs = case eitherDecodeStrict bs of
  Left err -> Left ("decrypted rumor is not valid JSON: " ++ err)
  Right r -> Right r

-- | The JSON form of any signed event, which is what a gift wrap encrypts.
eventBytes :: Event -> BS.ByteString
eventBytes = BL.toStrict . encode

-- | Seal a rumor to one recipient.
--
-- The seal is signed by the note's real author, so the author is public, but it
-- carries no @p@ tag and its content is encrypted, so neither the recipient nor
-- the message is.
--
-- @sealCreated@ should be a timestamp independent of the rumor's: the spec
-- recommends randomizing every layer to thwart time-analysis attacks, and
-- reusing the rumor's timestamp would correlate the two.
seal
  :: PrivateKey
  -> Text
  -> POSIXTime
  -> BS.ByteString
  -> Rumor
  -> Either String Event
seal sk recipientHex sealCreated nonce rumor = do
  payload <- encryptWithNonce sk recipientHex nonce (rumorBytes rumor)
  let unsigned =
        UnsignedEvent
          { uePubkey = pubKeyHex (derivePublicKey sk)
          , ueCreatedAt = sealCreated
          , ueKind = sealKind
          , ueTags = []
          , ueContent = payload
          }
  pure (signEvent sk (mkEvent unsigned))

-- | Open a seal, recovering the rumor.
--
-- The signature is verified before the content is decrypted, so a forged seal
-- cannot be used to make us derive key material for an attacker-chosen pubkey.
-- The seal's tags are required to be empty and its pubkey is required to match
-- the rumor's: NIP-17 makes that check mandatory, because without it anyone can
-- impersonate anyone by rewriting the rumor's pubkey.
unseal :: PrivateKey -> Event -> Either String Rumor
unseal sk e
  | evKind e /= sealKind = Left "event is not a kind 13 seal"
  | not (verifyEvent e) = Left "seal signature is invalid"
  | not (null (evTags e)) = Left "a seal must have empty tags"
  | otherwise = do
      bytes <- decrypt sk (evPubkey e) (evContent e)
      r <- rumorFromJSON bytes
      if rumorPubkey r == evPubkey e
        then Right r
        else Left "seal pubkey does not match the rumor's author"

-- | Wrap a seal (or any event) for one recipient, signed by a one-time key.
--
-- The @p@ tag is the only routing information on the wire, and it is what a
-- relay uses to decide who may read the event.
wrap
  :: PrivateKey
  -> Text
  -> POSIXTime
  -> BS.ByteString
  -> Event
  -> Either String Event
wrap = wrapWith wrapKind

-- | 'wrap' at 'ephemeralWrapKind', for real-time use where the relay should not
-- store the event.
wrapEphemeral
  :: PrivateKey
  -> Text
  -> POSIXTime
  -> BS.ByteString
  -> Event
  -> Either String Event
wrapEphemeral = wrapWith ephemeralWrapKind

wrapWith
  :: Int
  -> PrivateKey
  -> Text
  -> POSIXTime
  -> BS.ByteString
  -> Event
  -> Either String Event
wrapWith kind sk recipientHex wrapCreated nonce inner = do
  payload <- encryptWithNonce sk recipientHex nonce (eventBytes inner)
  let unsigned =
        UnsignedEvent
          { uePubkey = pubKeyHex (derivePublicKey sk)
          , ueCreatedAt = wrapCreated
          , ueKind = kind
          , ueTags = [["p", recipientHex]]
          , ueContent = payload
          }
  pure (signEvent sk (mkEvent unsigned))

-- | Open a gift wrap, recovering the sealed event inside.
--
-- Only the signature is checked here. Confirming that the wrap was actually
-- addressed to the key that opened it is the caller's job, because that check
-- needs the recipient's identity rather than just the key: see 'wrapRecipient'.
unwrap :: PrivateKey -> Event -> Either String Event
unwrap sk e
  | evKind e /= wrapKind && evKind e /= ephemeralWrapKind =
      Left "event is not a gift wrap"
  | not (verifyEvent e) = Left "gift wrap signature is invalid"
  | otherwise = do
      bytes <- decrypt sk (evPubkey e) (evContent e)
      case eitherDecodeStrict bytes of
        Left err -> Left ("gift wrap content is not a valid event: " ++ err)
        Right inner -> Right inner

isSeal :: Event -> Bool
isSeal e = evKind e == sealKind

isWrap :: Event -> Bool
isWrap e = evKind e == wrapKind

isEphemeralWrap :: Event -> Bool
isEphemeralWrap e = evKind e == ephemeralWrapKind

-- | The @p@tagged recipient of a gift wrap, if it has exactly one.
--
-- A wrap with no @p@ tag is unroutable, and one with several is ambiguous
-- rather than merely unusual, so both are 'Nothing' and the caller decides.
wrapRecipient :: Event -> Maybe Text
wrapRecipient e =
  case [v | ("p" : v : _) <- evTags e, not (T.null v)] of
    [r] -> Just r
    _   -> Nothing
