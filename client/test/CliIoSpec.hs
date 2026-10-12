{-# LANGUAGE OverloadedStrings #-}

-- | Integration coverage for the CLI's IO half.
--
-- "CliSpec" exercises the parser; this drives real subcommands through
-- @runCLIWith@ against a seeded temp store (or an empty one) and asserts on
-- the captured stdout/stderr and exit code. Every command here is finite and
-- offline: the streaming verbs (@serve@, @api@, @tui@, @feed --follow@,
-- @watch@) are deliberately absent, and the send verbs are driven only as far
-- as a missing key, a missing event, or an unusable argument, which dies
-- before any relay is dialled.
module CliIoSpec (cliIoSpec) where

import Test.Hspec

import Control.Exception (bracket, evaluate, finally, try)
import Control.Monad (forM_, void)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hClose, hFlush, openFile, stderr, stdout)
import System.IO.Temp (withSystemTempDirectory)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)

import Krivostr.Cli (runCLIWith)
import Krivostr.Cli.Nostr (defaultRelays)
import Krivostr.Event (Event (..))
import Krivostr.Key
  (PrivateKey, derivePublicKey, exportNpub, exportNsec, generatePrivateKey, pubKeyHex)
import Krivostr.Logging (LogLevel (..), newLogger)
import Krivostr.Nip.Nip01 (signEvent)
import Krivostr.Nip.Nip19 (AddrPointer (..), encodeNaddr)
import Krivostr.Store (closeStore, insertEvent, openStore)

-- ── fixtures ───────────────────────────────────────────────────

mkSigned :: PrivateKey -> Int -> T.Text -> Event
mkSigned sk kind content = signEvent sk Event
  { evId = ""
  , evPubkey = ""
  , evCreatedAt = 1700000000 + fromIntegral kind
  , evKind = kind
  , evTags = []
  , evContent = content
  , evSig = ""
  }

-- | Run a body against a fresh on-disk store path whose parent exists.
withDb :: (FilePath -> IO a) -> IO a
withDb act = withSystemTempDirectory "krivostr-db" $ \dir ->
  act (dir </> "events.db")

seed :: FilePath -> [Event] -> IO ()
seed db evs = do
  lg <- newLogger Error
  st <- openStore lg db
  forM_ evs $ \e -> void (insertEvent st e)
  closeStore st

-- ── harness ────────────────────────────────────────────────────

-- | Run a command with an explicit argv, capturing stdout and stderr into
-- files. Reading those files back forces the output, so lazy printing cannot
-- leave a code path unevaluated. Catches the @ExitCode@ that @die@ and
-- @handleParseResult@ raise, the way a shell would observe it.
runCli :: [String] -> IO (Either ExitCode (), T.Text, T.Text)
runCli args = withSystemTempDirectory "krivostr-cli" $ \dir -> do
  let outP = dir </> "out"
      errP = dir </> "err"
  hFlush stdout
  hFlush stderr
  outH <- openFile outP WriteMode
  errH <- openFile errP WriteMode
  oldOut <- hDuplicate stdout
  oldErr <- hDuplicate stderr
  hDuplicateTo outH stdout
  hDuplicateTo errH stderr
  res <- (try (runCLIWith args) `finally` restore oldOut oldErr)
           :: IO (Either ExitCode ())
  hClose outH
  hClose errH
  out <- TIO.readFile outP
  err <- TIO.readFile errP
  evaluate (T.length out + T.length err)
  pure (res, out, err)
  where
    restore oldOut oldErr = do
      hFlush stdout
      hFlush stderr
      hDuplicateTo oldOut stdout
      hDuplicateTo oldErr stderr
      hClose oldOut
      hClose oldErr

-- | @handleParseResult@ answers @--help@ and @--version@ by throwing
-- @ExitSuccess@, so both a normal return and that code count as success.
isOk :: Either ExitCode () -> Bool
isOk (Right ())         = True
isOk (Left ExitSuccess) = True
isOk _                  = False

isFailure :: Either ExitCode () -> Bool
isFailure (Left (ExitFailure _)) = True
isFailure _                      = False

expectOk :: [String] -> IO (T.Text, T.Text)
expectOk args = do
  (res, out, err) <- runCli args
  if isOk res
    then pure (out, err)
    else expectationFailure ("expected success for " <> show args <> ", got " <> show res)
           >> pure (out, err)

