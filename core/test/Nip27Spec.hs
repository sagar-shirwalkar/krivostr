{-# LANGUAGE OverloadedStrings #-}

-- | NIP-27 text note references: scanning @nostr:@ URIs out of free text.
--
-- The bech32 strings are built from keys rather than transcribed, so the
-- vectors cannot drift from the key code they depend on.
module Nip27Spec (nip27Spec) where

import Data.Text (Text)
import qualified Data.ByteString as BS
<<<<<<< HEAD
import qualified Data.ByteString.Base16 as B16
=======
>>>>>>> 1c7941b (NIP 09 22 27 36 51)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Krivostr.Key
import Krivostr.Nip.Nip27
import Test.Hspec

sk1PubHex :: Text
sk1PubHex = case importHex "0000000000000000000000000000000000000000000000000000000000000001" of
  Right sk -> pubKeyHex (derivePublicKey sk)
  Left e   -> error e

sk1NpubRaw :: Text
sk1NpubRaw = case importHex "0000000000000000000000000000000000000000000000000000000000000001" of
  Right sk -> exportNpub (derivePublicKey sk)
  Left e   -> error e

noteRaw :: Text
noteRaw = encodeNip19 "note" (BS.replicate 32 0xab)

profileRaw :: Text
profileRaw = encodeNip19 "nprofile" tlv
  where
    -- TLV: type 0 (pubkey, 32 bytes) then type 1 (relay hint).
    tlv = BS.concat
      [ BS.pack [0, 32]
      , BS.replicate 32 0xcd
      , BS.pack [1, 10]
      , TE.encodeUtf8 "wss://r.ly"
      ]

kinds :: [Mention] -> [MentionKind]
kinds = map meKind

<<<<<<< HEAD
unhex :: Text -> BS.ByteString
unhex t = case B16.decode (TE.encodeUtf8 t) of
  Right bs -> bs
  Left _   -> error "bad hex"

=======
>>>>>>> 1c7941b (NIP 09 22 27 36 51)
raws :: [Mention] -> [Text]
raws = map meRaw

nip27Spec :: Spec
nip27Spec = describe "NIP-27 mentions" $ do
  describe "findMentions" $ do
    it "finds an npub mention with its hex" $ do
      let ms = findMentions ("hello nostr:" <> sk1NpubRaw <> " bye")
      kinds ms `shouldBe` [MentionPubkey sk1PubHex]
      raws ms `shouldBe` ["nostr:" <> sk1NpubRaw]

    it "finds a note mention" $
      kinds (findMentions ("see nostr:" <> noteRaw))
        `shouldBe` [MentionEvent (T.replicate 32 "ab")]

    it "finds a profile with its relays" $
      kinds (findMentions ("nostr:" <> profileRaw))
        `shouldBe` [MentionProfile (T.replicate 32 "cd") ["wss://r.ly"]]

    it "finds several in order and skips garbage" $
      kinds (findMentions ("a nostr:" <> sk1NpubRaw <> " b nostr:notbech32! c nostr:" <> noteRaw))
        `shouldBe` [MentionPubkey sk1PubHex, MentionEvent (T.replicate 32 "ab")]

    it "finds nothing in plain text" $
      findMentions "just some words" `shouldBe` []

<<<<<<< HEAD
    it "decodes nevent to its id" $ do
      let nevent = encodeNeventFor (unhex (T.replicate 32 "ef")) [] Nothing Nothing
      kinds (findMentions ("x nostr:" <> nevent)) `shouldBe` [MentionEvent (T.replicate 32 "ef")]

    it "decodes naddr to its coordinate" $ do
      let naddr = encodeNip19 "naddr" (BS.concat
            [ BS.pack [0, 7], TE.encodeUtf8 "my-post"
            , BS.pack [2, 32], unhex (T.replicate 32 "cd")
            , BS.pack [3, 4, 0, 0, 0x75, 0x47]
            ])
      kinds (findMentions ("x nostr:" <> naddr))
        `shouldBe` [MentionAddress ("30023:" <> T.replicate 32 "cd" <> ":my-post")]

    it "treats nsec as opaque, never decoded" $ do
      let nsec = encodeNip19 "nsec" (BS.replicate 32 2)
      kinds (findMentions ("x nostr:" <> nsec)) `shouldBe` [MentionOpaque "nsec"]

encodeNeventFor :: BS.ByteString -> [(Int, BS.ByteString)] -> Maybe Text -> Maybe Int -> Text
encodeNeventFor eid extra _ _ = encodeNip19 "nevent" (BS.concat ([BS.pack [0, 32], eid] ++ map entry extra))
  where
    entry (t, v) = BS.pack [fromIntegral t, fromIntegral (BS.length v)] <> v
=======
    it "treats nevent and nsec as opaque, never decoded" $ do
      let nevent = encodeNip19 "nevent" (BS.replicate 32 1)
          nsec = encodeNip19 "nsec" (BS.replicate 32 2)
      kinds (findMentions ("x nostr:" <> nevent)) `shouldBe` [MentionOpaque "nevent"]
      kinds (findMentions ("x nostr:" <> nsec)) `shouldBe` [MentionOpaque "nsec"]
>>>>>>> 1c7941b (NIP 09 22 27 36 51)
