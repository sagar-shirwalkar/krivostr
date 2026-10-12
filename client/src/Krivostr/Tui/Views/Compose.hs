{-# LANGUAGE OverloadedStrings #-}

-- | Compose view: a target line saying what will be sent, then the multiline
-- editor. The target line shows the tag structure before signing (NIP-10/22
-- structure visible), matching the design doc's honesty rule for sends.
module Krivostr.Tui.Views.Compose
  ( drawCompose
  , targetLine
  ) where

import Brick.Types (Widget)
import Brick.Widgets.Core (txt, vBox)
import Brick.Widgets.Edit (Editor, renderEditor)
import Data.Text (Text)
import qualified Data.Text as T
import Krivostr.Tui.Types (AppState (..), ComposeTarget (..), Name)

-- | What this compose will send, in one line. Pure so the tag preview is
-- pinned by tests, not eyeballs.
targetLine :: ComposeTarget -> Text
targetLine CTNote        = "note"
targetLine (CTReply eid)   = "reply → e:" <> shortId eid
targetLine (CTReact eid)   = "react → e:" <> shortId eid
targetLine (CTQuote eid)   = "quote → q:" <> shortId eid
targetLine (CTComment eid) = "comment → E:" <> shortId eid
targetLine (CTDm hex)      = "dm → p:" <> shortId hex

-- | First eight hex characters: enough to recognize, short enough to scan.
shortId :: Text -> Text
shortId = T.take 8

-- | Target line, editor, and the send/cancel hints. Cursor handling lives in
-- the App (showCursorNamed on this screen).
drawCompose :: AppState -> ComposeTarget -> Editor Text Name -> Widget Name
drawCompose _st target ed = vBox
  [ txt (targetLine target)
  , renderEditor (txt . T.unlines) True ed
  , txt "Ctrl-G send · E $EDITOR · Esc cancel"
  ]
