{-# LANGUAGE OverloadedStrings #-}

-- | Turning events into lines a human wants to read in a terminal.
--
-- Shared by @feed@, @watch@ and @export@ so that piping one command's output
-- and eyeballing another's look the same.
module Krivostr.Cli.Render
  ( renderEvent
  , renderEventBlock
  , relativeTime
  , shortHex
  , oneLine
  , highlight
  , dim
  , kindColour
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime)
import Krivostr.Event

-- ANSI, hand-rolled: the escape sequences are short and pulling in
-- ansi-terminal for four of them is not worth another dependency.
dim, reset :: Text
dim   = "\ESC[2m"
reset = "\ESC[0m"

-- | Colour for a kind tag. Notes are plain, the interesting kinds are tinted.
kindColour :: Int -> Text
kindColour k
  | k == 4            = "\ESC[35m"  -- magenta: encrypted DM
  | k == 7            = "\ESC[33m"  -- yellow: reaction
  | k `elem` [0, 3, 10002] = "\ESC[36m"  -- cyan: lists and metadata
  | k `elem` [5, 6]  = "\ESC[31m"  -- red: deletion, repost
  | otherwise         = "\ESC[32m"  -- green: ordinary text

highlight :: Text -> Text -> Text
highlight colour t = colour <> t <> reset

-- | @abc…wxyz@, for telling two hex keys apart at a glance.
shortHex :: Int -> Text -> Text
shortHex n t
  | T.length t <= n * 2 + 1 = t
  | otherwise = T.take n t <> "\8230" <> T.dropEnd n t

-- | Collapse to a single line and clip to a column budget.
oneLine :: Int -> Text -> Text
oneLine n = clip n . T.unwords . T.words . T.replace "\r\n" " " . T.replace "\n" " "

clip :: Int -> Text -> Text
clip n t
  | T.length t <= n = t
  | otherwise       = T.take (max 0 (n - 1)) t <> "\8230"

-- | Coarse relative age. Deliberately not a timestamp: a feed line is scanned,
-- not read, and "4h" carries more than "2026-10-03T11:02".
relativeTime :: POSIXTime -> POSIXTime -> Text
relativeTime now then_ =
  let d = max 0 (now - then_)
      secs n = T.pack (show (floor (d / n) :: Integer))
  in if   d < 60        then "now"
     else if d < 3600   then secs 60 <> "m"
     else if d < 86400  then secs 3600 <> "h"
     else if d < 2592000 then secs 86400 <> "d"
     else if d < 31536000 then secs 2592000 <> "mo"
     else secs 31536000 <> "y"

-- | One line per event: age, kind, author, content.
renderEvent :: Bool -> POSIXTime -> Event -> Text
renderEvent colour now e =
  let age  = relativeTime now (evCreatedAt e)
      kind = "#" <> T.pack (show (evKind e))
      who  = shortHex 8 (evPubkey e)
      body = oneLine 100 (evContent e)
      plain = T.concat
        [ padRight 6 age, " ", padRight 7 kind, " ", padRight 17 who, "  ", body ]
  in if colour
       then T.concat
         [ dim <> age <> reset
         , " ", kindColour (evKind e) <> padRight 7 kind <> reset
         , " ", "\ESC[36m" <> padRight 17 who <> reset
         , "  ", body ]
       else plain

-- | A multi-line rendering that keeps the content's own line breaks, for
-- @--long@ and for notifications.
renderEventBlock :: Bool -> POSIXTime -> Event -> Text
renderEventBlock colour now e =
  let header = renderEvent colour now e
      body   = T.unlines (map ("    " <>) (T.lines (T.replace "\t" "  " (evContent e))))
      tags   = if null (evTags e) then "" else
                  "    " <> dim <> T.intercalate " " (map renderTag (evTags e))
                  <> if colour then reset else ""
  in header <> "\n" <> body <> tags
  where
    renderTag t = "#" <> T.unwords (filter (not . T.null) t)

padRight :: Int -> Text -> Text
padRight n t = t <> T.replicate (max 0 (n - T.length t)) " "
