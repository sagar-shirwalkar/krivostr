{-# LANGUAGE OverloadedStrings #-}

-- | NIP-42: Authentication of clients to relays.
--
-- Relay sends @["AUTH", <challenge>]@; client replies with @["AUTH", <signed event>]@
-- where the event has kind 22242, created_at is current time, and tags
-- @["relay", <relay url>]@ and @["challenge", <challenge>]@, signed with the
-- client's key. On success relay sends @["OK", <challenge>, true, ""]@; on failure
-- @["CLOSED", <challenge>, "auth-required: <reason>"]@.
--
-- The event is ephemeral and not stored. Relays must verify:
-- * kind is 22242
-- * created_at is close to current time (within a short window)
-- * relay tag matches the relay URL
-- * challenge tag matches the challenge issued
-- * the signature is valid
module Krivostr.Nip.Nip42
  ( buildAuthEvent
  , authEventRelay
  , authEventChallenge
  , validateAuthEvent
  , authRequiredNotice
  , restrictedNotice
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime)
import Krivostr.Event
import Krivostr.Key
import Krivostr.Nip.Nip01

-- | Build an authentication event (kind 22242) signed by the client's private key.
--
-- Reading the clock is IO, so the timestamp must be passed as a parameter.
-- This builds an 'UnsignedEvent' with kind 22242 and tags [["relay", relayUrl],
-- ["challenge", challenge]], then signs it.
buildAuthEvent :: PrivateKey -> Text -> Text -> POSIXTime -> Event
buildAuthEvent sk relayUrl challenge createdAt =
  let ue = UnsignedEvent
            { uePubkey    = ""
            , ueCreatedAt = createdAt
            , ueKind      = 22242
            , ueTags      = [ ["relay", relayUrl], ["challenge", challenge] ]
            , ueContent   = ""
            }
      e0 = mkEvent ue
  in signEvent sk e0

-- | Extract the relay URL from the AUTH event's "relay" tag.
--
-- Rejects if the relay tag is missing, malformed (wrong arity, wrong tag name),
-- or empty. Returns 'Left' with a descriptive message on failure.
authEventRelay :: Event -> Either String Text
authEventRelay e =
  case findRelayTag (evTags e) of
    Nothing -> Left "missing relay tag"
    Just url
      | T.null url -> Left "empty relay tag"
      | otherwise  -> Right url
  where
    findRelayTag [] = Nothing
    findRelayTag (t:ts) = case t of
      ("relay":url:_) -> Just url
      _               -> findRelayTag ts

-- | Extract the challenge from the AUTH event's "challenge" tag.
--
-- Rejects if the challenge tag is missing, malformed, or empty.
authEventChallenge :: Event -> Either String Text
authEventChallenge e =
  case findChallengeTag (evTags e) of
    Nothing -> Left "missing challenge tag"
    Just chal
      | T.null chal -> Left "empty challenge tag"
      | otherwise   -> Right chal
  where
    findChallengeTag [] = Nothing
    findChallengeTag (t:ts) = case t of
      ("challenge":chal:_) -> Just chal
      _                    -> findChallengeTag ts

-- | Validate an AUTH event against expected values.
--
-- Checks performed (each with rationale):
-- * Kind must be 22242 (NIP-42 canonical auth event)
-- * Event id and signature must be valid (verifyEvent) - ensures authenticity
-- * Relay tag must equal expected relay - prevents relay impersonation/phishing
-- * Challenge tag must equal expected challenge - prevents replay from old challenges
-- * created_at must be within maxAgeSeconds AND not in the future beyond small skew
--   (spec says "close to current time, e.g. within ~10 minutes"; also rejects
--   future-dated events to prevent certain attacks)
--
-- Returns 'Right ()' if all checks pass, 'Left' with reason if any fails.
validateAuthEvent
  :: Text           -- ^ expected relay URL
  -> Text           -- ^ expected challenge
  -> POSIXTime      -- ^ current time (now)
  -> Int            -- ^ maximum age in seconds
  -> Event          -- ^ the AUTH event to validate
  -> Either String ()
validateAuthEvent expectedRelay expectedChallenge now maxAge e = do
  -- Kind check: canonical auth event is kind 22242
  if evKind e /= 22242
    then Left "wrong kind (must be 22242)"
    else do
      -- Extract and validate tags first (for clearer error messages)
      relay <- authEventRelay e
      chal <- authEventChallenge e
      -- Relay tag must match expected relay
      if relay /= expectedRelay
        then Left "relay tag mismatch"
        else do
          -- Challenge tag must match the challenge issued by relay
          if chal /= expectedChallenge
            then Left "challenge mismatch"
            else do
              -- Check time constraints
              case checkTime of
                Left err -> Left err
                Right () -> if not (verifyEvent e)
                             then Left "bad signature or invalid id"
                             else Right ()
  where
    age = now - evCreatedAt e
    futureSkew :: Int
    futureSkew = 30 -- seconds - small skew for clock differences
    checkTime
      -- Reject future-dated events (created_at in future beyond skew)
      | evCreatedAt e > now + fromIntegral futureSkew =
          Left "event created in the future"
      -- Reject expired events (older than maxAge)
      | age > fromIntegral maxAge =
          Left "event too old"
      | otherwise = Right ()

-- | Helper for "auth-required" notice prefix as defined in NIP-42.
authRequiredNotice :: Text -> Text
authRequiredNotice reason = T.concat ["auth-required: ", reason]

-- | Helper for "restricted" notice prefix as defined in NIP-42.
restrictedNotice :: Text -> Text
restrictedNotice reason = T.concat ["restricted: ", reason]
