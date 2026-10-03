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

import Control.Exception (SomeException, try)
import Control.Monad (forM_, void, when)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime)
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Database.SQLite.Simple
import Database.SQLite.Simple.ToField (ToField(..))
import Krivostr.Event
import Krivostr.Filter
import Krivostr.Logging
import Data.Aeson (decode, encode)
import qualified Data.ByteString.Lazy as BL

-- | Row cap applied when a filter does not specify @limit@.
defaultLimit :: Int
defaultLimit = 500

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

-- | Orphan, but 'Event' lives in krivostr-core where the SQL row shape is not
-- known. Kept here rather than in the core, which must stay free of the
-- database dependency.
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

-- | Named @eventRow@ rather than @toRow@ because @Database.SQLite.Simple@
-- exports a @toRow@ class method of its own.
eventRow :: Event -> (Text, Text, Int64, Int, Text, Text, Text)
eventRow e =
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
    (eventRow e)
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
      lim = fromMaybe defaultLimit (fLimit f)
      -- The limit is a bound parameter in the SQL rather than a Haskell `take`
      -- afterwards: `take` still pulled every matching row out of SQLite
      -- first, so a broad filter read the entire table to return 500 of them.
      sql = "SELECT id, pubkey, created_at, kind, tags, content, sig \
            \FROM events " <> whereClause <> " ORDER BY created_at DESC LIMIT ?"
      allParams = params ++ [toField lim]
  rows <- query (stConn st) (Query sql) allParams
  -- Tag and content predicates still run in Haskell, so the limit can be
  -- reached before enough rows pass; fetch the bounded page and let the caller
  -- see what survived.
  pure (filter (matches f) rows)

-- | Query with an ad-hoc SQL suffix (escape hatch for advanced callers).
queryEventsWith :: Store -> Text -> [SQLData] -> IO [Event]
queryEventsWith st sql params =
  query (stConn st) (Query sql) params

-- | Turn a 'Filter' into a @WHERE@ fragment and its bound parameters.
--
-- The clause list has to be a list of @(fragment, params)@ pairs: the previous
-- version flattened fragments and parameters into one list, which cannot
-- typecheck and never unzip'd into the two halves it claimed to produce.
buildWhere :: Filter -> (Text, [SQLData])
buildWhere f =
  let clauses :: [(Text, [SQLData])]
      clauses =
        concat
          [ maybe
              []
              (\ids -> [("id IN (" <> placeholders (length ids) <> ")", map toField ids)])
              (fIds f)
          , maybe
              []
              (\as -> [("pubkey IN (" <> placeholders (length as) <> ")", map toField as)])
              (fAuthors f)
          , maybe
              []
              ( \ks ->
                  [("kind IN (" <> placeholders (length ks) <> ")", map toField ks)]
              )
              (fKinds f)
          -- created_at is an INTEGER column. Binding it as Text made every
          -- range comparison false, because SQLite sorts TEXT above INTEGER.
          , maybe [] (\s -> [("created_at >= ?", [toField (floor s :: Int64)])]) (fSince f)
          , maybe [] (\u -> [("created_at <= ?", [toField (floor u :: Int64)])]) (fUntil f)
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
  execute (stConn st) (Query sql) (Only cutoff)
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
    -- MIN/MAX over an empty table is NULL, so the aggregate row is already
    -- Maybe Int64; headMay then adds the outer layer.
    , ssOldest = headMay oldest >>= (toPosix . unOnly)
    , ssNewest = headMay newest >>= (toPosix . unOnly)
    , ssByKind = byKind
    }
  where
    unOnly (Only x) = x
    toPosix = fmap (fromIntegral :: Int64 -> POSIXTime)
    headMay []    = Nothing
    headMay (x:_) = Just x
