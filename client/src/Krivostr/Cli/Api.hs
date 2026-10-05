{-# LANGUAGE OverloadedStrings #-}

-- | A read-only JSON API over the local store.
--
-- Separate from @serve@ so the API can run on its own port, or without the
-- static file server and the WebSocket bridge, for scripts and other tools. A
-- browser UI served from Cloudflare Pages can call this cross-origin, so every
-- response carries permissive CORS headers.
--
-- The routes are deliberately the same filters the CLI understands, so
-- @?kind=1\&author=\<hex\>\&tag=t=bitcoin@ behaves the same here as
-- @krivostr search --kind 1@ and @krivostr export --kind 1@.
module Krivostr.Cli.Api
  ( runApi
  , ApiConfig(..)
  ) where

import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Read as TR
import Data.Streaming.Network.Internal (HostPreference (Host))
import Krivostr.Filter (Filter (fAuthors, fIds, fKinds, fLimit, fSearch, fSince, fTags, fUntil))
import qualified Krivostr.Filter as Filter
import Krivostr.Logging
import Krivostr.Store (StoreStats (ssByKind, ssNewest, ssOldest, ssTotal), Store, countEvents, getEventById, queryEvents, searchAvailable, searchEvents, storeStats)
import Network.HTTP.Types (Query, Status, hContentType, parseQuery, status200, status204, status400, status404, status503)
import Network.Wai
import Network.Wai.Handler.Warp
  ( defaultSettings
  , runSettings
  , setHost
  , setPort
  , setTimeout
  )

data ApiConfig = ApiConfig
  { apiPort :: !Int
  , apiHost :: !Text
  }

-- | Serve until killed.
runApi :: Logger -> ApiConfig -> Store -> IO ()
runApi lg cfg store = do
  emit lg Info
    ("api: listening on http://" <> apiHost cfg <> ":" <> T.pack (show (apiPort cfg)))
  runSettings
    (setPort (apiPort cfg)
      (setHost (Host (T.unpack (apiHost cfg)))
        (setTimeout 30 defaultSettings)))
    (app lg store)

app :: Logger -> Store -> Application
app lg store req respond = do
  -- `pathInfo` is the decoded path split into segments, without a leading slash
  -- and without the query string, so it can be matched directly.
  let segments = pathInfo req
      qs       = paramPairs (parseQuery (rawQueryString req))
  emit lg Debug ("api: /" <> T.intercalate "/" segments)
  resp <- route store segments qs
  respond (addCors req resp)

route :: Store -> [Text] -> Params -> IO Response
route store segments qs =
  case segments of
    ["api", "health"] -> do
      n <- countEvents store
      json status200 (object ["status" .= ("ok" :: Text), "events" .= n])
    ["api", "stats"] -> do
      st <- storeStats store
      json status200 (object
        [ "total"   .= ssTotal st
        , "oldest"  .= ssOldest st
        , "newest"  .= ssNewest st
        -- By kind as an object rather than a list of pairs, so a script can
        -- ask for one kind without parsing anything.
        , "by_kind" .= object [ K.fromText (T.pack (show k)) .= n | (k, n) <- ssByKind st ]
        ])
    ["api", "events"] ->
      case filterOf qs of
        Left e  -> json status400 (err e)
        Right f -> do
          evs <- queryEvents store f
          json status200 (object ["count" .= length evs, "events" .= evs])
    ["api", "events", eid] -> do
      found <- getEventById store eid
      case found of
        Nothing -> json status404 (err ("no such event: " <> eid))
        Just e  -> json status200 (toJSON e)
    ["api", "search"] ->
      case (qtext qs "q", kindsOf qs) of
        (Nothing, _) -> json status400 (err "missing q")
        (_, Left e) -> json status400 (err e)
        (Just raw, Right kinds) -> do
          available <- searchAvailable store
          if not available
            then json status503 (err "this store has no search index; run: krivostr reindex")
            else do
              let lim     = intParam qs "limit" 50
                  anyWord = qflag qs "any"
              evs <- searchEvents store raw anyWord kinds (qtext qs "author") lim
              json status200
                (object ["query" .= raw, "count" .= length evs, "results" .= evs])
    _ -> json status404 (err ("unknown route: /" <> T.intercalate "/" segments))
  where
    err :: Text -> Value
    err msg = object ["error" .= msg]

json :: Status -> Value -> IO Response
json st v = pure (responseLBS st [(hContentType, "application/json")] (encode v))

-- | CORS for a UI served from another origin, plus a preflight answer.
--
-- The preflight has to carry the headers too: a browser that does not see them
-- on the @OPTIONS@ response rejects the real request before sending it.
addCors :: Request -> Response -> Response
addCors req resp =
  case requestMethod req of
    "OPTIONS" -> mapResponseHeaders (const corsHeaders) (responseLBS status204 [] BL.empty)
    _         -> mapResponseHeaders (corsHeaders <>) resp
  where
    corsHeaders =
      [ ("Access-Control-Allow-Origin", "*")
      , ("Access-Control-Allow-Methods", "GET, OPTIONS")
      , ("Access-Control-Allow-Headers", "Content-Type")
      , ("Access-Control-Max-Age", "86400")
      ]

-- | Query parameters as plain key/value pairs.
--
-- A query item's value is optional, so @?debug@ parses fine but has nothing to
-- decode; dropping the valueless items keeps every lookup below total.
type Params = [(BS.ByteString, BS.ByteString)]

paramPairs :: Query -> Params
paramPairs = mapMaybe $ \(k, mv) -> do
  v <- mv
  pure (k, v)

-- | @?limit=&kind=&author=&since=&until=&tag=@, all optional.
filterOf :: Params -> Either Text Filter.Filter
filterOf qs = do
  lim      <- optionalInt qs "limit"
  since    <- optionalInt qs "since"
  untilEnd <- optionalInt qs "until"
  kinds    <- kindsOf qs
  let authors = wordsOf qs "author"
  pure Filter.Filter
    { fIds     = Nothing
    , fAuthors = if null authors then Nothing else Just authors
    , fKinds   = kinds
    , fSince   = fmap fromIntegral since
    , fUntil   = fmap fromIntegral untilEnd
    , fLimit   = fmap fromIntegral lim
    , fTags    = tagParams qs
    , fSearch  = qtext qs "search"
    }

-- | @?tag=e=&tag=p=&tag=t=bitcoin@: repeatable, values in the order given.
tagParams :: Params -> [(Text, [Text])]
tagParams qs =
  M.toList . M.fromListWith (flip (<>)) $
    [ (k, [v])
    | (rawK, rawV) <- qs
    , Just k <- [trimmed rawK]
    , Just v <- [trimmed rawV]
    , not (k `elem` reservedKeys)
    ]

-- | Every other query parameter names a tag, so these are the ones @filterOf@
-- consumes for itself.
reservedKeys :: [Text]
reservedKeys = ["limit", "since", "until", "kind", "author", "q", "any"]

-- | @?kind=1&kind=7@ or @?kind=1,7@.
kindsOf :: Params -> Either Text (Maybe [Int])
kindsOf qs =
  case wordsOf qs "kind" of
    [] -> Right Nothing
    ks -> Just <$> mapM parseOne ks
  where
    parseOne :: Text -> Either Text Int
    parseOne t = case TR.decimal t of
      Right (n, rest) | T.null rest -> Right n
      _                             -> Left ("bad kind: " <> t)

optionalInt :: Params -> BS.ByteString -> Either Text (Maybe Int64)
optionalInt qs k = case qtext qs k of
  Nothing -> Right Nothing
  Just v  -> case TR.decimal v of
    Right (n, rest) | T.null rest -> Right (Just n)
    _ -> Left ("bad " <> TE.decodeUtf8 k <> ": " <> v)

intParam :: Params -> BS.ByteString -> Int -> Int
intParam qs k d = case optionalInt qs k of
  Right (Just n) -> fromIntegral (max 1 n)
  _              -> d

-- | @?any@ as well as @?any=1@: presence means yes unless it says otherwise.
qflag :: Params -> BS.ByteString -> Bool
qflag qs k = case qtext qs k of
  Nothing -> any ((== k) . fst) qs
  Just v  -> v `elem` (["1", "true", "yes", "on"] :: [Text])

-- | Look up one parameter, trimmed, treating a blank value as absent.
qtext :: Params -> BS.ByteString -> Maybe Text
qtext qs k = trimmed =<< lookup k qs

-- | All values for a repeated parameter, e.g. @?author=a&author=b@.
wordsOf :: Params -> BS.ByteString -> [Text]
wordsOf qs k = maybe [] (T.words . T.strip) (qtext qs k)

trimmed :: BS.ByteString -> Maybe Text
trimmed raw = case TE.decodeUtf8' raw of
  Left _    -> Nothing
  Right t   -> let t' = T.strip t in if T.null t' then Nothing else Just t'
