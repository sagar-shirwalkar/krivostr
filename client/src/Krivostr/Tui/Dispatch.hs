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
data Command
  = CmdQuit
  | CmdRelays
  | CmdLists
  | CmdOutbox
  | CmdDm
  | CmdHelp
  | CmdUnknown Text
  deriving (Show, Eq)

-- | Parse a command-line buffer (without the leading ':'). Total: empty and
-- unrecognized lines are 'CmdUnknown', which 'applyCommand' logs.
parseCommand :: Text -> Command
parseCommand raw = case T.words (T.strip raw) of
  []            -> CmdUnknown raw
  ("q" : _)     -> CmdQuit
  ("quit" : _)  -> CmdQuit
  ("relays" : _) -> CmdRelays
  ("lists" : _)  -> CmdLists
  ("outbox" : _) -> CmdOutbox
  ("dm" : _)     -> CmdDm
  ("help" : _)   -> CmdHelp
  _             -> CmdUnknown raw

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
  ]
