{-# LANGUAGE OverloadedStrings #-}

-- | Thread view: one root plus its replies, newest last (a thread reads
-- down, a feed reads up). The matching rule — any @e@ tag citing the root —
-- lives here next to the renderer so 'Krivostr.Tui.State' and future views
-- share one definition of "belongs to this thread".
module Krivostr.Tui.Views.Thread
  ( drawThread
  , threadReplies
  ) where

import Brick.Types (Widget)
import Brick.Widgets.Core (str, vBox)
import Data.List (sortOn)
import Data.Set (Set)
import Data.Text (Text)
import Data.Time.Clock.POSIX (POSIXTime)
import Krivostr.Event (Event, evCreatedAt, evTags)
import Krivostr.Nip.Nip36 (isSensitive)
import Krivostr.Tui.Types (Name)
import Krivostr.Tui.Views.Feed (drawRow)

-- | Replies to a root id, oldest first for reading down. Any tag headed
-- @e@ counts — positional and marked alike — because old clients only
-- wrote positional tags and both must thread.
threadReplies :: Text -> [Event] -> [Event]
threadReplies rid = sortOn evCreatedAt . filter cites
  where
    cites e = any isReply (evTags e)
    isReply (t : rest) = t == "e" && rid `elem` rest
    isReply []         = False

-- | Root on top, replies below it. The caller passes root-first (see
-- 'stepEnter'); an empty thread says so rather than rendering blank.
drawThread :: POSIXTime -> Set Text -> Set Text -> [Event] -> Widget Name
drawThread now pending revealed evs = case evs of
  [] -> str "// no replies yet — o fetches missing relatives from relays"
  (root : rest) -> vBox (drawRow now pending revealed False root : map (drawRow now pending revealed False) rest)
