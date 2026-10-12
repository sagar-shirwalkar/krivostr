{-# LANGUAGE OverloadedStrings #-}

-- | Terminal safety: attacker-controlled text in, displayable text out.
--
-- Event content, NOTICE/CLOSED strings, and relay messages arrive from
-- adversarial relays and may carry ESC sequences (fake UI, cleared screens,
-- terminal-title abuse) or stray control codes. Every render boundary —
-- the CLI's @feed@\/@watch@ lines and the TUI's rows alike — runs display
-- text through 'stripAnsiAndC0' first. This is mandatory, not polish.
--
-- Rules: drop ANSI ESC sequences (CSI and Fe escapes) and all C0 controls
-- plus DEL, except @\\n@ (callers clip or keep newlines themselves); map
-- @\\t@ to two spaces; strip @\\r@ outright (a bare CR rewinds the line and
-- lets crafted content overwrite what the UI printed before it).
module Krivostr.Tui.Sanitize
  ( stripAnsiAndC0
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Make text safe to print on a terminal. Pure and total; the hspec target.
stripAnsiAndC0 :: Text -> Text
stripAnsiAndC0 = T.concatMap replace . stripEscapes
  where
    replace '\t' = "  "
    replace '\r' = ""
    replace '\n' = "\n"
    replace c
      | isC0 c    = ""
      | otherwise = T.singleton c
    isC0 c = (c >= '\x00' && c <= '\x08')
          || c == '\x0B' || c == '\x0C'
          || (c >= '\x0E' && c <= '\x1F')
          || c == '\x7F'

-- | Drop ESC and whatever it introduces: CSI (@ESC [ … final@, bytes
-- 0x40–0x7E) and single-character Fe escapes (@ESC@ + one byte 0x40–0x5F).
-- A trailing lone ESC is dropped too — emitting half an escape is worse
-- than losing it.
stripEscapes :: Text -> Text
stripEscapes t = case T.uncons t of
  Nothing -> ""
  Just ('\ESC', rest) -> case T.uncons rest of
    Nothing -> ""
    -- CSI: drop parameters, the final byte, and continue after it. Forgetting
    -- the final byte leaks a stray 'm' (or worse) into the output.
    Just ('[', csis) -> stripEscapes (T.drop 1 (T.dropWhile (not . isFinal) csis))
    Just (c, rest')
      | c >= '@' && c <= '_' -> stripEscapes rest'
      | otherwise -> stripEscapes rest'
  Just (c, rest) -> T.cons c (stripEscapes rest)
  where
    isFinal c = c >= '@' && c <= '~'
