{-# LANGUAGE OverloadedStrings #-}

-- | Search view: the query line plus FTS results through the shared row
-- renderer. Results borrow the feed widget while the screen is open;
-- leaving restores it (see 'popScreen'). The search itself runs in the App
-- edge (SQLite is IO); this module only draws.
module Krivostr.Tui.Views.Search
  ( drawSearch
  ) where

import Brick.Types (Widget)
import Brick.Widgets.Core (str, txt, vBox)
import Brick.Widgets.List (listElements, renderList)
import qualified Data.Foldable as F
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime)
import Krivostr.Tui.Types (AppState (..), Name)
import Krivostr.Tui.Views.Feed (drawRow)

-- | Query line, match count, results. An empty query is an invitation, not
-- an error; no matches say so with the query echoed.
drawSearch :: POSIXTime -> AppState -> Widget Name
drawSearch now st
  | T.null (T.strip (asSearchQuery st)) =
      vBox [txt ("/" <> asSearchQuery st), str "// type to search the local index"]
  | otherwise =
      vBox
        [ txt ("/" <> asSearchQuery st)
        , str (show matches <> " match(es) for " <> T.unpack (asSearchQuery st))
        , if matches == 0
            then str "// nothing matches — try --any terms or fewer words"
            else renderList (drawRow now (asPending st) (asRevealed st)) True (asList st)
        ]
  where
    matches :: Int
    matches = F.length (listElements (asList st))
