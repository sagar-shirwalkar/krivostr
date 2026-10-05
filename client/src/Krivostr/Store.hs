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
  , searchEvents
  , searchQuery
  , searchAvailable
  , searchCount
  , reindexEvents
  , reindexIfStale
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
  _ <- initialiseSearch conn
  execute_ conn "PRAGMA journal_mode = WAL"
  execute_ conn "PRAGMA synchronous  = NORMAL"

-- | Full-text index over event content, kept in step by triggers.
--
-- A standalone (not @content=events@) FTS5 table: external-content tables have
-- to be rebuilt by hand after a restore or a partial write, and this index is
-- derived data we are happy to throw away and recompute.
--
-- The bundled SQLite has FTS5 compiled in, but creating a virtual table is the
-- one statement here that can fail on an exotic build, so a failure degrades to
-- "no search" instead of taking the whole store down with it.
initialiseSearch :: Connection -> IO Bool
initialiseSearch conn = do
  r <- try $ do
    execute_ conn
      "CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(\
      \  body,\
      \  event_id UNINDEXED,\
      \  tokenize = 'porter unicode61'\
      \)"
    -- AFTER INSERT only fires for rows SQLite actually inserts, so
    -- `INSERT OR IGNORE` on an existing id leaves the index alone.
    execute_ conn
      "CREATE TRIGGER IF NOT EXISTS events_fts_ai AFTER INSERT ON events BEGIN\
      \  INSERT INTO events_fts(event_id, body) VALUES (new.id, new.content);\
      \END"
    execute_ conn
      "CREATE TRIGGER IF NOT EXISTS events_fts_ad AFTER DELETE ON events BEGIN\
      \  DELETE FROM events_fts WHERE event_id = old.id;\
      \END"
  pure $ case r of
    Left (_ :: SomeException) -> False
    Right ()                   -> True

-- | Whether this store has a usable search index.
searchAvailable :: Store -> IO Bool
searchAvailable st = do
  r <- try (query_ (stConn st) "SELECT 1 FROM events_fts LIMIT 1" :: IO [Only Int64])
  pure $ case r of
    Left (_ :: SomeException) -> False
    Right _                   -> True

-- | Number of rows currently in the search index.
searchCount :: Store -> IO Int
searchCount st = do
  rows <- query_ (stConn st) "SELECT COUNT(*) FROM events_fts" :: IO [Only Int64]
  pure $ maybe 0 fromIntegral $ headMay (map unOnly rows)
  where
    unOnly (Only x) = x
    headMay []      = Nothing
    headMay (x : _) = Just x

-- | Drop and rebuild the search index from the events table.
--
-- Returns the number of rows indexed. Safe to call at any time; the triggers
-- keep it honest from then on.
reindexEvents :: Store -> IO Int
reindexEvents st = do
  withTransaction (stConn st) $ do
    execute_ (stConn st) "DELETE FROM events_fts"
    execute_ (stConn st)
      "INSERT INTO events_fts(event_id, body) SELECT id, content FROM events"
  n <- searchCount st
  emit (stLogger st) Info ("store.reindex: indexed " <> T.pack (show n) <> " events")
  pure n

-- | Rebuild the index only if it has fallen behind the events table.
--
-- An index that is behind is the normal state of a database written before the
-- FTS tables existed, or one restored from a backup, so opening a store is the
-- right moment to notice.
reindexIfStale :: Store -> IO Bool
reindexIfStale st = do
  ok <- searchAvailable st
  if not ok
    then pure False
    else do
      indexed <- searchCount st
      total <- countEvents st
      if indexed == total
        then pure False
        else do
          emit (stLogger st) Warn
            ( "store: search index is stale ("
                <> T.pack (show indexed) <> " of " <> T.pack (show total)
                <> "), rebuilding"
            )
          void (reindexEvents st)
          pure True

-- | Turn free text into an FTS5 MATCH expression.
--
-- Each alphanumeric run becomes a quoted phrase and the phrases are joined with
-- @AND@ (or @OR@). Handing user input straight to @MATCH@ would be a syntax
-- error waiting to happen: @c++@, @foo-bar@, @NOT@, an unbalanced quote or a
-- bare @*@ all make FTS5 raise, and a search box should never do that.
searchQuery :: Bool -> Text -> Maybe Text
searchQuery anyWord input =
  let words = filter (not . T.null) (map T.strip (T.splitOn " " raw))
      quoted = [ "\"" <> T.replace "\"" " " w <> "\"" | w <- words, hasAlnum w ]
      joiner = if anyWord then " OR " else " AND "
  in if null quoted then Nothing else Just (T.intercalate joiner quoted)
  where
    raw = T.unwords (T.words input)
    hasAlnum = T.any (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z')

-- | Full-text search over event content, best match first.
--
-- @anyWord@ switches from AND to OR semantics. Returns an empty list if the
-- store has no search index, so callers do not need to check first.
searchEvents :: Store -> Text -> Bool -> Maybe [Int] -> Maybe Text -> Int -> IO [Event]
searchEvents st text anyWord kinds author lim =
  -- The first argument cannot be called `query`: that name belongs to
  -- Database.SQLite.Simple, and shadowing it makes the call below a Text
  -- applied to three arguments.
  case searchQuery anyWord text of
    Nothing   -> pure []
    Just matchExpr -> do
      ok <- searchAvailable st
      if not ok
        then pure []
        else do
          let kindClause = case kinds of
                Just ks | not (null ks) ->
                  " AND e.kind IN (" <> placeholders (length ks) <> ")"
                _ -> ""
              authClause = maybe "" (const " AND e.pubkey = ?") author
              -- No alias on events_fts: FTS5 needs the real table name in MATCH
              -- and in bm25().
              sql = "SELECT e.id, e.pubkey, e.created_at, e.kind, e.tags, e.content, e.sig\
                    \ FROM events_fts JOIN events e ON e.id = events_fts.event_id\
                    \ WHERE events_fts MATCH ?" <> kindClause <> authClause <> "\
                    \ ORDER BY bm25(events_fts), e.created_at DESC LIMIT ?"
              params = [toField matchExpr]
                ++ maybe [] (map toField) kinds
                ++ maybe [] (\a -> [toField a]) author
                ++ [toField (max 1 lim)]
          query (stConn st) (Query sql) params

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
--
-- A NIP-50 @search@ filter is answered from the FTS5 index instead of the
-- row scan: the MATCH ranks by bm25, and 'matches' then applies the
-- remaining predicates (ids, time bounds, tags, and the substring reading
-- of the same search). Without an index the row scan still runs and
-- 'matches' answers search as a substring, so the filter never fails -- it
-- only gets slower.
queryEvents :: Store -> Filter -> IO [Event]
queryEvents st f = case fSearch f of
  Just q | not (T.null (T.strip q)) -> do
    ok <- searchAvailable st
    if not ok
      then rowScan
      else do
        let lim = fromMaybe defaultLimit (fLimit f)
            author = case fAuthors f of
              Just [a] -> Just a
              _        -> Nothing
        evs <- searchEvents st q False (fKinds f) author (max 1 (lim * 4))
        pure (take lim (filter (matches f) evs))
  _ -> rowScan
  where
    rowScan = do
      let (whereClause, params) = buildWhere f
          lim = fromMaybe defaultLimit (fLimit f)
          -- The limit is a bound parameter in the SQL rather than a Haskell
          -- `take` afterwards: `take` still pulled every matching row out of
          -- SQLite first, so a broad filter read the entire table to return
          -- 500 of them.
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

-- | @?,?,?@ for an @IN@ clause of the given arity.
placeholders :: Int -> Text
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
