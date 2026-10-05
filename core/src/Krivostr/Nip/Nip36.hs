{-# LANGUAGE OverloadedStrings #-}

-- | NIP-36 sensitive content: the @content-warning@ tag.
--
-- Presence is the signal; the reason is advisory. A tag with no reason still
-- marks the event sensitive -- the author flagged *that* something needs a
-- warning without saying what, and treating a reasonless tag as unmarked
-- would unread exactly the events whose authors were most cautious.
--
-- This module only reads and writes the tag. Whether to hide, blur, or show
-- the content is a display decision in the renderer, which is why the CLI
-- gates it behind @--show-sensitive@ and the UI blurs behind a click.
module Krivostr.Nip.Nip36
  ( warningTagName
  , contentWarningOf
  , isSensitive
  , buildWarningTag
  ) where

import Data.Text (Text)
import Krivostr.Event

-- | The tag name.
warningTagName :: Text
warningTagName = "content-warning"

-- | The warning reason, if the event carries the tag. 'Just ""' means
-- flagged without a reason -- still sensitive, per the module header.
contentWarningOf :: Event -> Maybe Text
contentWarningOf e = case [rest | (t : rest) <- evTags e, t == warningTagName] of
  (r : _) -> Just (firstOrEmpty r)
  _       -> Nothing
  where
    firstOrEmpty (v : _) = v
    firstOrEmpty []      = ""

-- | Does the event carry a content warning?
isSensitive :: Event -> Bool
isSensitive e = case contentWarningOf e of
  Nothing -> False
  Just _  -> True

-- | The tag for marking content sensitive, with an optional reason. An
-- empty reason still emits the bare tag: the flag is the point.
buildWarningTag :: Text -> [Text]
buildWarningTag reason = ["content-warning", reason]
