{-# LANGUAGE OverloadedStrings #-}

-- | NIP-18 reposts and quotes.
--
-- Two shapes, and confusing them breaks the reader:
--
-- * A *repost* (kind 6) embeds the original event as JSON in its content and
--   @e@-tags its id. Relays and clients render the original; the repost
--   itself carries no text of its own.
-- * A *quote* (kind 1) is an ordinary note whose content adds commentary and
--   whose @q@ tag cites the quoted event. The @q@ tag -- not @e@ -- is what
--   keeps the quote out of the original's reply thread: an @e@ tag would make
--   every quoter look like a replier.
--
-- Kind 16 (generic repost) wraps any other kind the same way a kind 6 wraps
-- a kind 1. The @k@ tag on it records the reposted kind so a reader need not
-- parse the embedded JSON to decide whether it can render the event.
module Krivostr.Nip.Nip18
  ( repostKind
  , genericRepostKind
  , Repost(..)
  , repostOf
  , isRepost
  , Quote(..)
  , quoteOf
  , isQuote
  , buildRepostTags
  , buildQuoteTags
  , embedOriginal
  , embeddedOriginal
  ) where

import Data.Aeson (encode, eitherDecodeStrict)
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Krivostr.Event

-- | Kind 6: repost of a kind 1 note.
repostKind :: Int
repostKind = 6

-- | Kind 16: generic repost of any other kind.
genericRepostKind :: Int
genericRepostKind = 16

-- | A parsed repost: the original's id, author, and kind.
data Repost = Repost
  { rpEventId :: !Text
  , rpAuthor  :: !Text
  , rpKind    :: !(Maybe Int)
  } deriving (Show, Eq)

-- | Parse a kind 6 or kind 16 event. Any other kind is not a repost, and a
-- repost kind without an @e@ tag cites nothing.
repostOf :: Event -> Maybe Repost
repostOf e
  | evKind e /= repostKind && evKind e /= genericRepostKind = Nothing
  | otherwise = case [rest | ("e" : rest) <- evTags e] of
      ((eid : _) : _) -> Just Repost
        { rpEventId = eid
        , rpAuthor  = authorOf e
        , rpKind    = kindOf e
        }
      _ -> Nothing
  where
    authorOf ev = case [v | ("p" : v : _) <- evTags ev] of
      (v : _) -> v
      _       -> ""

    kindOf ev = case [v | ("k" : v : _) <- evTags ev] of
      (v : _) -> case reads (T.unpack v) of
        [(n, "")] -> Just n
        _         -> Nothing
      _ -> if evKind ev == repostKind then Just 1 else Nothing

-- | Is the event a well-formed repost?
isRepost :: Event -> Bool
isRepost e = case repostOf e of
  Nothing -> False
  Just _  -> True

-- | A parsed quote: the cited event's id and relay hint.
data Quote = Quote
  { quEventId :: !Text
  , quRelay   :: !Text
  } deriving (Show, Eq)

-- | Parse the @q@ tag of a kind 1 note. A quote is a kind 1 *with* a @q@
-- tag; the same tag on any other kind is ignored, because only notes carry
-- commentary that quotes.
quoteOf :: Event -> Maybe Quote
quoteOf e
  | evKind e /= 1 = Nothing
  | otherwise = case [rest | ("q" : rest) <- evTags e] of
      ((eid : rest) : _) -> Just Quote { quEventId = eid, quRelay = relayHint rest }
      _ -> Nothing
  where
    relayHint (r : _) = r
    relayHint []      = ""

-- | Is the event a quote?
isQuote :: Event -> Bool
isQuote e = case quoteOf e of
  Nothing -> False
  Just _  -> True

-- | The tags for reposting an event: @e@ for the original, @p@ for its
-- author. The kind needs no tag on a kind 6 (it is always a kind 1 inside);
-- a generic repost adds @k@ so the reader knows what it embeds.
buildRepostTags :: Text -> Text -> Text -> Int -> [[Text]]
buildRepostTags eventId relayHint author originalKind
  | originalKind == 1 =
      [ ["e", eventId, relayHint]
      , ["p", author]
      ]
  | otherwise =
      [ ["e", eventId, relayHint]
      , ["p", author]
      , ["k", T.pack (show originalKind)]
      ]

-- | The tags for quoting an event: a single @q@ tag. Deliberately not @e@,
-- so the quote never joins the original's reply thread.
buildQuoteTags :: Text -> Text -> [[Text]]
buildQuoteTags eventId relayHint = [["q", eventId, relayHint]]

-- | The repost content: the original event as JSON text.
embedOriginal :: Event -> Text
embedOriginal = TE.decodeUtf8 . BL.toStrict . encode

-- | Read the embedded original back out of a repost's content.
embeddedOriginal :: Text -> Maybe Event
embeddedOriginal t = case eitherDecodeStrict (TE.encodeUtf8 t) of
  Right e -> Just e
  Left _  -> Nothing
