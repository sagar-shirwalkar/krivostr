{-# LANGUAGE OverloadedStrings #-}

-- | TUI theme: attribute names mapping to brick's rendering layer.
-- Mirrors 'Krivostr.Cli.Render.kindColour' semantics but uses 'AttrName'
-- for the widget layer.
module Krivostr.Tui.Theme
  ( kindAttr
  , selectedAttr
  , sensitiveAttr
  , pendingAttr
  , themeAttrMap
  ) where

import Brick.AttrMap (attrMap, AttrMap, AttrName, attrName)
import qualified Graphics.Vty.Attributes as Vty

-- | Attribute for a kind tag. Notes (1) are default; other kinds
-- get distinct colours matching the CLI's kindColour:
--   4 -> magenta (encrypted DM)
--   7 -> yellow  (reaction)
--   0, 3, 10002 -> cyan (lists, metadata)
--   5, 6 -> red (deletion, repost)
--   otherwise -> green (ordinary text)
kindAttr :: Int -> AttrName
kindAttr k
  | k == 4            = attrName "kind-dm"
  | k == 7            = attrName "kind-reaction"
  | k `elem` [0, 3, 10002] = attrName "kind-meta"
  | k `elem` [5, 6]  = attrName "kind-delete"
  | otherwise         = attrName "kind-note"

-- | Attribute for the currently selected row.
selectedAttr :: AttrName
selectedAttr = attrName "selected"

-- | Attribute for sensitive (NIP-36 content-warning) content.
sensitiveAttr :: AttrName
sensitiveAttr = attrName "sensitive"

-- | Attribute for pending publish marker.
pendingAttr :: AttrName
pendingAttr = attrName "pending"

-- | The complete theme attribute map. Colours chosen to be readable
-- on both light and dark terminals (using Vty's default colour palette).
themeAttrMap :: AttrMap
themeAttrMap = attrMap Vty.defAttr
  [ (kindAttr 1,     Vty.defAttr `Vty.withForeColor` Vty.green `Vty.withBackColor` Vty.brightBlack)
  , (kindAttr 4,     Vty.defAttr `Vty.withForeColor` Vty.magenta `Vty.withBackColor` Vty.brightBlack)
  , (kindAttr 7,     Vty.defAttr `Vty.withForeColor` Vty.yellow `Vty.withBackColor` Vty.brightBlack)
  , (kindAttr 0,     Vty.defAttr `Vty.withForeColor` Vty.cyan `Vty.withBackColor` Vty.brightBlack)
  , (kindAttr 3,     Vty.defAttr `Vty.withForeColor` Vty.cyan `Vty.withBackColor` Vty.brightBlack)
  , (kindAttr 10002, Vty.defAttr `Vty.withForeColor` Vty.cyan `Vty.withBackColor` Vty.brightBlack)
  , (kindAttr 5,     Vty.defAttr `Vty.withForeColor` Vty.red `Vty.withBackColor` Vty.brightBlack)
  , (kindAttr 6,     Vty.defAttr `Vty.withForeColor` Vty.red `Vty.withBackColor` Vty.brightBlack)
  , (selectedAttr,   Vty.defAttr `Vty.withForeColor` Vty.brightWhite `Vty.withBackColor` Vty.brightBlue)
  , (sensitiveAttr,  Vty.defAttr `Vty.withForeColor` Vty.brightYellow `Vty.withBackColor` Vty.brightBlack)
  , (pendingAttr,    Vty.defAttr `Vty.withForeColor` Vty.brightRed `Vty.withBackColor` Vty.brightBlack)
  ]