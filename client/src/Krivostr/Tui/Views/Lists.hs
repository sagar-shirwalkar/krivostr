{-# LANGUAGE OverloadedStrings #-}

-- | Lists view: mute / pin / bookmark tabs from the model. Read-only in M2
-- (the `m` shortcut and a future editor mutate through workers); the tabs
-- show what muting filters on, so the state is inspectable.
module Krivostr.Tui.Views.Lists
  ( drawLists
  , tabName
  ) where

import Brick.Types (Widget)
import Brick.Widgets.Core (str, txt, vBox)
import qualified Data.Set as Set
import Data.Text (Text)
import Krivostr.Tui.Types (AppState (..), Name)

-- | Tab index to name. Tab 0 is mutes — the list the feed filters on.
tabName :: Int -> Text
tabName 0 = "mute"
tabName 1 = "pin"
tabName _ = "bookmark"

-- | Entries of the focused tab, one per line, with a header naming all
-- three. An empty tab says so; mute is first because it is the working list.
drawLists :: AppState -> Widget Name
drawLists st = vBox (header : rows)
  where
    header = txt ("lists: " <> tabName (asListTab st))
    entries :: [Text]
    entries = case asListTab st of
      0 -> Set.toList (asMuted st)
      1 -> Set.toList (asPins st)
      _ -> Set.toList (asBookmarks st)
    rows
      | null entries = [str "// empty — m mutes the focused author"]
      | otherwise = map txt entries
