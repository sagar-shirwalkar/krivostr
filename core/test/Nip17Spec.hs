{-# LANGUAGE OverloadedStrings #-}

-- | NIP-17 private direct message tests.
--
-- NIP-17 is composition over NIP-59, so most of what could go wrong lives in
-- 'Krivostr.Nip.Nip59' and is tested there. What is tested here is the part that
-- is NIP-17's own: the @kind 14@ rumor shape, the timestamp jitter, and the rule
-- that the seal's pubkey must equal the rumor's pubkey -- the check that stops
-- anyone impersonating anyone by rewriting a rumor's author.
module Nip17Spec (nip17Spec) where

import Data.Aeson (encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock.POSIX (POSIXTime)
import Krivostr.Event
import Krivostr.Key
import Krivostr.Nip.Nip01
import Krivostr.Nip.Nip17
import Krivostr.Nip.Nip44
import Krivostr.Nip.Nip59
import System.IO.Error (ioError, userError)
import Test.Hspec

aliceKey, bobKey, wrapperKey :: PrivateKey
aliceKey = key "0beebd062ec8735f4243466049d7747ef5d6594ee838de147f8aab842b15e273"
bobKey = key "e108399bd8424357a710b606ae0c13166d853d327e47a6e5e038197346bdbf45"
wrapperKey = key "4f02eac59266002db5801adc5270700ca69d5b8f761d8732fab2fbf233c90cbd"

key :: Text -> PrivateKey
key = either (error . ("bad key: " ++)) id . importHex

alicePub, bobPub :: Text
alicePub = pubKeyHex (derivePublicKey aliceKey)
bobPub = pubKeyHex (derivePublicKey bobKey)

-- | Fixed nonces, so the built layers are reproducible.
sealNonce, wrapNonce :: BS.ByteString
sealNonce = BS.replicate 32 0x01
wrapNonce = BS.replicate 32 0x02

fromRight :: Either String a -> IO a
fromRight = either (ioError . userError) pure

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

nip17Spec :: Spec
nip17Spec = describe "NIP-17 private direct messages" $ do
  describe "createChatRumor" $ do
    let rumor = createChatRumor aliceKey 1700000000 [bobPub] "party" "Are you going to the party tonight?"

    it "is a kind 14 event with the sender's pubkey" $ do
      rumorKind rumor `shouldBe` 14
      rumorPubkey rumor `shouldBe` alicePub
      rumorId rumor `shouldNotBe` ""

    it "carries one p tag per receiver" $
      rumorTags rumor `shouldBe` [["p", bobPub], ["subject", "party"]]

    it "reads back its receivers and subject" $ do
      chatReceivers rumor `shouldBe` [bobPub]
      chatSubject rumor `shouldBe` Just "party"

    it "omits the subject tag when there is no subject" $
      rumorTags (createChatRumor aliceKey 1700000000 [bobPub] "" "")
        `shouldBe` [["p", bobPub]]

    it "supports several receivers in one room" $ do
      let carolPub = pubKeyHex (derivePublicKey wrapperKey)
          multi = createChatRumor aliceKey 1700000000 [bobPub, carolPub] "" ""
      chatReceivers multi `shouldBe` [bobPub, carolPub]
      -- The p tag set is the room identity, so it is ordered and complete.
      rumorTags multi `shouldBe` [["p", bobPub], ["p", carolPub]]

    it "ignores empty receiver strings" $
      chatReceivers (createChatRumor aliceKey 1700000000 [bobPub, ""] "" "")
        `shouldBe` [bobPub]

    it "computes the id over an unsigned event" $
      -- The rumor's id is part of the rumor, and NIP-17 replies link to it, so
      -- it must be the id of the event as it will be sealed: no signature.
      rumorId rumor
        `shouldBe` computeEventId (mkEvent (UnsignedEvent alicePub 1700000000 14 [["p", bobPub], ["subject", "party"]] "Are you going to the party tonight?"))

  describe "createFileRumor" $ do
    let rumor =
          createFileRumor
            aliceKey
            1700000000
            [bobPub]
            "image/jpeg"
            "https://example.com/f.jpg"
            [["x", "ab" <> T.replicate 62 "cd"]]

    it "is a kind 15 event" $
      rumorKind rumor `shouldBe` 15

    it "carries the file metadata tags" $
      rumorTags rumor
        `shouldBe` [ ["p", bobPub]
                   , ["file-type", "image/jpeg"]
                   , ["x", "ab" <> T.replicate 62 "cd"]
                   ]

    it "uses the url as its content" $
      rumorContent rumor `shouldBe` "https://example.com/f.jpg"

    it "omits the file-type tag when none is given" $
      rumorTags (createFileRumor aliceKey 1700000000 [bobPub] "" "" [])
        `shouldBe` [["p", bobPub]]

  describe "pastTimestamp" $ do
    it "shifts backwards by the offset" $
      pastTimestamp 1700000000 3600 `shouldBe` 1699996400

    it "is the identity at zero" $
      pastTimestamp 1700000000 0 `shouldBe` 1700000000

    it "clamps to two days" $ do
      pastTimestamp 1700000000 twoDaysSeconds `shouldBe` 1700000000 - 172800
      pastTimestamp 1700000000 (twoDaysSeconds + 1) `shouldBe` 1700000000 - 172800
      pastTimestamp 1700000000 999999999 `shouldBe` 1700000000 - 172800

    it "never moves a timestamp into the future" $
      -- A negative offset would, and some relays refuse to serve future-dated
      -- events, which the spec warns about.
      pastTimestamp 1700000000 (-1) `shouldBe` 1700000000

    it "stays inside the window for every offset in range" $
      mapM_
        (\n -> pastTimestamp 1700000000 n `shouldSatisfy` (\t -> t > 1700000000 - 172801 && t <= 1700000000))
        [0, 1, 86400, 172799, 172800]

  describe "sealAndWrap" $ do
    let rumor = createChatRumor aliceKey 1700000000 [bobPub] "party" "Are you going to the party tonight?"
        layers =
          either error id
            ( sealAndWrap
                aliceKey
                wrapperKey
                bobPub
                1699990000
                sealNonce
                1699980000
                wrapNonce
                rumor
            )

    it "produces a kind 13 seal and a kind 1059 wrap" $ do
      evKind (dmSeal layers) `shouldBe` 13
      evKind (dmWrap layers) `shouldBe` 1059

    it "signs the seal with the author and the wrap with a one-time key" $ do
      evPubkey (dmSeal layers) `shouldBe` alicePub
      evPubkey (dmWrap layers) `shouldBe` pubKeyHex (derivePublicKey wrapperKey)
      evPubkey (dmSeal layers) `shouldNotBe` evPubkey (dmWrap layers)

    it "gives the seal empty tags and the wrap a p tag" $ do
      evTags (dmSeal layers) `shouldBe` []
      evTags (dmWrap layers) `shouldBe` [["p", bobPub]]

    it "uses independent timestamps for the two layers" $
      -- Reusing one timestamp across layers is the correlation the spec warns
      -- about.
      evCreatedAt (dmSeal layers) `shouldNotBe` evCreatedAt (dmWrap layers)

    it "round-trips back to the original rumor" $ do
      s <- fromRight (unwrap bobKey (dmWrap layers))
      unseal bobKey s `shouldBe` Right rumor

    it "hides the message from the relay-facing wrap" $ do
      let wire = BL.toStrict (encode (dmWrap layers))
      wire `shouldNotSatisfy` BS.isInfixOf (encodeUtf8 (rumorContent rumor))
      wire `shouldNotSatisfy` BS.isInfixOf (encodeUtf8 alicePub)
      wire `shouldSatisfy` BS.isInfixOf (encodeUtf8 bobPub)

    it "hides the rumor's kind from the wrap" $
      -- kind 14 must not be visible; the wrap says 1059 and nothing else.
      BL.toStrict (encode (dmWrap layers))
        `shouldNotSatisfy` BS.isInfixOf "\"kind\":14"

    it "does not let the sender's key read someone else's wrap" $
      -- Only the p-tagged recipient can open it.
      unwrap aliceKey (dmWrap layers) `shouldSatisfy` isLeft

    it "rejects a wrap whose seal author differs from the rumor author" $
      -- NIP-17 makes this check mandatory. Rewriting the rumor's pubkey would
      -- otherwise let anyone impersonate anyone.
      let forged = (dmSeal layers) {evPubkey = bobPub}
      in unseal bobKey forged `shouldSatisfy` isLeft

  describe "dmRelayListTags" $ do
    it "builds one relay tag per relay" $
      dmRelayListTags ["wss://a", "wss://b"]
        `shouldBe` [["r", "wss://a"], ["r", "wss://b"]]

    it "drops empty entries" $
      dmRelayListTags ["wss://a", "", "wss://b"]
        `shouldBe` [["r", "wss://a"], ["r", "wss://b"]]

    it "is empty for no relays" $
      dmRelayListTags [] `shouldBe` []

  describe "kinds" $ do
    it "exposes the documented kind numbers" $ do
      chatKind `shouldBe` 14
      fileMessageKind `shouldBe` 15
      dmRelayListKind `shouldBe` 10050
      twoDaysSeconds `shouldBe` 172800
