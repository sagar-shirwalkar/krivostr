{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
module Krivostr.Filter
  ( Filter(..)
  , matches
  , empty
  , onlyKinds
  , byAuthors
  , tagEq
  ) where

import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime)
import GHC.Generics (Generic)
import Krivostr.Event

data Filter = Filter
  { fIds     :: !(Maybe [Text])
  , fAuthors :: !(Maybe [Text])
  , fKinds   :: !(Maybe [Int])
  , fSince   :: !(Maybe POSIXTime)
  , fUntil   :: !(Maybe POSIXTime)
  , fLimit   :: !(Maybe Int)
  , fTags    :: ![(Text, [Text])]
  } deriving (Show, Eq, Generic)

instance ToJSON Filter where
  toJSON f = object $ concat
    [ maybe [] (\v -> ["ids"     .= v]) (fIds f)
    , maybe [] (\v -> ["authors" .= v]) (fAuthors f)
    , maybe [] (\v -> ["kinds"   .= v]) (fKinds f)
    , maybe [] (\v -> ["since"   .= v]) (fSince f)
    , maybe [] (\v -> ["until"   .= v]) (fUntil f)
    , maybe [] (\v -> ["limit"   .= v]) (fLimit f)
    , [ K.fromText ("#" <> k) .= v | (k, v) <- fTags f ]
    ]

instance FromJSON Filter where
  parseJSON = withObject "Filter" $ \o -> do
    ids     <- o .:? "ids"
    authors <- o .:? "authors"
    kinds   <- o .:? "kinds"
    since   <- o .:? "since"
    until   <- o .:? "until"
    limit   <- o .:? "limit"
    let tags =
          [ (K.toText k & T.drop 1, v)
          | (k, Array arr) <- KM.toList o
          , "#" `T.isPrefixOf` K.toText k
          , Just v <- [parseMaybe (withArray "tagVals" (mapM parseJSON . foldr (:) [])) (Array arr)]
          ]
    pure Filter
      { fIds = ids, fAuthors = authors, fKinds = kinds
      , fSince = since, fUntil = until, fLimit = limit
      , fTags = tags
      }
    where
      (&) = flip ($)

empty :: Filter
empty = Filter Nothing Nothing Nothing Nothing Nothing Nothing []

onlyKinds :: [Int] -> Filter
onlyKinds ks = empty { fKinds = Just ks }

byAuthors :: [Text] -> Filter
byAuthors as = empty { fAuthors = Just as }

tagEq :: Text -> [Text] -> Filter
tagEq k vs = empty { fTags = [(k, vs)] }

matches :: Filter -> Event -> Bool
matches f e =
     maybe True (elem (evId e)) (fIds f)
  && maybe True (elem (evPubkey e)) (fAuthors f)
  && maybe True (elem (evKind e)) (fKinds f)
  && maybe True (<= evCreatedAt e) (fSince f)
  && maybe True (>= evCreatedAt e) (fUntil f)
  && all tagMatches (fTags f)
  where
    tagMatches (k, vs) =
      any (\tag -> case tag of
             (t:_) -> t == k && any (`elem` tag) vs
             _     -> False)
          (evTags e)
