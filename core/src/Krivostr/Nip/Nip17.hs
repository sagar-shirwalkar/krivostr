{-# LANGUAGE OverloadedStrings #-}

-- | NIP-17 private direct messages.
--
-- NIP-17 is a messaging protocol built on the NIP-59 primitives, so this module
-- is mostly composition: build a @kind 14@ rumor, seal it, then gift-wrap it to
-- every participant. The parts that are NIP-17's own are the ones that make the
-- scheme private rather than merely encrypted:
--
-- * The rumor's @p@ tags define the room. Adding or removing one starts a new
--   room with a clean history, so the tag set is the room identity and there is
--   no public group identifier to correlate.
-- * Every layer's @created_at@ is randomized up to two days into the past.
--   Grouping messages by timestamp is otherwise a cheap way to link them, and
--   the spec is explicit that both the seal and the wrap should be jittered.
-- * The sender gets their own gift wrap. Without it the sender has no copy of
--   the conversation, and "fully recoverable" -- one of the NIP's stated
--   benefits -- would not hold.
--
-- ## What is deliberately not here
--
-- NIP-17 says the rumor's @content@ MUST be plain text. Enforcing that is a
-- client decision, not a protocol one: the seal encrypts whatever bytes it is
-- given, and a client that puts a URL there is not breaking the wire format.
-- 'createChatRumor' takes the content as given.
module Krivostr.Nip.Nip17
  ( -- * Kinds
    chatKind
  , fileMessageKind
  , dmRelayListKind
    -- * Timestamps
  , twoDaysSeconds
  , pastTimestamp
    -- * Rumors
  , createChatRumor
  , createFileRumor
  , chatReceivers
  , chatSubject
    -- * Sending
  , DmLayers(..)
  , sealAndWrap
  , dmRelayListTags
  ) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime)
import Krivostr.Event
import Krivostr.Key
import Krivostr.Nip.Nip59

-- | @kind 14@, a chat message. @content@ is plain text.
chatKind :: Int
chatKind = 14

-- | @kind 15@, an encrypted file message.
fileMessageKind :: Int
fileMessageKind = 15

-- | @kind 10050@, the user's preferred relays for receiving DMs.
dmRelayListKind :: Int
dmRelayListKind = 10050

-- | The jitter window, in seconds.
twoDaysSeconds :: Int
twoDaysSeconds = 2 * 24 * 60 * 60

-- | Shift a timestamp backwards by a caller-supplied offset.
--
-- The offset is a parameter rather than a draw from the CSPRNG so the module
-- stays pure and a test can check the whole window. It is clamped to
-- @[0, 'twoDaysSeconds']@: the spec says "up to two days in the past", and a
-- negative offset would put the event in the future, which some relays refuse to
-- serve -- the spec warns about exactly that.
pastTimestamp :: POSIXTime -> Int -> POSIXTime
pastTimestamp now offset
  | offset < 0 = now
  | offset > twoDaysSeconds = now - fromIntegral twoDaysSeconds
  | otherwise = now - fromIntegral offset

-- | Build a @kind 14@ chat rumor.
--
-- The @p@ tags are the room. A @subject@ tag is optional and only the newest
-- one in a room is the topic, so it is passed through as an ordinary tag rather
-- than given special treatment here.
--
-- The content is plain text and is /not/ encrypted at this layer: the seal
-- encrypts the whole rumor, which is what makes the message private. Passing
-- something other than plain text does not break the wire format, but it does
-- break the NIP-17 contract, so the caller is trusted to follow it.
createChatRumor
  :: PrivateKey
  -> POSIXTime
  -> [Text]
  -> Text
  -> Text
  -> Rumor
createChatRumor sk now receivers subject content =
  createRumor
    sk
    UnsignedEvent
      { uePubkey = ""
      , ueCreatedAt = now
      , ueKind = chatKind
      , ueTags = pTags ++ [["subject", subject] | not (T.null subject)]
      , ueContent = content
      }
  where
    pTags = [["p", r] | r <- receivers, not (T.null r)]

-- | Build a @kind 15@ file message rumor.
--
-- The file itself is encrypted by the caller and described by the tags the spec
-- lists (@file-type@, @encryption-algorithm@, @decryption-key@,
-- @decryption-nonce@, @x@, @ox@, @size@, @dim@, @thumbhash@, @blurhash@,
-- @thumb@, @fallback@). Only the tags that carry no caller data are filled in
-- here; the rest are appended by the caller.
createFileRumor
  :: PrivateKey
  -> POSIXTime
  -> [Text]
  -> Text
  -> Text
  -> [[Text]]
  -> Rumor
createFileRumor sk now receivers fileType content extraTags =
  createRumor
    sk
    UnsignedEvent
      { uePubkey = ""
      , ueCreatedAt = now
      , ueKind = fileMessageKind
      , ueTags =
          [["p", r] | r <- receivers, not (T.null r)]
            ++ [["file-type", fileType] | not (T.null fileType)]
            ++ extraTags
      , ueContent = content
      }

-- | The receivers of a chat rumor: its @p@ tags, in order.
chatReceivers :: Rumor -> [Text]
chatReceivers r = [v | ("p" : v : _) <- rumorTags r, not (T.null v)]

-- | The rumor's @subject@ tag, if any.
chatSubject :: Rumor -> Maybe Text
chatSubject r =
  case [v | ("subject" : v : _) <- rumorTags r, not (T.null v)] of
    (s : _) -> Just s
    _       -> Nothing

-- | The two layers of a sent message, kept together so a caller cannot
-- accidentally publish the seal or lose the wrap.
data DmLayers = DmLayers
  { dmSeal :: !Event
  , dmWrap :: !Event
  } deriving (Show, Eq)

-- | Seal a rumor for one recipient and gift-wrap the seal to them.
--
-- The wrap is signed by @wrapperKey@, which must be a fresh one-time key
-- unrelated to the author's. That is the whole point of the outer layer: the
-- wrap is what a relay sees, and if it were signed by the author's key the
-- relay could link every message in a conversation to one identity. The spec's
-- @createWrap@ generates a new key for exactly this reason.
--
-- The two timestamps and two nonces are independent parameters, because reusing
-- either across layers is exactly the correlation the spec warns about: the
-- seal's @created_at@ should not match the wrap's, and a NIP-44 nonce must never
-- be reused with the same conversation key.
sealAndWrap
  :: PrivateKey
  -> PrivateKey
  -> Text
  -> POSIXTime
  -> BS.ByteString
  -> POSIXTime
  -> BS.ByteString
  -> Rumor
  -> Either String DmLayers
sealAndWrap authorKey wrapperKey recipient sealCreated sealNonce wrapCreated wrapNonce rumor = do
  s <- seal authorKey recipient sealCreated sealNonce rumor
  w <- wrap wrapperKey recipient wrapCreated wrapNonce s
  pure (DmLayers s w)

-- | The @relay@ tags for a @kind 10050@ DM relay list.
--
-- Clients MUST only publish DMs to the relays in the recipient's list, so this
-- is the routing half of the protocol: the wrap says who, this says where.
dmRelayListTags :: [Text] -> [[Text]]
dmRelayListTags = map (\r -> ["r", r]) . filter (not . T.null)