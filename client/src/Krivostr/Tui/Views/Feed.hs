{-# LANGUAGE OverloadedStrings #-}

-- | Feed view: the default screen. Rows reuse the CLI's conventions (@age
-- @#kind @abcd…wxyz @content@, one line, sanitized, clipped) so piping
-- @feed@ output and eyeballing the TUI look the same. M0 renders the model;
-- selection movement, reveals, and kind colours land in M1/M4.
module Krivostr.Tui.Views.Feed
  ( drawFeed
  , drawRow
  , rowText
  ) where

import Brick.Types (Widget)
import Brick.Widgets.Core (str, txt)
import Brick.Widgets.List (renderList)
import Data.Foldable (toList)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime)
import Krivostr.Cli.Render (oneLine, relativeTime, shortHex)
import Krivostr.Event (Event, evContent, evCreatedAt, evId, evKind, evPubkey)
import Krivostr.Nip.Nip36 (isSensitive)
import Krivostr.Tui.Sanitize (stripAnsiAndC0)
import Krivostr.Tui.Types (AppState (..), Name)

-- | The feed: rows newest-first, or the empty state when the store has
-- nothing for the filter yet. Muted authors are filtered at the model level
-- (see 'Krivostr.Tui.State.pushEvent' and 'purgeMutedAuthor').
drawFeed :: POSIXTime -> AppState -> Widget Name
drawFeed now st = case toList (asFeed st) of
  [] -> str "// no events yet — fill the store with feed --follow --ingest"
  _  -> renderList (drawRow now (asPending st) (asRevealed st)) True (asList st)

-- | One row. Sanitized before clipping (never the reverse: an escape could
-- hide past the clip point), content clipped to a column budget. Width-aware
-- clipping (vty text width, not characters) is an M4 refinement — see the
-- design doc's wide-char risk.
drawRow :: POSIXTime -> Set Text -> Set Text -> Bool -> Event -> Widget Name
drawRow now pending revealed _selected e = txt (rowText now pending revealed e)

-- | The row as text: @age  #kind  abcd…wxyz  content@, plus a pending
-- marker while a publish is in flight. The marker is its own segment so
-- clipping the content can never eat it. Pure so the format is pinned by
-- tests, not eyeballs. Sensitive content is hidden unless revealed.
rowText :: POSIXTime -> Set Text -> Set Text -> Event -> Text
rowText now pending revealed e = T.intercalate "  " (base <> [mark | Set.member (evId e) pending])
  where
    base =
      [ relativeTime now (evCreatedAt e)
      , "#" <> T.pack (show (evKind e))
      , shortHex 8 (evPubkey e)
      , bodyText
      ]
    mark = "[sending]"
    bodyText
      | isSensitive e && not (Set.member (evId e) revealed) = "[hidden — content-warning]"
      | otherwise = oneLine 80 (stripAnsiAndC0 (evContent e))
