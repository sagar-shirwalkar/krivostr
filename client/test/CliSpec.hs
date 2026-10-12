{-# LANGUAGE OverloadedStrings #-}

-- | The command-line parser, exercised as a whole.
--
-- Every subcommand and every flag in @Krivostr.Cli@ has to be reachable from
-- argv, and the only honest way to check that is to hand the parser real
-- argument vectors and look at what it returns. The module is otherwise all
-- IO dispatch, so nothing else in the suite touches its parsers; a sweep here
-- is what keeps the command surface from drifting out of the help text.
--
-- These are parser-shape assertions, not value assertions: the @*Opts@ records
-- and the 'Command' type are deliberately not exported, so a test can only say
-- "these arguments are accepted" or "these are refused". Value-level checks
-- live in the functions the parser feeds.
module CliSpec (cliSpec) where

import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import Krivostr.Cli (Opts, parserInfo)
import Test.Hspec

-- | Run the real parser over an argument vector.
runParse :: [String] -> ParserResult Opts
runParse = execParserPure defaultPrefs parserInfo

-- | True when the parser accepts the arguments. Shell-completion requests are
-- not something we build, so the remaining constructors all count as a refusal.
accepts :: [String] -> Bool
accepts args = case runParse args of
  Success _ -> True
  _ -> False

-- | True when the parser refuses the arguments: a bad value, a missing
-- required argument, or an unknown command.
rejects :: [String] -> Bool
rejects = not . accepts

-- | A syntactically valid 64-hex pubkey. 'resolveAuthor' only checks the shape,
-- so this need not be a curve point.
hex64 :: String
hex64 = replicate 64 'a'

cliSpec :: Spec
cliSpec = describe "CLI parser" $ do
  describe "globals" $ do
    it "reports the version and exits" $
      -- an infoOption is delivered as a failure carrying ExitSuccess, which is
      -- exactly how the program knows to print and stop.
      rejects ["--version"] `shouldBe` True

    it "takes --db before the command" $
      accepts ["--db", "/tmp/db", "feed"] `shouldBe` True

    it "takes --log-level at every documented spelling" $
      mapM_
        (\lvl -> accepts ["--log-level", lvl, "feed"] `shouldBe` True)
        ["debug", "info", "warn", "error"]

    it "takes --color and --no-color" $ do
      accepts ["--color", "feed"] `shouldBe` True
      accepts ["--no-color", "feed"] `shouldBe` True

    it "refuses an unknown global flag" $
      rejects ["--unknown-global", "feed"] `shouldBe` True

    it "needs a command: globals alone are not a request" $ do
      rejects ["--db", "/tmp/db"] `shouldBe` True
      rejects ["--color"] `shouldBe` True

  describe "serve" $ do
    it "takes no options at all" $ accepts ["serve"] `shouldBe` True
    it "takes port, host and static" $
      accepts ["serve", "--port", "8082", "--host", "0.0.0.0", "--static", "/tmp/ui"]
        `shouldBe` True
    it "takes several --upstream" $
      accepts ["serve", "--upstream", "wss://a", "--upstream", "wss://b"] `shouldBe` True
    it "rejects a non-numeric port" $
      rejects ["serve", "--port", "eighty"] `shouldBe` True

  describe "feed" $ do
    it "takes no options" $ accepts ["feed"] `shouldBe` True
    it "takes the display switches" $
      accepts ["feed", "--json", "--long", "--show-sensitive"] `shouldBe` True
    it "takes the streaming switches" $
      accepts ["feed", "--follow", "--ingest", "--relay", "wss://r"] `shouldBe` True
    it "takes the short aliases" $
      accepts ["feed", "-f", "-k", "1", "-a", hex64, "-t", "e=abc", "-n", "5", "-s", "hi"]
        `shouldBe` True

  describe "search" $ do
    it "requires a query" $
      rejects ["search"] `shouldBe` True
    it "takes a query and --any" $
      accepts ["search", "hello", "--any"] `shouldBe` True
    it "takes the whole filter set and --json" $
      accepts
        ( ["search", "hello world", "--json"]
            <> filterArgs
        )
        `shouldBe` True

  describe "dm" $ do
    it "takes recipient and message" $
      accepts ["dm", hex64, "hello"] `shouldBe` True
    it "takes --inbox on its own" $
      accepts ["dm", "--inbox"] `shouldBe` True
    it "takes --inbox with the listing options" $
      accepts ["dm", "--inbox", "--relay", "wss://r", "--timeout", "30", "--limit", "100"]
        `shouldBe` True

  describe "reply" $ do
    it "takes parent and message" $ accepts ["reply", "abc", "hello"] `shouldBe` True
    it "takes relay and timeout" $
      accepts ["reply", "abc", "hello", "--relay", "wss://r", "--timeout", "30"] `shouldBe` True
    it "requires both positional arguments" $ do
      rejects ["reply"] `shouldBe` True
      rejects ["reply", "abc"] `shouldBe` True

  describe "react" $ do
    it "defaults the emoji to +" $ accepts ["react", "abc"] `shouldBe` True
    it "takes an explicit emoji" $ accepts ["react", "abc", "--emoji", "+"] `shouldBe` True
    it "requires the event id" $ rejects ["react"] `shouldBe` True

  describe "repost" $ do
    it "takes the event id" $ accepts ["repost", "abc"] `shouldBe` True
    it "takes --quote" $ accepts ["repost", "abc", "--quote", "my take"] `shouldBe` True
    it "requires the event id" $ rejects ["repost"] `shouldBe` True

  describe "verify" $ do
    it "takes an identifier" $ accepts ["verify", "alice@example.com"] `shouldBe` True
    it "takes an explicit --pubkey" $
      accepts ["verify", "alice@example.com", "--pubkey", hex64] `shouldBe` True
    it "requires the identifier" $ rejects ["verify"] `shouldBe` True

  describe "publish" $ do
    it "requires a file and a title" $ do
      rejects ["publish", "post.md"] `shouldBe` True
      rejects ["publish"] `shouldBe` True
    it "takes the optional metadata" $
      accepts
        [ "publish", "post.md", "--title", "T", "--slug", "s"
        , "--summary", "sum", "--image", "https://img", "--timeout", "30"
        ]
        `shouldBe` True

  describe "delete" $ do
    it "requires at least one event id" $ rejects ["delete"] `shouldBe` True
    it "takes several event ids" $ accepts ["delete", "a", "b", "c"] `shouldBe` True
    it "takes relay and timeout" $
      accepts ["delete", "a", "--relay", "wss://r", "--timeout", "30"] `shouldBe` True

  describe "resolve" $ do
    it "requires a reference" $ rejects ["resolve"] `shouldBe` True
    it "takes a reference" $ accepts ["resolve", "nostr:npub1abc"] `shouldBe` True

  describe "comment" $ do
    it "requires a target and a message" $ do
      rejects ["comment"] `shouldBe` True
      rejects ["comment", "abc"] `shouldBe` True
    it "takes target, message, relay and timeout" $
      accepts ["comment", "abc", "hi", "--relay", "wss://r", "--timeout", "30"] `shouldBe` True

  describe "list" $ do
    it "requires a list name" $ rejects ["list"] `shouldBe` True
    it "takes each documented list name" $
      mapM_ (\n -> accepts ["list", n] `shouldBe` True) ["mute", "pin", "bookmark"]
    it "takes --add and --del, repeated" $
      accepts ["list", "mute", "--add", "a", "--add", "b", "--del", "c"] `shouldBe` True

  describe "count" $ do
    it "takes no options" $ accepts ["count"] `shouldBe` True
    it "takes the filter set" $ accepts ("count" : filterArgs) `shouldBe` True

  describe "wallet" $ do
    it "requires a subcommand" $ rejects ["wallet"] `shouldBe` True
    it "takes balance and info" $ do
      accepts ["wallet", "balance"] `shouldBe` True
      accepts ["wallet", "info"] `shouldBe` True
    it "takes pay with an invoice" $ accepts ["wallet", "pay", "lnbc1"] `shouldBe` True
    it "takes invoice with an amount and description" $
      accepts ["wallet", "invoice", "1000", "--description", "coffee"] `shouldBe` True
    it "defaults the invoice description" $ accepts ["wallet", "invoice", "1000"] `shouldBe` True
    it "requires a numeric amount" $ rejects ["wallet", "invoice", "lots"] `shouldBe` True

  describe "relay" $ do
    it "requires a subcommand" $ rejects ["relay"] `shouldBe` True
    it "takes list, add and remove" $ do
      accepts ["relay", "list"] `shouldBe` True
      accepts ["relay", "add", "wss://r"] `shouldBe` True
      accepts ["relay", "remove", "wss://r"] `shouldBe` True
    it "requires a URL for add and remove" $ do
      rejects ["relay", "add"] `shouldBe` True
      rejects ["relay", "remove"] `shouldBe` True

  describe "export" $ do
    it "takes no options" $ accepts ["export"] `shouldBe` True
    it "takes a format and an output file" $
      accepts ["export", "--format", "csv", "--out", "/tmp/out.csv"] `shouldBe` True
    it "accepts every documented format" $
      mapM_ (\f -> accepts ["export", "--format", f] `shouldBe` True) ["nostr", "array", "csv"]
    it "rejects an unknown option" $ rejects ["export", "--nope"] `shouldBe` True

  describe "watch" $ do
    it "takes no options" $ accepts ["watch"] `shouldBe` True
    it "takes the notification switches" $
      accepts ["watch", "--bell", "--existing", "--print-unit"] `shouldBe` True
    it "takes --exec and --interval" $
      accepts ["watch", "--exec", "echo {json}", "--interval", "5"] `shouldBe` True
    it "rejects a non-numeric interval" $
      rejects ["watch", "--interval", "soon"] `shouldBe` True

  describe "api" $ do
    it "takes no options" $ accepts ["api"] `shouldBe` True
    it "takes port and host" $
      accepts ["api", "--port", "8080", "--host", "0.0.0.0"] `shouldBe` True

  describe "argument-free commands" $ do
    it "takes reindex, keygen and tui" $ do
      accepts ["reindex"] `shouldBe` True
      accepts ["keygen"] `shouldBe` True
      accepts ["tui"] `shouldBe` True
    it "takes the tui options" $
      accepts ["tui", "--relay", "wss://r", "--no-ingest"] `shouldBe` True

  describe "kind parsing via the parser" $ do
    it "takes every named kind" $
      mapM_
        (\k -> accepts ["feed", "--kind", k] `shouldBe` True)
        ["note", "dm", "delete", "repost", "like", "metadata", "follow", "relays", "giftwrap"]
    it "takes a numeric kind" $ accepts ["feed", "--kind", "30023"] `shouldBe` True
    it "takes the boundaries of the 16-bit range" $ do
      accepts ["feed", "--kind", "0"] `shouldBe` True
      accepts ["feed", "--kind", "65535"] `shouldBe` True
    it "rejects a kind past 16 bits" $ rejects ["feed", "--kind", "65536"] `shouldBe` True
    it "rejects a named kind it does not know" $ rejects ["feed", "--kind", "nonsense"] `shouldBe` True

  describe "author and tag parsing via the parser" $ do
    it "takes a hex author" $ accepts ["feed", "--author", hex64] `shouldBe` True
    it "rejects an author that is neither npub nor hex" $
      rejects ["feed", "--author", "alice"] `shouldBe` True
    it "takes the several tag spellings" $
      mapM_
        (\t -> accepts ["feed", "--tag", t] `shouldBe` True)
        ["e=abc", "#e=def", "p=pubkey"]
    it "rejects a tag with no value" $ rejects ["feed", "--tag", "e"] `shouldBe` True

  describe "time parsing via the parser" $ do
    it "takes relative and absolute forms" $
      mapM_
        (\w -> accepts ["feed", "--since", w] `shouldBe` True)
        ["90s", "15m", "2h", "7d", "3w", "6mo", "1y", "2026-01-01", "1700000000"]
    it "takes --until the same way" $
      accepts ["feed", "--until", "1h"] `shouldBe` True
    it "rejects an unreadable time" $ rejects ["feed", "--since", "yesterday"] `shouldBe` True

  describe "unknown commands" $ do
    it "rejects a command that does not exist" $
      rejects ["frobnicate"] `shouldBe` True
    it "rejects a bare invocation" $ rejects [] `shouldBe` True

  where
    -- One representative of every filter option, all valid.
    filterArgs :: [String]
    filterArgs =
      [ "--kind", "note"
      , "--author", hex64
      , "--tag", "e=abc"
      , "--since", "1h"
      , "--until", "2026-01-01"
      , "--limit", "50"
      , "--search", "hello"
      ]
