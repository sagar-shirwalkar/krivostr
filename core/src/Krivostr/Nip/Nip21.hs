{-# LANGUAGE OverloadedStrings #-}

-- | NIP-21 @nostr:@ URIs: one reference, alone, as an address.
--
-- Where NIP-27 scans mentions out of prose, NIP-21 names a single entity:
-- the whole input (modulo surrounding whitespace) must be exactly one
-- @nostr:@ reference. Anything else -- prose around it, two references,
-- trailing punctuation -- is not a URI, because opening it would mean
-- guessing which part the user meant.
--
-- Resolution (fetching the event or author) is IO and lives with the
-- callers; what a URI *is* stays pure here.
module Krivostr.Nip.Nip21
  ( parseNostrUri
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Krivostr.Nip.Nip27 (Mention (..), findMentions)

-- | Parse a @nostr:@ URI into its mention. The input must be exactly one
-- reference and nothing else; the raw span comes back intact for highlighting.
parseNostrUri :: Text -> Maybe Mention
parseNostrUri raw = case findMentions (T.strip raw) of
  [m@(Mention _ span)] | span == T.strip raw -> Just m
  _ -> Nothing
