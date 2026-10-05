{-# LANGUAGE OverloadedStrings #-}

-- | NIP-40 expiration timestamps.
--
-- The tag is trivial; the decisions around it are not. Two of them are encoded
-- here because getting them wrong is a correctness bug rather than a policy
-- choice:
--
-- * Expiration is part of the event, so it is covered by the event id and the
--   signature. Rewriting the tag changes the id and invalidates both, which is
--   why 'buildExpirationTags' only ever adds to an unsigned event.
--
-- * The comparison is @expiration <= now@, not @expiration < now@. An event
--   whose expiration is exactly the current second is already gone, and
--   @<@ would serve it for one more second on every clock tick.
--
-- The spec is explicit that expiration is not a confidentiality control: the
-- event is public until the relay drops it. Nothing here changes that.
module Krivostr.Nip.Nip40
  ( expirationTag
  , buildExpirationTags
  , expirationOf
  , parseExpirationTag
  , isExpiredAt
  , keepUnexpired
  , dropExpired
  , filterExpired
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime)
import Krivostr.Event

-- | The @expiration@ tag for a unix timestamp in seconds.
--
-- Seconds, not milliseconds: it has the same base as @created_at@, and a
-- millisecond value would be a timestamp far in the future.
expirationTag :: POSIXTime -> [Text]
expirationTag at = ["expiration", T.pack (show (floor at :: Integer))]

-- | Add an @expiration@ tag, replacing any existing one.
--
-- Only one expiration may apply, so an existing tag is overwritten rather than
-- shadowed.
buildExpirationTags :: POSIXTime -> [[Text]] -> [[Text]]
buildExpirationTags at tags =
  expirationTag at : filter (not . isExpiration) tags
  where
    isExpiration ("expiration" : _) = True
    isExpiration _                   = False

-- | The expiration timestamp of an event, if it has a valid one.
--
-- A malformed tag yields 'Nothing' rather than a guess. Treating an
-- unparseable timestamp as "expires at the epoch" would silently delete the
-- note on the first read; treating it as "never expires" lets a spammer strip
-- the tag's meaning, so callers should check 'isExpired' and decide what an
-- absent value means for them.
expirationOf :: Event -> Maybe POSIXTime
expirationOf e = expirationTagOf e >>= parseExpirationTag

expirationTagOf :: Event -> Maybe [Text]
expirationTagOf e =
  case [rest | ("expiration" : rest) <- evTags e] of
    (rest : _) -> Just rest
    _          -> Nothing

-- | The unix timestamp in an @expiration@ tag. Rejects the empty string, a
-- sign, and trailing junk.
parseExpirationTag :: [Text] -> Maybe POSIXTime
parseExpirationTag (value : _)
  | T.null value = Nothing
  | T.any (\c -> c < '0' || c > '9') value = Nothing
  | otherwise = case reads (T.unpack value) of
      [(n, "")] -> Just (fromInteger n)
      _         -> Nothing
parseExpirationTag [] = Nothing

-- | Is the event expired at a given instant? An event with no expiration tag
-- never expires, since relays may persist those indefinitely.
--
-- There is no argument-free variant: reading the clock is IO and this module is
-- pure, so the caller passes the instant. The relay path should read it once
-- per batch rather than per event.
isExpiredAt :: POSIXTime -> Event -> Bool
isExpiredAt now e = maybe False (<= now) (expirationOf e)

-- | Keep the events that have not expired.
keepUnexpired :: POSIXTime -> [Event] -> [Event]
keepUnexpired now = filter (not . isExpiredAt now)

-- | Keep the events that have expired, which is what a purge wants.
dropExpired :: POSIXTime -> [Event] -> [Event]
dropExpired now = filter (isExpiredAt now)

-- | Split events into unexpired and expired, for reporting after a purge.
filterExpired :: POSIXTime -> [Event] -> ([Event], [Event])
filterExpired now es = (keepUnexpired now es, dropExpired now es)
