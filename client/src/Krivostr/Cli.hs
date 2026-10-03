{-# LANGUAGE OverloadedStrings #-}

-- | The @krivostr@ command line: one static binary over the SQLite store.
--
-- Every subcommand opens the same database the bridge uses, so the CLI, the HTTP
-- API and the browser all see one history. That is the whole point: the store
-- outlives the browser, and anything the store can answer can be scripted.
module Krivostr.Cli
  ( runCLI
  , TimeSpec(..)
  , resolveTime
  , parseWhen
  , parseKind
  , parseTag
  , isHex64
  , resolveAuthor
  , resolveRecipient
  , buildFilter
  , FilterOpts(..)
  , emptyFilterOpts
  , csvField
  , renderCsv
  , substitute
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.MVar
-- `orElse` is the fallback-on-empty-list helper used by the parsers below.
import Control.Concurrent.STM hiding (orElse)
import Control.Exception (bracket, finally)
import Control.Monad (forM_, forever, unless, void, when)
import Data.Aeson (ToJSON, encode)
import Data.Char (toLower)
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.List (dropWhileEnd)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime, utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Krivostr.Bridge
import Krivostr.Cli.Api
import Krivostr.Cli.Nostr
import Krivostr.Cli.Render
import Krivostr.Event
import Krivostr.Filter
import Krivostr.Key
-- `info` is a log level here and a parser combinator in optparse-applicative.
import Krivostr.Logging hiding (info)
import Krivostr.Nip.Nip01 (verifyEvent)
import Krivostr.Nip.Nip65 (RelayHint (..), RelayMode (..), parseRelayList)
import Krivostr.Pool
import Krivostr.Store
import Options.Applicative
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitSuccess), exitFailure)
import System.FilePath (takeDirectory)
import System.IO
import System.Process (readProcessWithExitCode)

-- ═══════════════════════════════════════════════════════════ time

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

-- ═══════════════════════════════════════════════════════════ options

-- | Filter options shared by feed, search, export and watch.
data FilterOpts = FilterOpts
  { foKinds   :: [Int]
  , foAuthors :: [Text]
  , foTags    :: [(Text, Text)]
  , foSince   :: Maybe TimeSpec
  , foUntil   :: Maybe TimeSpec
  , foLimit   :: Int
  }

emptyFilterOpts :: FilterOpts
emptyFilterOpts = FilterOpts [] [] [] Nothing Nothing 100

data Command
  = CmdServe ServeOpts
  | CmdFeed FeedOpts
  | CmdSearch SearchOpts
  | CmdDm DmOpts
  | CmdExport ExportOpts
  | CmdWatch WatchOpts
  | CmdApi ApiOpts
  | CmdReindex
  | CmdKeygen

data ServeOpts = ServeOpts
  { soPort     :: Maybe Int
  , soHost     :: Maybe Text
  , soStatic   :: Maybe FilePath
  , soUpstream :: [Text]
  }

data FeedOpts = FeedOpts
  { fdFilter :: FilterOpts
  , fdJson   :: Bool
  , fdLong   :: Bool
  , fdFollow :: Bool
  , fdIngest :: Bool
  , fdRelays :: [Text]
  }

data SearchOpts = SearchOpts
  { seQuery  :: Text
  , seAny    :: Bool
  , seFilter :: FilterOpts
  , seJson   :: Bool
  }

data DmOpts = DmOpts
  { dmRecipient :: Maybe String
  , dmMessage   :: Maybe String
  , dmInbox     :: Bool
  , dmRelays    :: [Text]
  , dmTimeout   :: Int
  , dmLimit     :: Int
  }

data ExportOpts = ExportOpts
  { exFilter :: FilterOpts
  , exFormat :: String
  , exOut    :: Maybe FilePath
  }

data WatchOpts = WatchOpts
  { waFilter   :: FilterOpts
  , waExec     :: Maybe String
  , waBell     :: Bool
  , waInterval :: Int
  , waExisting :: Bool
  , waUnit     :: Bool
  }

data ApiOpts = ApiOpts
  { aoPort :: Int
  , aoHost :: Text
  }

-- | Global flags. All @Maybe@ so an unset flag can fall back to the environment
-- variable the README documents.
data Global = Global
  { gDb    :: Maybe FilePath
  , gLevel :: Maybe LogLevel
  , gColor :: Maybe Bool
  }

data Opts = Opts Global Command

