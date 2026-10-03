{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Krivostr.Store
  ( Store
  , openStore
  , openMemoryStore
  , closeStore
  , insertEvent
  , insertEvents
  , queryEvents
  , queryEventsWith
  , countEvents
  , getEventById
  , deleteEvent
  , evictExpired
  , storeStats
  , StoreStats(..)
  , defaultRetentionDays
  , persistentKinds
  ) where

import Control.Exception (bracket, try, SomeException)
import Control.Monad (forM_, void, when)
import Data.Int (Int64)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Data.Time.Clock (UTCTime, NominalDiffTime, diffUTCTime, addUTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds, posixSecondsToUTCTime)
import Database.SQLite.Simple
import Database.SQLite.Simple.FromRow
import Krivostr.Event
import Krivostr.Filter
import Krivostr.Logging
import Data.Aeson (encode, decode, eitherDecode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as BS

-- | Kinds that are never evicted, regardless of age.
persistentKinds :: [Int]
persistentKinds = [0, 3, 4, 1059, 10002]

-- | Default retention for ephemeral events (30 days).
defaultRetentionDays :: NominalDiffTime
defaultRetentionDays = 30 * 24 * 60 * 60

data Store = Store
  { stConn   :: Connection
  , stLogger :: Logger
  }

data StoreStats = StoreStats
  { ssTotal      :: !Int
  , ssOldest     :: !(Maybe POSIXTime)
  , ssNewest     :: !(Maybe POSIXTime)
  , ssByKind     :: ![(Int, Int)]
  } deriving (Show, Eq)

instance FromRow Event where
  fromRow = do
    eid     :: Text <- field
    pubkey  :: Text <- field
    created :: Int64 <- field
    kind    :: Int   <- field
    tagsJ   :: Text <- field
    content :: Text <- field
    sig     :: Text <- field
    tags <- case decode (BL.fromStrict (TE.encodeUtf8 tagsJ)) of
      Just t  -> pure t
      Nothing -> pure []
    pure Event
      { evId = eid
      , evPubkey = pubkey
      , evCreatedAt = fromIntegral created
      , evKind = kind
      , evTags = tags
      , evContent = content
      , evSig = sig
      }

toRow :: Event -> (Text, Text, Int64, Int, Text, Text, Text)
toRow e =
  ( evId e
  , evPubkey e
  , floor (evCreatedAt e)
  , evKind e
  , TE.decodeUtf8 (BL.toStrict (encode (evTags e)))
  , evContent e
  , evSig e
  )

-- | Open a store backed by a file. Runs migrations.
openStore :: Logger -> FilePath -> IO Store
openStore lg path = do
  conn <- open path
  initialise conn
  emit lg Info ("store: opened " <> T.pack path)
  pure (Store conn lg)

-- | In-memory store, for tests.
openMemoryStore :: Logger -> IO Store
openMemoryStore lg = do
  conn <- open ":memory:"
  initialise conn
  pure (Store conn lg)

initialise :: Connection -> IO ()
initialise conn = do
  execute_ conn
    "CREATE TABLE IF NOT EXISTS events (\
    \  id         TEXT PRIMARY KEY,\
    \  pubkey     TEXT NOT NULL,\
    \  created_at INTEGER NOT NULL,\
    \  kind       INTEGER NOT NULL,\
    \  tags       TEXT NOT NULL,\
    \  content    TEXT NOT NULL,\
    \  sig        TEXT NOT NULL\
    \)"
  execute_ conn "CREATE INDEX IF NOT EXISTS idx_pubkey     ON events(pubkey)"
  execute_ conn "CREATE INDEX IF NOT EXISTS idx_created_at ON events(created_at)"
  execute_ conn "CREATE INDEX IF NOT EXISTS idx_kind       ON events(kind)"
  execute_ conn "PRAGMA journal_mode = WAL"
  execute_ conn "PRAGMA synchronous  = NORMAL"

closeStore :: Store -> IO ()
closeStore = close . stConn

-- | Idempotent: INSERT OR IGNORE on the primary key.
insertEvent :: Store -> Event -> IO Bool
insertEvent st e = do
  r <- try $ execute (stConn st)
    "INSERT OR IGNORE INTO events \
    \(id, pubkey, created_at, kind, tags, content, sig) \
    \VALUES (?, ?, ?, ?, ?, ?, ?)"
    (toRow e)
  case r of
    Left (err :: SomeException) -> do
      emit (stLogger st) Error ("store.insert: " <> T.pack (show err))
      pure False
    Right () -> pure True

insertEvents :: Store -> [Event] -> IO Int
insertEvents st es = do
  withTransaction (stConn st) $ forM_ es $ \e -> void $ insertEvent st e
  countEvents st

-- | Query by a filter. Everything happens in SQL for indexed fields,
-- tag and content matching happens in Haskell (small N, cleaner).
queryEvents :: Store -> Filter -> IO [Event]
queryEvents st f = do
  let (whereClause, params) = buildWhere f
      sql = "SELECT id, pubkey, created_at, kind, tags, content, sig \
            \FROM events " <> whereClause <> " ORDER BY created_at DESC"
      lim = fromMaybe 500 (fLimit f)
  rows <- query (stConn st) (Query (TE.encodeUtf8 sql)) params
  let filtered = filter (matches f) rows
  pure (take lim filtered)

-- | Query with an ad-hoc SQL suffix (escape hatch for advanced callers).
queryEventsWith :: Store -> Text -> [Param] -> IO [Event]
queryEventsWith st sql params =
  query (stConn st) (Query (TE.encodeUtf8 sql)) params

buildWhere :: Filter -> (Text, [Param])
buildWhere f =
  let clauses = concat
        [ maybe [] (\ids -> [ "id IN (" <> placeholders (length ids) <> ")"
                            , map ToField ids ]) (fIds f)
        , maybe [] (\as  -> [ "pubkey IN (" <> placeholders (length as) <> ")"
                            , map ToField as ]) (fAuthors f)
        , maybe [] (\ks  -> [ "kind IN (" <> placeholders (length ks) <> ")"
                            , map (ToField . T.pack . show) ks ]) (fKinds f)
        , maybe [] (\s   -> [ "created_at >= ?", [ToField (T.pack (show (floor s :: Integer)))]] ) (fSince f)
        , maybe [] (\u   -> [ "created_at <= ?", [ToField (T.pack (show (floor u :: Integer)))]] ) (fUntil f)
        ]
      (fragments, allParams) = unzip clauses
      whereText =
        if null fragments
          then ""
          else "WHERE " <> T.intercalate " AND " fragments
  in (whereText, concat allParams)
  where
    placeholders n = T.intercalate "," (replicate n "?")

countEvents :: Store -> IO Int
countEvents st = do
  [Only n] <- query_ (stConn st) "SELECT COUNT(*) FROM events" :: IO [Only Int]
  pure n

getEventById :: Store -> Text -> IO (Maybe Event)
getEventById st eid = do
  rows <- query (stConn st)
    "SELECT id, pubkey, created_at, kind, tags, content, sig \
    \FROM events WHERE id = ? LIMIT 1"
    (Only eid)
  pure $ case rows of
    (e:_) -> Just e
    _     -> Nothing

deleteEvent :: Store -> Text -> IO ()
deleteEvent st eid =
  execute (stConn st) "DELETE FROM events WHERE id = ?" (Only eid)

-- | Delete events older than the retention window. Returns the count.
-- Persistent kinds (DMs, follows, metadata, relay lists) are kept.
evictExpired :: Store -> IO Int
evictExpired st = do
  now <- getPOSIXTime
  let cutoff = floor (now - defaultRetentionDays) :: Int64
      keep = T.intercalate "," (map (T.pack . show) persistentKinds)
      sql = "DELETE FROM events \
            \WHERE created_at < ? \
            \  AND kind NOT IN (" <> keep <> ")"
  before <- countEvents st
  execute (stConn st) (Query (TE.encodeUtf8 sql)) (Only cutoff)
  after <- countEvents st
  let removed = before - after
  when (removed > 0) $
    emit (stLogger st) Info
      ("store.evict: removed " <> T.pack (show removed) <> " events")
  pure removed

storeStats :: Store -> IO StoreStats
storeStats st = do
  total <- countEvents st
  oldest <- query_ (stConn st)
    "SELECT MIN(created_at) FROM events" :: IO [Only (Maybe Int64)]
  newest <- query_ (stConn st)
    "SELECT MAX(created_at) FROM events" :: IO [Only (Maybe Int64)]
  byKind <- query_ (stConn st)
    "SELECT kind, COUNT(*) FROM events GROUP BY kind ORDER BY 2 DESC"
    :: IO [(Int, Int)]
  pure StoreStats
    { ssTotal = total
    , ssOldest = fmap fromIntegral . unOnly <$> headMay oldest
    , ssNewest = fmap fromIntegral . unOnly <$> headMay newest
    , ssByKind = byKind
    }
  where
    unOnly (Only x) = x
    headMay []    = Nothing
    headMay (x:_) = Just x
