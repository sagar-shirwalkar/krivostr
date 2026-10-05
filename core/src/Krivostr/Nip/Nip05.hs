{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

-- | NIP-05 DNS identifiers: human names for public keys.
--
-- An identifier looks like an email address -- @alice@example.com@ -- and
-- resolves through a JSON document the domain serves at
-- @https://example.com/.well-known/nostr.json@. The document maps names to
-- pubkeys; verification is comparing the claimed pubkey against the mapped
-- one.
--
-- Only the parsing and the comparison live here. Fetching the document is
-- HTTPS, so it belongs below the purity line (@client/@ on the binary,
-- @fetch@ in the browser). What the fetcher hands back is 'Nip05Doc', and
-- 'verifyName' is the whole trust decision.
--
-- Two readings the spec pins down: a bare domain means the name @_@, and the
-- comparison is exact -- no case folding, no trimming. A domain that maps
-- @"Alice"@ does not verify @"alice"@.
module Krivostr.Nip.Nip05
  ( Nip05Doc(..)
  , parseIdentifier
  , wellKnownUrl
  , verifyName
  ) where

import Data.Aeson
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

-- | The @nostr.json@ document: names to hex pubkeys, plus relay hints the
-- verifier ignores. Relays are the publisher's problem, not the verifier's.
data Nip05Doc = Nip05Doc
  { nip05Names  :: !(Map Text Text)
  , nip05Relays :: !(Map Text [Text])
  } deriving (Show, Eq, Generic)

instance FromJSON Nip05Doc where
  parseJSON = withObject "Nip05Doc" $ \o ->
    Nip05Doc <$> o .:? "names" .!= M.empty <*> o .:? "relays" .!= M.empty

instance ToJSON Nip05Doc where
  toJSON d = object ["names" .= nip05Names d, "relays" .= nip05Relays d]

-- | Split @name@domain@ into its parts. A bare domain reads as the name
-- @_@; anything without exactly one @\@@, or with an empty side, is not an
-- identifier at all.
parseIdentifier :: Text -> Either String (Text, Text)
parseIdentifier raw
  | T.null raw = Left "empty identifier"
  | T.any (== '@') raw = case T.splitOn "@" raw of
      [name, domain]
        | not (T.null name) && not (T.null domain) -> Right (name, domain)
      _ -> Left ("bad identifier: " ++ T.unpack raw)
  | otherwise = Right ("_", raw)

-- | The HTTPS URL serving the domain's document, with the @?name=@ query
-- the spec asks clients to send. Some hosts return an empty mapping without
-- it, so leaving it off would turn valid identifiers into failures.
--
-- Always HTTPS: the mapping is a trust decision, and fetching it over plain
-- HTTP would let anyone on the path hand out any pubkey for any name.
wellKnownUrl :: Text -> Text -> Text
wellKnownUrl name domain = "https://" <> domain <> "/.well-known/nostr.json?name=" <> name

-- | Does the document map @name@ to @pubkey@? Exact match on both sides.
-- A missing name and a wrong pubkey fail alike: either way the identifier
-- does not belong to this key, and saying which would help an attacker
-- enumerate the domain's users.
verifyName :: Text -> Text -> Nip05Doc -> Either String ()
verifyName name pubkey doc =
  case M.lookup name (nip05Names doc) of
    Just mapped
      | mapped == pubkey -> Right ()
      | otherwise -> Left ("identifier does not match this pubkey: " ++ T.unpack name)
    Nothing -> Left ("identifier does not match this pubkey: " ++ T.unpack name)