-- ═══════════════════════════════════════════════════════════ parser

runCLI :: IO ()
runCLI = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  execParser parserInfo >>= dispatch

-- | Version reported by @--version@. Kept here rather than generated from
-- client/package.yaml because hpack does not expose the package version to the
-- source; the release workflow reads the tag, so the two are the same string.
version :: String
version = "0.2.0.0"

-- | @--version@ answers without needing a subcommand, so `krivostr --version`
-- works in a script that knows nothing about the command set.
versionP :: Parser (a -> a)
versionP = infoOption ("krivostr " <> version)
  (long "version" <> help "Show the version and exit")

parserInfo :: ParserInfo Opts
parserInfo = info (helper <*> versionP <*> optsP) ( fullDesc
  <> progDesc "One binary: bridge, CLI, search and HTTP API over a local SQLite store"
  <> header "krivostr — the store outlives the browser, so everything in it is scriptable."
  <> footer "Run `krivostr <command> --help` for one command's options." )

optsP :: Parser Opts
optsP = Opts
  <$> ( Global
      <$> optional (strOption
            ( long "db" <> metavar "PATH"
           <> help "SQLite database (env: KRIVOSTR_DB, default .krivostr/events.db)" ))
      <*> optional (option (eitherReader parseLevel)
            ( long "log-level" <> metavar "LEVEL"
           <> help "debug | info | warn | error (env: KRIVOSTR_LOG_LEVEL, default info)" ))
      <*> ( (Just True <$ flag' True (long "color" <> help "Force ANSI colour"))
          <|> (Just False <$ flag' False (long "no-color" <> help "Never emit ANSI colour"))
          <|> pure Nothing ) )
  <*> commandP

commandP :: Parser Command
commandP = hsubparser
  ( command "serve"   (info (CmdServe   <$> serveP)   (progDesc "Run the bridge: WebSocket + static UI"))
 <> command "feed"    (info (CmdFeed    <$> feedP)    (progDesc "Read the store; --follow streams live"))
 <> command "search"  (info (CmdSearch  <$> searchP)  (progDesc "Full-text search over the local store"))
 <> command "dm"      (info (CmdDm      <$> dmP)      (progDesc "Send a NIP-04 DM, or --inbox to read yours"))
 <> command "export"  (info (CmdExport  <$> exportP)  (progDesc "Bulk export as nostr (ndjson), array or csv"))
 <> command "watch"   (info (CmdWatch   <$> watchP)   (progDesc "Notify on new events"))
 <> command "api"     (info (CmdApi     <$> apiP)     (progDesc "Run the JSON HTTP API on its own port"))
 <> command "reindex" (info (pure CmdReindex)         (progDesc "Rebuild the full-text search index"))
 <> command "keygen"  (info (pure CmdKeygen)          (progDesc "Generate an nsec / npub pair"))
  )

serveP :: Parser ServeOpts
serveP = ServeOpts
  <$> optional (option auto (long "port" <> metavar "N"
        <> help "Bridge port (env: KRIVOSTR_PORT, default 8081)"))
  <*> optional (T.pack <$> strOption (long "host" <> metavar "ADDR"
        <> value "127.0.0.1" <> showDefault
        <> help "Interface to bind (env: KRIVOSTR_BRIDGE_HOST)"))
  <*> optional (strOption (long "static" <> metavar "DIR"
        <> help "Static UI directory (env: KRIVOSTR_STATIC_DIR, default ./ui/dist)"))
  <*> (withDefaults defaultRelays <$> many (urlOption "upstream" "Upstream relay"))

feedP :: Parser FeedOpts
feedP = FeedOpts
  <$> filterP
  <*> switch (long "json" <> help "One JSON event per line")
  <*> switch (long "long" <> help "Multi-line, keeping the content's own line breaks")
  <*> switch (long "follow" <> short 'f' <> help "Stream live from relays instead of reading the store")
  <*> switch (long "ingest" <> help "With --follow, also store what arrives")
  <*> many (urlOption "relay" "Relay to stream from")

searchP :: Parser SearchOpts
searchP = SearchOpts
  <$> argument str (metavar "QUERY" <> help "Words to look for")
  <*> switch (long "any" <> help "Match any word instead of all of them")
  <*> filterP
  <*> switch (long "json" <> help "One JSON event per line")

dmP :: Parser DmOpts
dmP = DmOpts
  <$> optional (argument str (metavar "RECIPIENT" <> help "npub, nprofile or hex pubkey"))
  <*> optional (argument str (metavar "MESSAGE" <> help "Message text"))
  <*> switch (long "inbox" <> help "List recent DMs addressed to you, decrypted")
  <*> many (urlOption "relay" "Relay to publish to")
  <*> option auto (long "timeout" <> metavar "SECONDS" <> value 15 <> showDefault
                <> help "How long to wait for each relay's OK")
  <*> option auto (long "limit" <> short 'n' <> metavar "N" <> value 50 <> showDefault
                <> help "How many to list with --inbox")

exportP :: Parser ExportOpts
exportP = ExportOpts
  <$> filterP
  <*> strOption (long "format" <> metavar "FMT" <> value "nostr" <> showDefault
             <> help "nostr (ndjson) | array | csv")
  <*> optional (strOption (long "out" <> metavar "FILE" <> help "Write here instead of stdout"))

watchP :: Parser WatchOpts
watchP = WatchOpts
  <$> filterP
  <*> optional (strOption (long "exec" <> metavar "CMD"
        <> help "Run CMD per event; {json} {content} {author} {kind} are substituted"))
  <*> switch (long "bell" <> help "Ring the terminal bell")
  <*> option auto (long "interval" <> metavar "SECONDS" <> value 2 <> showDefault
                <> help "How often to poll the store")
  <*> switch (long "existing" <> help "Also announce events already stored at startup")
  <*> switch (long "print-unit" <> help "Print a systemd user unit and exit")

apiP :: Parser ApiOpts
apiP = ApiOpts
  <$> option auto (long "port" <> metavar "N" <> value 8090 <> showDefault <> help "API port")
  <*> (T.pack <$> strOption (long "host" <> metavar "ADDR" <> value "127.0.0.1" <> showDefault
             <> help "Interface to bind (env: KRIVOSTR_API_HOST)"))

-- | Filter options shared by feed, search, export and watch.
--
-- No kind restriction and no time window by default: @krivostr feed@ on an
-- empty store should say the store is empty, not claim there are no notes.
filterP :: Parser FilterOpts
filterP = FilterOpts
  <$> many (option (eitherReader parseKind) ( long "kind" <> short 'k' <> metavar "KIND"
       <> help "note | dm | like | repost | delete | metadata | follow | relays, or a number" ))
  <*> many (option (eitherReader resolveAuthor) ( long "author" <> short 'a' <> metavar "KEY"
       <> help "npub or hex pubkey, repeatable" ))
  <*> many (option (eitherReader parseTag) ( long "tag" <> short 't' <> metavar "NAME=VALUE"
       <> help "Tag filter, repeatable, e.g. -t e=<id>" ))
  <*> optional (option (eitherReader parseWhen) (long "since" <> metavar "WHEN"
       <> help "2h, 7d, 2026-01-01, or a unix timestamp"))
  <*> optional (option (eitherReader parseWhen) (long "until" <> metavar "WHEN"
       <> help "Same forms as --since"))
  <*> option auto (long "limit" <> short 'n' <> metavar "N" <> value 100 <> showDefault
                <> help "Maximum events")

-- ═══════════════════════════════════════════════════════════ value parsers

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

isHex64 :: Text -> Bool
isHex64 t = T.length t == 64 && T.all isHexDigit t
  where
    isHexDigit c = (c >= '0' && c <= '9')
                || (c >= 'a' && c <= 'f')
                || (c >= 'A' && c <= 'F')

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

-- | Turn parsed options into a 'Filter', resolving relative times against now.
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
    }

-- | @--tag e=a --tag e=@ means @e@ matches either, not that @e@ must be both.
groupTags :: [(Text, Text)] -> [(Text, [Text])]
groupTags = M.toList . M.fromListWith (flip (<>)) . map (\(k, v) -> (k, [v]))

-- | A @wss://@ URL as Text, repeatable.
urlOption :: String -> String -> Parser Text
urlOption name what =
  T.pack <$> strOption (long name <> metavar "URL" <> help (what <> ", repeatable"))

-- | The default set when a repeatable option was not given at all.
--
-- The list comes first so @withDefaults defaultRelays <$> many urlOption@ infers
-- without help: the element type is fixed by the argument we pass in.
withDefaults :: [a] -> [a] -> [a]
withDefaults def ds = if null ds then def else ds

-- ═══════════════════════════════════════════════════════════ dispatch

-- | Print what the logger queues to stderr for as long as the command runs.
--
-- A 'Logger' is a queue that something has to empty, and nothing in the program
-- did: without this, @--log-level@ had no visible effect anywhere.
withStderrLog :: Logger -> (Logger -> IO a) -> IO a
withStderrLog lg act =
  bracket (async (forever drain)) cancel (\_ -> act lg)
  where
    drain = do
      entries <- drainQueue lg
      forM_ entries $ \e ->
        TIO.hPutStrLn stderr (T.pack (tag (leLevel e)) <> " " <> leMsg e)
      -- Nothing to do 100 times a second is cheaper than a busy loop.
      when (null entries) (threadDelay 100000)

tag :: LogLevel -> String
tag lvl = case lvl of
  Debug -> "debug"
  Info  -> "info "
  Warn  -> "warn "
  Error -> "error"

dispatch :: Opts -> IO ()
dispatch (Opts g cmd) = do
  db     <- resolveDb g
  level  <- resolveLevel g
  colour <- resolveColour g
  lg     <- newLogger level
  withStderrLog lg $ \lg' -> case cmd of
      CmdServe o  -> do
                       cfg <- bridgeConfig o
                       withStore lg' db $ \st -> runBridge lg' cfg st
      CmdFeed o   -> cmdFeed lg' db colour o
      CmdSearch o -> cmdSearch lg' db colour o
      CmdDm o     -> cmdDm lg' db o
      CmdExport o -> cmdExport lg' db o
      CmdWatch o  -> cmdWatch lg' db colour o
      CmdApi o    -> withStore lg' db $ \st -> do
                       void (reindexIfStale st)
                       runApi lg' (ApiConfig (aoPort o) (aoHost o)) st
      CmdReindex  -> withStore lg' db $ \st -> do
                       n <- reindexEvents st
                       TIO.putStrLn ("indexed " <> T.pack (show n) <> " events")
      CmdKeygen   -> do
                       sk <- generatePrivateKey
                       TIO.putStrLn ("nsec: " <> exportNsec sk)
                       TIO.putStrLn ("npub: " <> exportNpub (derivePublicKey sk))
  where
    -- --port and --static each name an environment variable in their help text,
    -- so both are read here; a container sets them once instead of passing a
    -- command line to an image whose CMD it cannot see.
    bridgeConfig o = do
      port   <- maybe (envPort 8081 "KRIVOSTR_PORT")    pure (soPort o)
      host   <- case soHost o of
                  Just h  -> pure h
                  Nothing -> fromMaybe "127.0.0.1" <$> envText "KRIVOSTR_BRIDGE_HOST"
      static <- maybe (envPath "./ui/dist" "KRIVOSTR_STATIC_DIR") pure (soStatic o)
      pure BridgeConfig
        { bcPort = port
        , bcHost = host
        , bcStaticDir = static
        , bcUpstreams = soUpstream o
        }

resolveDb :: Global -> IO FilePath
resolveDb g = case gDb g of
  Just p  -> pure p
  Nothing -> do
    m <- envText "KRIVOSTR_DB"
    pure (maybe ".krivostr/events.db" T.unpack m)

resolveLevel :: Global -> IO LogLevel
resolveLevel g = case gLevel g of
  Just l  -> pure l
  Nothing -> do
    m <- envText "KRIVOSTR_LOG_LEVEL"
    pure $ case m of
      Nothing -> Info
      -- An unparseable level in the environment should not stop the tool.
      Just v  -> either (const Info) id (parseLevel (T.unpack v))

-- | An environment variable as trimmed Text; unset or blank reads as absent.
envText :: String -> IO (Maybe Text)
envText k = do
  v <- lookupEnv k
  pure $ case v of
    Nothing -> Nothing
    Just s  -> let t = T.strip (T.pack s) in if T.null t then Nothing else Just t

-- | Colour when asked for, when stdout is a terminal, and not when @NO_COLOR@
-- is set. Guessing the other way puts escape codes into a pipe.
-- | A port from the environment, falling back to @def@ when unset or unparseable.
envPort :: Int -> String -> IO Int
envPort def name = do
  m <- envText name
  pure $ case m >>= readMaybeInt of
    Just n | n > 0 && n < 65536 -> n
    _ -> def

-- | A path from the environment, falling back to @def@ when unset or empty.
envPath :: FilePath -> String -> IO FilePath
envPath def name = do
  m <- envText name
  pure (maybe def T.unpack m)

readMaybeInt :: Text -> Maybe Int
readMaybeInt t = case reads (T.unpack (T.strip t)) of
  [(n, "")] -> Just n
  _         -> Nothing

resolveColour :: Global -> IO Bool
resolveColour g = case gColor g of
  Just c  -> pure c
  Nothing -> do
    tty     <- hIsTerminalDevice stdout
    noColor <- lookupEnv "NO_COLOR"
    pure (tty && noColor == Nothing)

-- | Open the store, creating its directory, and always close it again.
withStore :: Logger -> FilePath -> (Store -> IO a) -> IO a
withStore lg db act = do
  createDirectoryIfMissing True (takeDirectory db)
  st <- openStore lg db
  act st `finally` closeStore st

die :: String -> IO a
die msg = hPutStrLn stderr msg >> exitFailure

-- ═══════════════════════════════════════════════════════════ feed

cmdFeed :: Logger -> FilePath -> Bool -> FeedOpts -> IO ()
cmdFeed lg db colour o
  | fdFollow o = followFeed
  | otherwise  = withStore lg db $ \st -> do
      f   <- buildFilter (fdFilter o)
      evs <- queryEvents st f
      now <- getPOSIXTime
      forM_ evs (putEvent colour now (fdJson o) (fdLong o))
      when (null evs) $
        TIO.hPutStrLn stderr "no events matched; try --limit 500, or --kind note"
  where
    -- Stream from relays, printing as events arrive.
    --
    -- @--ingest@ stores them too, which is how a headless machine builds up the
    -- history that the other subcommands read.
    followFeed = do
      f  <- buildFilter (fdFilter o)
      store <- if fdIngest o
                 then do
                   createDirectoryIfMissing True (takeDirectory db)
                   Just <$> openStore lg db
                 else pure Nothing
      relays <- case fdRelays o of
        [] -> do
          hinted <- maybe (pure []) relayHints store
          pure (if null hinted then defaultRelays else hinted)
        xs -> pure xs
      lock <- newMVar ()
      let onEvent e = withMVar lock $ \_ -> do
            now <- getPOSIXTime
            putEvent colour now (fdJson o) (fdLong o) e
            case store of
              Nothing -> pure ()
              Just st -> do
                if verifyEvent e
                  then do
                    fresh <- insertEvent st e
                    unless fresh $ emit lg Debug ("duplicate: " <> evId e)
                  else
                    emit lg Warn ("cli: rejected event " <> evId e <> " (invalid signature)")
      emit lg Info ("streaming from " <> T.intercalate ", " relays)
      pool <- newPool lg onEvent
      forM_ relays (addRelay pool)
      -- A limit means nothing to a live subscription, so drop it rather than
      -- pretend the stream is bounded.
      subscribe pool "krivostr-cli" [f { fLimit = Nothing }]
      let shutdown = do
            forM_ relays (removeRelay pool)
            mapM_ closeStore store
      flip finally shutdown $ forever $ threadDelay 1000000

-- | Relays named for reading by the newest kind 10002 in the store.
--
-- This is the CLI half of the NIP-65 story: the store already holds the relay
-- list metadata, so the tool follows it instead of carrying its own defaults.
relayHints :: Store -> IO [Text]
relayHints st = do
  evs <- queryEvents st Filter
    { fIds = Nothing, fAuthors = Nothing, fKinds = Just [10002]
    , fSince = Nothing, fUntil = Nothing, fLimit = Just 20, fTags = [] }
  pure $ case evs of
    []   -> []
    list -> [ rhUrl h | ev <- list, h <- parseRelayList ev, readable (rhMode h) ]
  where
    readable Read  = True
    readable Write = False
    readable Both  = True

-- ═══════════════════════════════════════════════════════════ search

cmdSearch :: Logger -> FilePath -> Bool -> SearchOpts -> IO ()
cmdSearch lg db colour o = withStore lg db $ \st -> do
  rebuilt <- reindexIfStale st
  when rebuilt $ TIO.hPutStrLn stderr "search index was stale; rebuilt"
  let fo         = seFilter o
      kinds      = foKinds fo
      -- Full-text search filters one author at a time; the SQL layer takes the
      -- same single-author shape.
      author     = listToMaybe' (foAuthors fo)
  evs <- searchEvents st (seQuery o) (seAny o)
         (if null kinds then Nothing else Just kinds)
         author
         (foLimit fo)
  now <- getPOSIXTime
  forM_ evs (putEvent colour now (seJson o) False)
  TIO.hPutStrLn stderr
    (T.pack (show (length evs)) <> " match(es) for " <> seQuery o)

-- ═══════════════════════════════════════════════════════════ dm

cmdDm :: Logger -> FilePath -> DmOpts -> IO ()
cmdDm lg db o
  | dmInbox o = inbox
  | otherwise =
      case (dmRecipient o, dmMessage o) of
        (Just who, Just msg) -> send who (T.pack msg)
        _ -> die "usage: krivostr dm <npub|hex> \"message\"   (or: krivostr dm --inbox)"
  where
    loadKey = do
      env <- envText "KRIVOSTR_NSEC"
      case env of
        Nothing -> die "no secret key: set KRIVOSTR_NSEC=nsec1... (see: krivostr keygen)"
        Just t  -> case importNsec t of
          Right sk -> pure sk
          Left e   -> die ("KRIVOSTR_NSEC is not an nsec: " ++ e)

    inbox =
      withStore lg db $ \st -> do
        sk <- loadKey
        let mine = pubKeyHex (derivePublicKey sk)
        evs <- queryEvents st Filter
          { fIds = Nothing, fAuthors = Nothing, fKinds = Just [4]
          , fSince = Nothing, fUntil = Nothing
          , fLimit = Just (dmLimit o), fTags = [("p", [mine])] }
        now <- getPOSIXTime
        forM_ evs $ \e -> do
          TIO.putStrLn (renderEvent False now e)
          case senderOf e of
            "" -> pure ()
            v  -> case publicKeyFromHex v of
              Nothing -> pure ()
              Just pk -> do
                r <- decryptNip04 sk pk (evContent e)
                TIO.putStrLn
                  ("  " <> either (\err -> "<cannot decrypt: " <> T.pack err <> ">") id r)
        when (null evs) $ TIO.hPutStrLn stderr "no DMs addressed to you in the store"

    -- A kind 4 has exactly one p tag: the recipient.
    senderOf e = case [ v | ("p" : v : _) <- evTags e ] of
      (v : _) -> v
      []      -> ""

    send who msg = do
      sk <- loadKey
      recipient <- either die pure (resolveRecipient who)
      now <- getPOSIXTime
      plain <- either (\e -> die ("encryption failed: " ++ e)) pure
               =<< encryptNip04 sk recipient msg
      let ev = signUnsigned sk UnsignedEvent
            { uePubkey    = pubKeyHex (derivePublicKey sk)
            , ueCreatedAt = now
            , ueKind      = 4
            , ueTags      = [["p", pubKeyHex recipient]]
            , ueContent   = plain
            }
      relays <- case dmRelays o of
        [] -> do
          hinted <- withStore lg db relayHints
          pure (if null hinted then defaultRelays else hinted)
        xs -> pure xs
      emit lg Info
        ("dm: kind 4 to " <> T.pack who <> " via " <> T.intercalate ", " relays)
      results <- publishAll lg (dmTimeout o * 1000000) ev relays
      forM_ results $ \(url, r) ->
        -- The relay's own words matter more than our verdict, so print both and
        -- let the relay explain itself.
        TIO.putStrLn $ case r of
          Right ok -> "ok    " <> url <> ": " <> ok
          Left  e  -> "fail  " <> url <> ": " <> T.pack e
      unless (any (either (const False) (const True) . snd) results) exitFailure

publicKeyFromHex :: Text -> Maybe PublicKey
publicKeyFromHex t = do
  bs <- either (const Nothing) Just (B16.decode (TE.encodeUtf8 t))
  publicKeyFromBytes bs

-- ═══════════════════════════════════════════════════════════ export

cmdExport :: Logger -> FilePath -> ExportOpts -> IO ()
cmdExport lg db o = withStore lg db $ \st -> do
  f   <- buildFilter (exFilter o)
  evs <- queryEvents st f
  body <- case map toLower (exFormat o) of
    "nostr" -> pure (ndjson evs)
    "ndjson" -> pure (ndjson evs)
    "array" -> pure (json evs)
    "csv"   -> pure (renderCsv evs)
    other   -> die ("unknown --format: " ++ other ++ " (try nostr, array, csv)")
  case exOut o of
    Nothing -> putStr body
    Just p  -> writeFile p body
  TIO.hPutStrLn stderr ("exported " <> T.pack (show (length evs)) <> " events")
  where
    json :: ToJSON a => a -> String
    json = BLC.unpack . encode
    ndjson = unlines . map json

-- | RFC 4180 quoting: double the quotes, wrap anything holding a comma or a
-- newline. Without this a note containing a comma silently shifts every column.
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

-- ═══════════════════════════════════════════════════════════ watch

cmdWatch :: Logger -> FilePath -> Bool -> WatchOpts -> IO ()
cmdWatch lg db colour o
  | waUnit o = putStr (systemdUnit db o)
  | otherwise = withStore lg db $ \st -> do
      primed <- buildFilter (waFilter o)
      seen   <- newTVarIO Set.empty
      lastAt <- newTVarIO (0 :: POSIXTime)
      unless (waExisting o) $ do
        existing <- queryEvents st primed
        now      <- getPOSIXTime
        atomically $ do
          writeTVar seen (Set.fromList (map evId existing))
          -- Start from the newest thing already stored, so only genuinely new
          -- events are announced.
          writeTVar lastAt (maybe now evCreatedAt (listToMaybe' existing))
      emit lg Info ("watch: polling every " <> T.pack (show (waInterval o)) <> "s")
      let tick = do
            base <- buildFilter (waFilter o)
            from <- readTVarIO lastAt
            evs  <- queryEvents st base { fSince = Just from }
            forM_ evs $ \e -> do
              fresh <- atomically $ do
                s <- readTVar seen
                if evId e `Set.member` s
                  then pure False
                  else do
                    writeTVar seen (Set.insert (evId e) s)
                    writeTVar lastAt (max from (evCreatedAt e))
                    pure True
              when fresh (announce e)
      flip finally (pure ()) $ forever (threadDelay (waInterval o * 1000000) >> tick)
  where
    announce e = do
      now <- getPOSIXTime
      TIO.putStrLn (renderEventBlock colour now e)
      when (waBell o) (hFlush stdout >> putStr "\a" >> hFlush stdout)
      forM_ (waExec o) $ \cmd -> do
        (code, out, err) <-
          readProcessWithExitCode "sh" ["-c", T.unpack (substitute cmd e)] ""
        let say = putStr . dropWhileEnd (== '\n')
        unless (null out) (say out)
        when (code /= ExitSuccess) $
          TIO.hPutStrLn stderr
            ("exec failed (" <> T.pack (show code) <> "): " <> T.pack err)

listToMaybe' :: [a] -> Maybe a
listToMaybe' []      = Nothing
listToMaybe' (x : _) = Just x

-- | Replace the documented placeholders.
--
-- Deliberately not a template engine: four fixed names, and shell quoting stays
-- the caller's problem because the command is handed to a shell anyway.
substitute :: String -> Event -> Text
substitute cmd e =
  T.replace "{content}" (evContent e)
  $ T.replace "{author}" (evPubkey e)
  $ T.replace "{kind}" (T.pack (show (evKind e)))
  $ T.replace "{json}" (TE.decodeUtf8 (BLC.toStrict (encode e)))
  $ T.pack cmd

-- | A ready-to-install systemd user unit: a watcher is only useful if it
-- survives logout.
systemdUnit :: FilePath -> WatchOpts -> String
systemdUnit db o =
  unlines
    [ "[Unit]"
    , "Description=krivostr watcher"
    , "After=network-online.target"
    , ""
    , "[Service]"
    , "Type=simple"
    , "ExecStart=" <> exec
    , "Restart=on-failure"
    , "RestartSec=5"
    , ""
    , "[Install]"
    , "WantedBy=default.target"
    ]
  where
    exec = "krivostr --db " <> db <> " watch " <> filterArgs (waFilter o)
    filterArgs fo = concat
      [ concat ["--kind " <> show k <> " " | k <- foKinds fo]
      , concat ["--author " <> T.unpack a <> " " | a <- foAuthors fo]
      , concat ["--tag " <> T.unpack k <> "=" <> T.unpack v <> " " | (k, v) <- foTags fo]
      , if waBell o then "--bell " else ""
      ]

-- ═══════════════════════════════════════════════════════════ output

putEvent :: Bool -> POSIXTime -> Bool -> Bool -> Event -> IO ()
putEvent _ _ True _ e = BLC.putStrLn (encode e)
putEvent colour now _ True  e = TIO.putStrLn (renderEventBlock colour now e)
putEvent colour now _ False e = TIO.putStrLn (renderEvent colour now e)