expectFail :: [String] -> IO (T.Text, T.Text)
expectFail args = do
  (res, out, err) <- runCli args
  res `shouldSatisfy` isFailure
  pure (out, err)

-- | Set an env var for the body, restoring the previous state afterwards.
withEnv :: String -> String -> IO a -> IO a
withEnv k v act = bracket
  (do old <- lookupEnv k; setEnv k v; pure old)
  (\old -> maybe (unsetEnv k) (setEnv k) old)
  (const act)

-- | Clear an env var for the body, restoring the previous state afterwards.
withoutEnv :: String -> IO a -> IO a
withoutEnv k act = bracket
  (do old <- lookupEnv k; unsetEnv k; pure old)
  (\old -> maybe (unsetEnv k) (setEnv k) old)
  (const act)

-- ── tests ──────────────────────────────────────────────────────

cliIoSpec :: Spec
cliIoSpec = describe "Cli IO" $ do

  describe "parsing seam" $ do
    it "runs a subcommand and returns normally" $ do
      withDb $ \db -> do
        (out, _) <- expectOk ["--db", db, "keygen"]
        -- The parse seam handed a real command to dispatch.
        out `shouldSatisfy` T.isInfixOf "nsec: nsec1"

    it "exits non-zero on an unknown command" $ do
      (_, err) <- expectFail ["definitely-not-a-command"]
      err `shouldSatisfy` (not . T.null)

    it "answers --help with a usage block and success" $ do
      (out, _) <- expectOk ["--help"]
      out `shouldSatisfy` T.isInfixOf "krivostr"

    it "answers --version with the version string and success" $ do
      (out, _) <- expectOk ["--version"]
      out `shouldSatisfy` T.isInfixOf "krivostr 0.7.4.0"

  describe "keygen" $ do
    it "prints an nsec and its npub" $ do
      withDb $ \db -> do
        (out, _) <- expectOk ["--db", db, "keygen"]
        out `shouldSatisfy` T.isInfixOf "nsec: nsec1"
        out `shouldSatisfy` T.isInfixOf "npub: npub1"

  describe "db and log resolution" $ do
    it "reads the database path from KRIVOSTR_DB" $ do
      withDb $ \db ->
        withEnv "KRIVOSTR_DB" db $ do
          (out, _) <- expectOk ["count"]
          T.strip out `shouldBe` "0"

    it "accepts an explicit log level and a bad env level falls back to info" $ do
      withDb $ \db -> do
        _ <- expectOk ["--db", db, "--log-level", "debug", "count"]
        withEnv "KRIVOSTR_LOG_LEVEL" "warn" $ void (expectOk ["--db", db, "count"])
        withEnv "KRIVOSTR_LOG_LEVEL" "not-a-level" $ void (expectOk ["--db", db, "count"])

    it "forces colour on, off, and detects a non-tty as off" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        seed db [mkSigned sk 1 "colour me"]
        (colourOut, _) <- expectOk ["--db", db, "--color", "feed"]
        colourOut `shouldSatisfy` T.isInfixOf "\ESC["
        (plainOut, _) <- expectOk ["--db", db, "--no-color", "feed"]
        plainOut `shouldSatisfy` (not . T.isInfixOf "\ESC[")
        (autoOut, _) <- expectOk ["--db", db, "feed"]
        autoOut `shouldSatisfy` (not . T.isInfixOf "\ESC[")

  describe "count" $ do
    it "counts everything and honours --kind" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        seed db [mkSigned sk 1 "one", mkSigned sk 7 "two"]
        (allOut, _) <- expectOk ["--db", db, "count"]
        T.strip allOut `shouldBe` "2"
        (oneOut, _) <- expectOk ["--db", db, "count", "--kind", "1"]
        T.strip oneOut `shouldBe` "1"

  describe "reindex" $ do
    it "rebuilds the search index and reports the count" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        seed db [mkSigned sk 1 "alpha", mkSigned sk 7 "beta"]
        (out, _) <- expectOk ["--db", db, "reindex"]
        out `shouldSatisfy` T.isInfixOf "indexed 2 events"

  describe "feed" $ do
    it "says the store is empty when nothing is stored" $ do
      withDb $ \db -> do
        (_, err) <- expectOk ["--db", db, "feed"]
        err `shouldSatisfy` T.isInfixOf "store is empty"

    it "says no events matched when the filter excludes everything" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        seed db [mkSigned sk 1 "only a note"]
        (_, err) <- expectOk ["--db", db, "feed", "--kind", "7"]
        err `shouldSatisfy` T.isInfixOf "no events matched"

    it "prints JSON and long forms of stored events" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        seed db [mkSigned sk 1 "hello feed"]
        (jsonOut, _) <- expectOk ["--db", db, "feed", "--json"]
        jsonOut `shouldSatisfy` T.isInfixOf "hello feed"
        (longOut, _) <- expectOk ["--db", db, "feed", "--long"]
        longOut `shouldSatisfy` T.isInfixOf "hello feed"

  describe "search" $ do
    it "finds stored text and reports the match count" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        seed db [mkSigned sk 1 "the quick brown fox"]
        (out, err) <- expectOk ["--db", db, "search", "brown"]
        out `shouldSatisfy` T.isInfixOf "the quick brown fox"
        err `shouldSatisfy` T.isInfixOf "match(es)"

  describe "export" $ do
    it "emits ndjson by default and array on request" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        seed db [mkSigned sk 1 "export me"]
        (ndjson, _) <- expectOk ["--db", db, "export"]
        ndjson `shouldSatisfy` T.isInfixOf "export me"
        (array, _) <- expectOk ["--db", db, "export", "--format", "array"]
        T.strip array `shouldSatisfy` T.isPrefixOf "["

    it "renders csv with a header row" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        seed db [mkSigned sk 1 "csv me"]
        (out, _) <- expectOk ["--db", db, "export", "--format", "csv"]
        out `shouldSatisfy` T.isInfixOf "id,pubkey,created_at,kind,tags,content,sig"

    it "refuses an unknown format" $ do
      withDb $ \db -> do
        (_, err) <- expectFail ["--db", db, "export", "--format", "bogus"]
        err `shouldSatisfy` T.isInfixOf "unknown --format"

    it "writes to --out instead of stdout" $ do
      withDb $ \db ->
        withSystemTempDirectory "krivostr-out" $ \dir -> do
          sk <- generatePrivateKey
          seed db [mkSigned sk 1 "to a file"]
          let file = dir </> "dump.ndjson"
          (out, err) <- expectOk ["--db", db, "export", "--out", file]
          out `shouldBe` ""
          err `shouldSatisfy` T.isInfixOf "exported 1 events"
          body <- TIO.readFile file
          body `shouldSatisfy` T.isInfixOf "to a file"

  describe "relay" $ do
    it "lists compiled-in defaults when nothing is configured" $ do
      withDb $ \db -> do
        (out, err) <- expectOk ["--db", db, "relay", "list"]
        err `shouldSatisfy` T.isInfixOf "no configured relays"
        forM_ defaultRelays $ \r -> out `shouldSatisfy` T.isInfixOf r

    it "adds a valid URL and rejects a bad one" $ do
      withDb $ \db -> do
        (added, _) <- expectOk ["--db", db, "relay", "add", "wss://a.example"]
        added `shouldSatisfy` T.isInfixOf "remembered wss://a.example"
        (listed, _) <- expectOk ["--db", db, "relay", "list"]
        listed `shouldSatisfy` T.isInfixOf "wss://a.example"
        (_, err) <- expectFail ["--db", db, "relay", "add", "http://a.example"]
        err `shouldSatisfy` T.isInfixOf "not a relay URL"

    it "forgets a relay" $ do
      withDb $ \db -> do
        _ <- expectOk ["--db", db, "relay", "add", "wss://a.example"]
        (out, _) <- expectOk ["--db", db, "relay", "remove", "wss://a.example"]
        out `shouldSatisfy` T.isInfixOf "forgot wss://a.example"

  describe "resolve" $ do
    it "resolves a hex pubkey to an author line" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        let hex = T.unpack (pubKeyHex (derivePublicKey sk))
        (out, _) <- expectOk ["--db", db, "resolve", hex]
        out `shouldSatisfy` T.isInfixOf ("author " <> T.pack hex)

    it "resolves a stored event id to its block" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        let e = mkSigned sk 1 "resolve this"
        seed db [e]
        (out, _) <- expectOk ["--db", db, "resolve", T.unpack (evId e)]
        out `shouldSatisfy` T.isInfixOf "resolve this"

    it "resolves a nostr: npub reference" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        let pk = derivePublicKey sk
            hex = T.unpack (pubKeyHex pk)
        (out, _) <- expectOk ["--db", db, "resolve", "nostr:" <> T.unpack (exportNpub pk)]
        out `shouldSatisfy` T.isInfixOf ("author " <> T.pack hex)

    it "resolves a nostr: naddr for a stored article" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        let art = signEvent sk Event
              { evId = "", evPubkey = "", evCreatedAt = 1700000000, evKind = 30023
              , evTags = [["d", "hello"]], evContent = "article body", evSig = "" }
            addr = AddrPointer
              { apIdentifier = "hello"
              , apAuthor = pubKeyHex (derivePublicKey sk)
              , apKind = 30023
              , apRelays = []
              }
        seed db [art]
        case encodeNaddr addr of
          Left e -> expectationFailure e
          Right naddr -> do
            (out, _) <- expectOk ["--db", db, "resolve", "nostr:" <> T.unpack naddr]
            out `shouldSatisfy` T.isInfixOf "article body"

    it "says an naddr is not in the store when nothing matches" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        let addr = AddrPointer
              { apIdentifier = "missing"
              , apAuthor = pubKeyHex (derivePublicKey sk)
              , apKind = 30023
              , apRelays = [] }
        case encodeNaddr addr of
          Left e -> expectationFailure e
          Right naddr -> do
            (out, _) <- expectOk ["--db", db, "resolve", "nostr:" <> T.unpack naddr]
            out `shouldSatisfy` T.isInfixOf "not in the local store"

    it "rejects something that is not a reference" $ do
      withDb $ \db -> do
        (_, err) <- expectFail ["--db", db, "resolve", "not-a-reference"]
        err `shouldSatisfy` T.isInfixOf "is not a nostr: reference"

  describe "dm" $ do
    it "reports an empty inbox" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        withEnv "KRIVOSTR_NSEC" (T.unpack (exportNsec sk)) $ do
          (_, err) <- expectOk ["--db", db, "dm", "--inbox"]
          err `shouldSatisfy` T.isInfixOf "no DMs addressed to you"

    it "dies with usage when given neither message nor --inbox" $ do
      withDb $ \db -> do
        (_, err) <- expectFail ["--db", db, "dm"]
        err `shouldSatisfy` T.isInfixOf "usage: krivostr dm"

  describe "list" $ do
    it "shows an empty mute list without output" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        withEnv "KRIVOSTR_NSEC" (T.unpack (exportNsec sk)) $ do
          (out, _) <- expectOk ["--db", db, "list", "mute"]
          out `shouldBe` ""

    it "rejects an unknown list name" $ do
      withDb $ \db -> do
        (_, err) <- expectFail ["--db", db, "list", "bogus"]
        err `shouldSatisfy` T.isInfixOf "unknown list"

  describe "watch --print-unit" $ do
    it "renders a systemd unit carrying the filter" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        let hex = T.unpack (pubKeyHex (derivePublicKey sk))
        (out, _) <- expectOk
          [ "--db", db, "watch", "--print-unit"
          , "--kind", "1", "--author", hex, "--tag", "e=abc", "--bell" ]
        out `shouldSatisfy` T.isInfixOf "[Service]"
        out `shouldSatisfy` T.isInfixOf "ExecStart=krivostr --db"
        out `shouldSatisfy` T.isInfixOf "watch --kind 1"
        out `shouldSatisfy` T.isInfixOf ("--author " <> T.pack hex)
        out `shouldSatisfy` T.isInfixOf "--tag e=abc"
        out `shouldSatisfy` T.isInfixOf "--bell"

  describe "wallet" $ do
    it "explains a missing wallet connection" $ do
      withDb $ \db ->
        withoutEnv "KRIVOSTR_NWC" $ do
          (_, err) <- expectFail ["--db", db, "wallet", "balance"]
          err `shouldSatisfy` T.isInfixOf "no wallet"

    it "rejects an unparseable KRIVOSTR_NWC" $ do
      withDb $ \db ->
        withEnv "KRIVOSTR_NWC" "not-a-wallet-uri" $ do
          (_, err) <- expectFail ["--db", db, "wallet", "info"]
          err `shouldSatisfy` (not . T.null)

  describe "send verbs stop before the network" $ do
    it "reply without a key dies for the missing key" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        let eid = T.unpack (evId (mkSigned sk 1 "parent"))
        withoutEnv "KRIVOSTR_NSEC" $ do
          (_, err) <- expectFail ["--db", db, "reply", eid, "hi"]
          err `shouldSatisfy` T.isInfixOf "no secret key"

    it "reply to an event not in the store dies for the missing event" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        let eid = T.unpack (evId (mkSigned sk 1 "absent"))
        withEnv "KRIVOSTR_NSEC" (T.unpack (exportNsec sk)) $ do
          (_, err) <- expectFail ["--db", db, "reply", eid, "hi"]
          err `shouldSatisfy` T.isInfixOf "no event"

    it "react, repost and delete reject an event that is not stored" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        let eid = T.unpack (evId (mkSigned sk 1 "absent"))
        withEnv "KRIVOSTR_NSEC" (T.unpack (exportNsec sk)) $ do
          (_, reactErr) <- expectFail ["--db", db, "react", eid]
          reactErr `shouldSatisfy` T.isInfixOf "no event"
          (_, repostErr) <- expectFail ["--db", db, "repost", eid]
          repostErr `shouldSatisfy` T.isInfixOf "no event"
          (_, deleteErr) <- expectFail ["--db", db, "delete", eid]
          deleteErr `shouldSatisfy` T.isInfixOf "no event"

    it "comment refuses a kind 1 note" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        let e = mkSigned sk 1 "a note"
        seed db [e]
        withEnv "KRIVOSTR_NSEC" (T.unpack (exportNsec sk)) $ do
          (_, err) <- expectFail ["--db", db, "comment", T.unpack (evId e), "hi"]
          err `shouldSatisfy` T.isInfixOf "kind 1 note"

    it "comment on an address nothing is stored at" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        withEnv "KRIVOSTR_NSEC" (T.unpack (exportNsec sk)) $ do
          (_, err) <- expectFail ["--db", db, "comment", "30023:deadbeef:slug", "hi"]
          err `shouldSatisfy` T.isInfixOf "nothing at that address"

    it "comment on a malformed target" $ do
      withDb $ \db -> do
        sk <- generatePrivateKey
        withEnv "KRIVOSTR_NSEC" (T.unpack (exportNsec sk)) $ do
          (_, err) <- expectFail ["--db", db, "comment", "notanaddress", "hi"]
          err `shouldSatisfy` T.isInfixOf "target must be"

    it "publish refuses an empty file" $ do
      withDb $ \db ->
        withSystemTempDirectory "krivostr-pub" $ \dir -> do
          sk <- generatePrivateKey
          let file = dir </> "empty.md"
          writeFile file ""
          withEnv "KRIVOSTR_NSEC" (T.unpack (exportNsec sk)) $ do
            (_, err) <- expectFail ["--db", db, "publish", file, "--title", "T"]
            err `shouldSatisfy` T.isInfixOf "empty article"

    it "publish needs a slug or a title" $ do
      withDb $ \db ->
        withSystemTempDirectory "krivostr-pub" $ \dir -> do
          sk <- generatePrivateKey
          let file = dir </> "body.md"
          writeFile file "# hello\n"
          withEnv "KRIVOSTR_NSEC" (T.unpack (exportNsec sk)) $ do
            (_, err) <- expectFail ["--db", db, "publish", file, "--title", ""]
            err `shouldSatisfy` T.isInfixOf "no slug"

  describe "verify" $ do
    it "needs the key when no --pubkey is given" $ do
      withDb $ \db ->
        withoutEnv "KRIVOSTR_NSEC" $ do
          (_, err) <- expectFail ["--db", db, "verify", "alice@example.com"]
          err `shouldSatisfy` T.isInfixOf "no secret key"

    it "rejects an unusable --pubkey" $ do
      withDb $ \db -> do
        (_, err) <- expectFail ["--db", db, "verify", "alice@example.com", "--pubkey", "notakey"]
        err `shouldSatisfy` (not . T.null)
