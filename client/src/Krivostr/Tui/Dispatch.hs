{-# LANGUAGE OverloadedStrings #-}

-- | The ':' command bar: a total parser from line to 'Command' plus the
-- commands the dispatcher will run. M0 covers @:q@uit and unknown input;
-- every row of the parity table grows this ADT in M3, and the Help view
-- renders from it so help cannot drift from the parser.
module Krivostr.Tui.Dispatch
  ( Command (..)
  , parseCommand
  , commandHelp
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Every ':' line the TUI understands. Unknown input stays a value
-- ('CmdUnknown'), never a parse failure — the bar must not crash on typos.
-- Commands that need IO carry their arguments; 'Krivostr.Tui.State.applyCommand'
-- handles the pure part and the App edge runs the rest through the backend.
data Command
  = CmdQuit
  | CmdRelays
  | CmdLists
  | CmdOutbox
  | CmdDm
  | CmdHelp
  | CmdSearch Text
  | CmdCount (Maybe Text)
  | CmdResolve Text
  | CmdVerify Text (Maybe Text)
  | CmdLimit Int
  | CmdPublish Text (Maybe Text)
  | CmdIngest (Maybe Bool)
  | CmdUnknown Text
  deriving (Show, Eq)

-- | Parse a command-line buffer (without the leading ':'). Total: empty and
-- unrecognized lines are 'CmdUnknown'. A recognised verb whose required
-- argument is missing also stays 'CmdUnknown', so the bar reports the line
-- rather than guessing.
parseCommand :: Text -> Command
parseCommand raw = case T.words (T.strip raw) of
  []        -> CmdUnknown raw
  (w : rest) -> case w of
    "q"      -> CmdQuit
    "quit"   -> CmdQuit
    "relays" -> CmdRelays
    "lists"  -> CmdLists
    "outbox" -> CmdOutbox
    "dm"     -> CmdDm
    "help"   -> CmdHelp
    "search" | not (null rest) -> CmdSearch (T.unwords rest)
    "count"  -> CmdCount (listToMaybe rest)
    "resolve" -> case rest of
      (r : _) -> CmdResolve r
      []      -> CmdUnknown raw
    "verify" -> case rest of
      (ident : pk : _) -> CmdVerify ident (Just pk)
      [ident]          -> CmdVerify ident Nothing
      []               -> CmdUnknown raw
    "limit" -> case rest of
      (n : _) | Just v <- readMaybeInt n -> CmdLimit v
      _                                  -> CmdUnknown raw
    "publish" -> case rest of
      (f : ts) -> CmdPublish f (if null ts then Nothing else Just (T.unwords ts))
      []       -> CmdUnknown raw
    "ingest" -> case rest of
      []      -> CmdIngest Nothing
      ["on"]  -> CmdIngest (Just True)
      ["off"] -> CmdIngest (Just False)
      _       -> CmdUnknown raw
    _ -> CmdUnknown raw

listToMaybe :: [a] -> Maybe a
listToMaybe []      = Nothing
listToMaybe (x : _) = Just x

readMaybeInt :: Text -> Maybe Int
readMaybeInt t = case reads (T.unpack (T.strip t)) of
  [(n, "")] -> Just n
  _         -> Nothing

-- | One help line per command, rendered by the Help view. Written next to
-- the parser branches above on purpose: adding a command without its line
-- should feel wrong.
commandHelp :: [(Text, Text)]
commandHelp =
  [ (":q, :quit", "leave the TUI")
  , (":relays", "show relays view")
  , (":lists", "show mute/pin/bookmark lists view")
  , (":outbox", "show outbox view")
  , (":dm", "show DM view")
  , (":help", "show help view")
  , (":search QUERY", "full-text search the store")
  , (":count [KIND]", "count stored events, optionally of one kind")
  , (":resolve REF", "resolve a nostr: reference and open it")
  , (":verify IDENT [KEY]", "check a NIP-05 identifier against its domain")
  , (":limit N", "load the newest N stored events into the feed")
  , (":publish FILE [TITLE]", "publish a Markdown file as a long-form article")
  , (":ingest [on|off]", "toggle live relay ingest")
  ]
