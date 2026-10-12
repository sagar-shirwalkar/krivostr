{-# LANGUAGE OverloadedStrings #-}

-- | Option parsing shared by both shells: the one-shot CLI parses argv into
-- these, the TUI's dispatcher parses ':' lines into the same. Moved here
-- from Krivostr.Cli so Krivostr.Tui.Dispatch can reuse them without
-- importing the whole command surface (which would cycle back through the
-- TUI). Pure except 'buildFilter'/'resolveTime', which read the clock.
module Krivostr.Cli.Options
  ( TimeSpec (..)
  , resolveTime
  , parseWhen
  , FilterOpts (..)
  , emptyFilterOpts
  , groupTags
  , parseKind
  , parseTag
  , resolveAuthor
  , resolveRecipient
  , parseLevel
  , buildFilter
  , resolveUpstreams
  , csvField
  , renderCsv
  , tagCell
  , substitute
  ) where

import qualified Data.Aeson as Aeson (encode)
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime, utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Krivostr.Cli.Nostr (defaultRelays, isHex64)
import Krivostr.Event
import Krivostr.Filter (Filter (..))
import Krivostr.Key
import Krivostr.Logging (LogLevel (..))

-- | An absolute instant, or an age relative to now.
--
-- Kept symbolic until dispatch, so @--since 2h@ means "two hours before this
-- command ran" rather than two hours after the epoch.
data TimeSpec
  = At POSIXTime
  | Ago Integer          -- ^ seconds in the past
  deriving (Show, Eq)

resolveTime :: TimeSpec -> IO POSIXTime
resolveTime (At t)  = pure t
resolveTime (Ago n) = fmap (subtract (fromIntegral n)) getPOSIXTime

-- | @2026-01-01@, a unix timestamp, or a relative age: @90s@, @15m@, @2h@,
-- @7d@, @3w@, @6mo@, @1y@.
parseWhen :: String -> Either String TimeSpec
parseWhen s
  | not (null s), all isDigit s = Right (At (fromIntegral (read s :: Integer)))
  | otherwise =
      case (span isDigit s, reads (fst (span isDigit s)) :: [(Integer, String)]) of
        (numS, [(n, "")]) | not (null numS), Just m <- multiplier (snd (span isDigit s)) ->
          Right (Ago (n * m))
        _ ->
          case parseTimeM True defaultTimeLocale "%Y-%m-%d" s of
            Just t  -> Right (At (fromIntegral (floor (utcTimeToPOSIXSeconds t) :: Integer)))
            Nothing -> Left (timeErr s)
  where
    isDigit c = c >= '0' && c <= '9'
    multiplier u = case u of
      "s"  -> Just 1
      "m"  -> Just 60
      "h"  -> Just 3600
      "d"  -> Just 86400
      "w"  -> Just 604800
      "mo" -> Just 2592000
      "y"  -> Just 31536000
      _    -> Nothing
    timeErr x =
      "cannot read time: " <> x
        <> " (try 2h, 7d, 2026-01-01, or a unix timestamp)"

-- | Filter options shared by feed, search, export and watch.
data FilterOpts = FilterOpts
  { foKinds   :: [Int]
  , foAuthors :: [Text]
  , foTags    :: [(Text, Text)]
  , foSince   :: Maybe TimeSpec
  , foUntil   :: Maybe TimeSpec
  , foLimit   :: Int
  , foSearch  :: Maybe Text
  }

emptyFilterOpts :: FilterOpts
emptyFilterOpts = FilterOpts [] [] [] Nothing Nothing 100 Nothing

parseKind :: String -> Either String Int
parseKind s = case s of
  "note"     -> Right 1
  "dm"       -> Right 4
  "delete"   -> Right 5
  "repost"   -> Right 6
  "like"     -> Right 7
  "metadata" -> Right 0
  "follow"   -> Right 3
  "relays"   -> Right 10002
  "giftwrap" -> Right 1059
  -- A kind is a 16-bit unsigned integer (NIP-01). reads would happily accept
  -- "-1" and a value past 65535, neither of which can match a stored event.
  _ | not (null s), all isDigitAscii s ->
        case reads s of
          [(n, "")] | n >= 0, n <= maxKind -> Right n
          _          -> Left (unknownKind s)
    | otherwise -> Left (unknownKind s)

-- | NIP-01 fixes the kind range at 16 bits.
maxKind :: Int
maxKind = 65535

unknownKind :: String -> String
unknownKind s =
  "unknown kind: " <> s <> " (try note, dm, like, repost, metadata, relays)"

isDigitAscii :: Char -> Bool
isDigitAscii c = c >= '0' && c <= '9'

-- | Accept @e=<value>@, @#e=<value>@ and bare @name=value@.
parseTag :: String -> Either String (Text, Text)
parseTag s =
  let cleaned = case s of ('#' : rest) -> rest; _ -> s
      (k, v)  = break (== '=') cleaned
  in if null k || null v
       then Left ("tag filter must look like e=<value>, got: " <> s)
       else Right (T.pack k, T.pack (drop 1 v))

-- | Turn a nostr identifier into the hex pubkey the store indexes.
resolveAuthor :: String -> Either String Text
resolveAuthor s =
  case importNpub (T.pack s) of
    Right pk -> Right (pubKeyHex pk)
    Left _
      | isHex64 t -> Right t
      | otherwise -> Left (s <> " is neither an npub nor a 64-character hex pubkey")
      where t = T.pack s

-- | The same, but keeping the parsed key: encrypting needs the curve point.
resolveRecipient :: String -> Either String PublicKey
resolveRecipient s =
  case importNpub (T.pack s) of
    Right pk -> Right pk
    Left _
      | isHex64 t ->
          case B16.decode (TE.encodeUtf8 t) of
            Right bs -> maybe (Left "that pubkey is not a point on the curve") Right
                           (publicKeyFromBytes bs)
            Left e  -> Left ("bad hex pubkey: " <> show e)
      | otherwise -> Left (s <> " is neither an npub nor a 64-character hex pubkey")
      where t = T.pack s

parseLevel :: String -> Either String LogLevel
parseLevel s = case map lower s of
  "debug"   -> Right Debug
  "info"    -> Right Info
  "warn"    -> Right Warn
  "warning" -> Right Warn
  "error"   -> Right Error
  _         -> Left ("unknown log level: " <> s)
  where
    lower c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

buildFilter :: FilterOpts -> IO Filter
buildFilter fo = do
  since  <- traverse resolveTime (foSince fo)
  until' <- traverse resolveTime (foUntil fo)
  pure Filter
    { fIds     = Nothing
    , fAuthors = if null (foAuthors fo) then Nothing else Just (foAuthors fo)
    , fKinds   = if null (foKinds fo) then Nothing else Just (foKinds fo)
    , fSince   = since
    , fUntil   = until'
    , fLimit   = Just (foLimit fo)
    , fTags    = groupTags (foTags fo)
    , fSearch  = foSearch fo
    }

-- | @--tag e=a --tag e=@ means @e@ matches either, not that @e@ must be both.
groupTags :: [(Text, Text)] -> [(Text, [Text])]
groupTags = M.toList . M.fromListWith (flip (<>)) . map (\(k, v) -> (k, [v]))

-- | The effective upstream set from flags and the saved table: their
-- union, or the compiled-in defaults when both are empty. Pure so the rule
-- is testable; `bridgeConfig` and `relay list` share it, so they agree.
resolveUpstreams :: [Text] -> [Text] -> [Text]
resolveUpstreams flags saved = case nub (flags <> saved) of
  [] -> defaultRelays
  xs -> xs

csvField :: Text -> Text
csvField t
  | T.any (\c -> c == ',' || c == '"' || c == '\n' || c == '\r') t =
      "\"" <> T.replace "\"" "\"\"" t <> "\""
  | otherwise = t

renderCsv :: [Event] -> String
renderCsv evs = T.unpack (T.unlines rows)
  where
    headerRow = "id,pubkey,created_at,kind,tags,content,sig"
    rows =
      headerRow :
      [ T.intercalate ","
          [ csvField (evId e)
          , csvField (evPubkey e)
          , T.pack (show (floor (evCreatedAt e) :: Integer))
          , T.pack (show (evKind e))
          , csvField (T.intercalate " " (map tagCell (evTags e)))
          , csvField (evContent e)
          , csvField (evSig e)
          ]
      | e <- evs
      ]

-- | One tag as @name=value|value@: CSV has no nesting, and @|@ cannot appear
-- unquoted in a tag value often enough to be worth escaping here.
tagCell :: [Text] -> Text
tagCell []       = ""
tagCell (k : vs) = k <> "=" <> T.intercalate "|" vs

substitute :: String -> Event -> Text
substitute cmd e =
  T.replace "{content}" (evContent e)
  $ T.replace "{author}" (evPubkey e)
  $ T.replace "{kind}" (T.pack (show (evKind e)))
  $ T.replace "{json}" (TE.decodeUtf8 (BLC.toStrict (Aeson.encode e)))
  $ T.pack cmd
