{-# LANGUAGE OverloadedStrings #-}

-- | NIP-23 long-form content.
--
-- An article is a kind 30023 parameterized-replaceable event: the @d@ tag
-- holds the slug, and the address @30023:pubkey:slug@ names the article, so
-- republishing the same slug replaces the article instead of adding a second
-- one. The body is Markdown in the content; the @title@, @summary@,
-- @image@, and @published_at@ tags are the structured header a reader shows
-- without parsing the body.
--
-- This module builds and reads that header. Rendering Markdown is a client
-- decision -- the CLI prints the raw body, the browser renders it as text --
-- and neither belongs in the address logic.
module Krivostr.Nip.Nip23
  ( articleKind
  , Article(..)
  , articleOf
  , isArticle
  , articleAddress
  , buildArticleTags
  , slugify
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime)
import Krivostr.Event

-- | Kind 30023.
articleKind :: Int
articleKind = 30023

-- | A parsed article header plus body.
data Article = Article
  { arSlug        :: !Text
  , arTitle       :: !Text
  , arSummary     :: !Text
  , arImage       :: !Text
  , arPublishedAt :: !(Maybe POSIXTime)
  , arContent     :: !Text
  , arAuthor      :: !Text
  } deriving (Show, Eq)

-- | Parse a kind 30023 event. Any other kind is not an article, and an
-- article without a @d@ tag has no address -- it is unreferenceable rather
-- than untitled, so it parses to 'Nothing' instead of an empty slug.
articleOf :: Event -> Maybe Article
articleOf e
  | evKind e /= articleKind = Nothing
  | otherwise = case tagValue "d" e of
      Nothing   -> Nothing
      Just slug -> Just Article
        { arSlug        = slug
        , arTitle       = tagOr "" "title" e
        , arSummary     = tagOr "" "summary" e
        , arImage       = tagOr "" "image" e
        , arPublishedAt = tagValue "published_at" e >>= parseTime
        , arContent     = evContent e
        , arAuthor      = evPubkey e
        }
  where
    tagOr def k ev = maybe def id (tagValue k ev)

    parseTime t = case reads (T.unpack t) of
      [(n, "")] -> Just (fromInteger n)
      _         -> Nothing

-- | Is the event a well-formed article?
isArticle :: Event -> Bool
isArticle e = case articleOf e of
  Nothing -> False
  Just _  -> True

-- | The @a@ tag value addressing the article: @30023:pubkey:slug@.
articleAddress :: Event -> Maybe Text
articleAddress e = case articleOf e of
  Nothing -> Nothing
  Just a  -> Just (T.intercalate ":" ["30023", evPubkey e, arSlug a])

-- | The header tags for an article. @published_at@ travels as a tag (not
-- @created_at@) because republishing an edit must not rewrite when the
-- article claims to have been published.
--
-- Empty fields are dropped, not emitted: an empty @title@ tag would be a
-- title that says nothing, and readers fall back to the slug in its absence.
buildArticleTags :: Text -> Text -> Text -> Text -> Maybe POSIXTime -> [[Text]]
buildArticleTags slug title summary image publishedAt =
  [["d", slug]]
    ++ opt "title" title
    ++ opt "summary" summary
    ++ opt "image" image
    ++ case publishedAt of
         Nothing -> []
         Just at -> [["published_at", T.pack (show (floor at :: Integer))]]
  where
    opt _ "" = []
    opt k v  = [[k, v]]

-- | Turn a title into a slug: lowercase, spaces to dashes, nothing else.
-- Slugs address articles, so they must be stable and URL-safe; punctuation
-- is dropped rather than escaped, because an escaped slug is a different
-- address every time a client guesses the escaping differently.
slugify :: Text -> Text
slugify = T.intercalate "-" . T.words . T.map lower . T.filter ok
  where
    lower c
      | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
      | otherwise = c
    ok c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ' ' || c == '-'

tagValue :: Text -> Event -> Maybe Text
tagValue name e = case [v | (t : v : _) <- evTags e, t == name] of
  (v : _) -> Just v
  _       -> Nothing
