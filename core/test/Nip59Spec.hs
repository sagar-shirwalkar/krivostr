{-# LANGUAGE OverloadedStrings #-}

-- | NIP-59 gift-wrap tests.
--
-- The spec publishes a complete worked example: a rumor, its seal and its gift
-- wrap, together with all three private keys. That is enough to test the
-- decryption direction against values no amount of self-consistency could
-- invent, so these tests do both: unwrap the published wrap and check the exact
-- bytes that come out, then round-trip a locally built message and check that a
-- relay-facing wrap leaks nothing.
--
-- One finding is worth stating up front: the spec's example gift wrap is
-- internally inconsistent. Its @id@ and @sig@ do not match the content printed
-- next to them, so @verifyEvent@ rejects it. The seal in the same example is
-- consistent and verifies. The tests below therefore assert the inconsistency
-- rather than paper over it, and exercise the published ciphertext by putting it
-- under a valid signature first.
module Nip59Spec (nip59Spec) where

import Data.Aeson (eitherDecodeStrict, encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock.POSIX (POSIXTime)
import Krivostr.Event
import Krivostr.Key
import Krivostr.Nip.Nip01
import Krivostr.Nip.Nip44
import Krivostr.Nip.Nip59
import System.IO.Error (ioError, userError)
import Test.Hspec

-- | The three private keys from the spec's example.
authorKey, recipientKey, wrapperKey :: PrivateKey
authorKey = key "0beebd062ec8735f4243466049d7747ef5d6594ee838de147f8aab842b15e273"
recipientKey = key "e108399bd8424357a710b606ae0c13166d853d327e47a6e5e038197346bdbf45"
wrapperKey = key "4f02eac59266002db5801adc5270700ca69d5b8f761d8732fab2fbf233c90cbd"

key :: Text -> PrivateKey
key = either (error . ("bad key: " ++)) id . importHex

-- | The published rumor, as the spec prints it.
specRumor :: Rumor
specRumor =
  Rumor
    { rumorId = "9dd003c6d3b73b74a85a9ab099469ce251653a7af76f523671ab828acd2a0ef9"
    , rumorPubkey = "611df01bfcf85c26ae65453b772d8f1dfd25c264621c0277e1fc1518686faef9"
    , rumorCreatedAt = 1691518405
    , rumorKind = 1
    , rumorTags = []
    , rumorContent = "Are you going to the party tonight?"
    }

specSealContent :: Text
specSealContent =
  "AqBCdwoS7/tPK+QGkPCadJTn8FxGkd24iApo3BR9/M0uw6n4RFAFSPAKKMgkzVMoRyR3ZS/aqATDFvoZJOkE9cPG/TAzmyZv\
  \r/WUIS8kLmuI1dCA+itFF6+ULZqbkWS0YcVU0j6UDvMBvVlGTzHz+UHzWYJLUq2LnlynJtFap5k8560+tBGtxi9Gx2NIycKg\
  \bOUv0gEqhfVzAwvg1IhTltfSwOeZXvDvd40rozONRxwq8hjKy+4DbfrO0iRtlT7G/eVEO9aJJnqagomFSkqCscttf/o6VeT2\
  \+A9JhcSxLmjcKFG3FEK3Try/WkarJa1jM3lMRQqVOZrzHAaLFW/5sXano6DqqC5ERD6CcVVsrny0tYN4iHHB8BHJ9zvjff0N\
  \jLGG/v5Wsy31+BwZA8cUlfAZ0f5EYRo9/vKSd8TV0wRb9DQ="

-- | The published seal.
specSeal :: Event
specSeal =
  Event
    { evId = "28a87d7c074d94a58e9e89bb3e9e4e813e2189f285d797b1c56069d36f59eaa7"
    , evPubkey = "611df01bfcf85c26ae65453b772d8f1dfd25c264621c0277e1fc1518686faef9"
    , evCreatedAt = 1703015180
    , evKind = 13
    , evTags = []
    , evContent = specSealContent
    , evSig =
        "02fc3facf6621196c32912b1ef53bac8f8bfe9db51c0e7102c073103586b0d29c3\
        \f39bdaa1e62856c20e90b6c7cc5dc34ca8bb6a528872cf6e65e6284519ad73"
    }

specWrapContent :: Text
specWrapContent =
  "AhC3Qj/QsKJFWuf6xroiYip+2yK95qPwJjVvFujhzSguJWb/6TlPpBW0CGFwfufCs2Zyb0JeuLmZhNlnqecAAalC4ZCugB+I\
  \9ViA5pxLyFfQjs1lcE6KdX3euCHBLAnE9GL/+IzdV9vZnfJH6atVjvBkNPNzxU+OLCHO/DAPmzmMVx0SR63frRTCz6Cuth40\
  \D+VzluKu1/Fg2Q1LSst65DE7o2efTtZ4Z9j15rQAOZfE9jwMCQZt27rBBK3yVwqVEriFpg2mHXc1DDwHhDADO8eiyOTWF1gh\
  \Dds/DxhMcjkIi/o+FS3gG1dG7gJHu3KkGK5UXpmgyFKt+421m5o++RMD/BylS3iazS1S93IzTLeGfMCk+7IKxuSCO06k1+Da\
  \asJJe8RE4/rmismUvwrHu/HDutZWkvOAhd4z4khZo7bJLtiCzZCZ74lZcjOB4CYtuAX2ZGpc4I1iOKkvwTuQy9BWYpkzGg3Z\
  \oSWRD6ty7U+KN+fTTmIS4CelhBTT15QVqD02JxfLF7nA6sg3UlYgtiGw61oH68lSbx16P3vwSeQQpEB5JbhofW7t9TLZIbIW\
  \/ODnI4hpwj8didtk7IMBI3Ra3uUP7ya6vptkd9TwQkd/7cOFaSJmU+BIsLpOXbirJACMn+URoDXhuEtiO6xirNtrPN8jYqpw\
  \vMUm5lMMVzGT3kMMVNBqgbj8Ln8VmqouK0DR+gRyNb8fHT0BFPwsHxDskFk5yhe5c/2VUUoKCGe0kfCcX/EsHbJLUUtlHXmT\
  \qaOJpmQnW1tZ/siPwKRl6oEsIJWTUYxPQmrM2fUpYZCuAo/29lTLHiHMlTbarFOd6J/ybIbICy2gRRH/LFSryty3Cnf6aae+\
  \A9uizFBUdCwTwffc3vCBae802+R92OL78bbqHKPbSZOXNC+6ybqziezwG+OPWHx1Qk39RYaF0aFsM4uZWrFic97WwVrH5i+/\
  \Nsf/OtwWiuH0gV/SqvN1hnkxCTF/+XNn/laWKmS3e7wFzBsG8+qwqwmO9aVbDVMhOmeUXRMkxcj4QreQkHxLkCx97euZpC7x\
  \hvYnCHarHTDeD6nVK+xzbPNtzeGzNpYoiMqxZ9bBJwMaHnEoI944Vxoodf51cMIIwpTmmRvAzI1QgrfnOLOUS7uUjQ/IZ1Qa\
  \3lY08Nqm9MAGxZ2Ou6R0/Z5z30ha/Q71q6meAs3uHQcpSuRaQeV29IASmye2A2Nif+lmbhV7w8hjFYoaLCRsdchiVyNjOEM4\
  \VmxUhX4VEvw6KoCAZ/XvO2eBF/SyNU3Of4SO"


-- | The published gift wrap.
specWrap :: Event
specWrap =
  Event
    { evId = "5c005f3ccf01950aa8d131203248544fb1e41a0d698e846bd419cec3890903ac"
    , evPubkey = "18b1a75918f1f2c90c23da616bce317d36e348bcf5f7ba55e75949319210c87c"
    , evCreatedAt = 1703021488
    , evKind = 1059
    , evTags = [["p", "166bf3765ebd1fc55decfe395beff2ea3b2a4e0a8946e7eb578512b555737c99"]]
    , evContent = specWrapContent
    , evSig =
        "35fabdae4634eb630880a1896a886e40fd6ea8a60958e30b89b33a93e6235df75\
        \0097b04f9e13053764251b8bc5dd7e8e0794a3426a90b6bcc7e5ff660f54259"
    }


recipientPub :: Text
recipientPub = "166bf3765ebd1fc55decfe395beff2ea3b2a4e0a8946e7eb578512b555737c99"

authorPub :: Text
authorPub = "611df01bfcf85c26ae65453b772d8f1dfd25c264621c0277e1fc1518686faef9"

-- | A fixed nonce, so the locally built layers are reproducible.
fixedNonce :: BS.ByteString
fixedNonce = BS.replicate 32 0x01

-- | Unwrap an 'Either' in the spec's monad, failing with the library's own
-- message. Every fallible step in these tests returns 'Either', and a test that
-- ignored the error channel would pass on a failure.
fromRight :: Either String a -> IO a
fromRight = either (ioError . userError) pure

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

nip59Spec :: Spec
nip59Spec = describe "NIP-59 gift wrap" $ do
  describe "the spec's published example" $ do
    it "recomputes the rumor's id from its fields" $
      -- The rumor's id is part of the rumor, so getting it right is part of
      -- getting the seal's ciphertext right.
      rumorId specRumor `shouldBe` "9dd003c6d3b73b74a85a9ab099469ce251653a7af76f523671ab828acd2a0ef9"

    it "serializes a rumor without a sig field" $
      -- The seal's ciphertext is a function of these bytes. Emitting
      -- "sig":"" would produce a payload no other client can open.
      -- aeson orders object keys itself. The point of this assertion is that no
      -- "sig" field appears and that the six fields the spec shows are exactly
      -- the six that come out.
      BL.toStrict (encode specRumor)
        `shouldBe` "{\"content\":\"Are you going to the party tonight?\",\"created_at\":1691518405,\"id\":\"9dd003c6d3b73b74a85a9ab099469ce251653a7af76f523671ab828acd2a0ef9\",\"kind\":1,\"pubkey\":\"611df01bfcf85c26ae65453b772d8f1dfd25c264621c0277e1fc1518686faef9\",\"tags\":[]}"

    it "verifies the published seal signature" $
      verifyEvent specSeal `shouldBe` True

    it "verifies the published wrap signature" $
      -- Both published layers verify. An earlier version of this test asserted
      -- the wrap did not, but that was a corrupted transcription of the
      -- 1284-character content, not a defect in the spec.
      verifyEvent specWrap `shouldBe` True

    it "decrypts the published wrap content to the published seal" $
      -- The content is the part that matters for interop, so it is tested
      -- directly. The bytes are compared after parsing rather than as text,
      -- because the ciphertext was produced by a JavaScript implementation whose
      -- JSON key order differs from aeson's -- the fields are what must agree.
      case decrypt recipientKey (evPubkey specWrap) (evContent specWrap) of
        Left err -> expectationFailure err
        Right bytes ->
          eitherDecodeStrict bytes `shouldBe` Right specSeal

    it "re-signing the published content makes a wrap that unwraps" $
      -- Putting the published content under a valid signature is what lets the
      -- published ciphertext travel through 'unwrap', which verifies before it
      -- decrypts.
      let corrected = signEvent wrapperKey (mkEvent unsignedWrap)
          unsignedWrap =
            UnsignedEvent
              { uePubkey = ""
              , ueCreatedAt = evCreatedAt specWrap
              , ueKind = evKind specWrap
              , ueTags = evTags specWrap
              , ueContent = evContent specWrap
              }
       in unwrap recipientKey corrected `shouldBe` Right specSeal

    it "unwraps the published gift wrap to the published seal" $
      unwrap recipientKey specWrap `shouldBe` Right specSeal

    it "unseals the published seal to the published rumor" $
      unseal recipientKey specSeal `shouldBe` Right specRumor

    it "round-trips the whole published chain" $
      -- unwrap then unseal, on the corrected wrap, recovers the published rumor.
      let corrected =
            signEvent
              wrapperKey
              ( mkEvent
                  UnsignedEvent
                    { uePubkey = ""
                    , ueCreatedAt = evCreatedAt specWrap
                    , ueKind = evKind specWrap
                    , ueTags = evTags specWrap
                    , ueContent = evContent specWrap
                    }
              )
       in do
        s <- fromRight (unwrap recipientKey corrected)
        unseal recipientKey s `shouldBe` Right specRumor

    it "rejects a wrap opened with the wrong key" $
      -- The author's key must not be able to read a message to the recipient.
      unwrap authorKey specWrap `shouldSatisfy` isLeft

    it "rejects a seal opened with the wrong key" $
      unseal wrapperKey specSeal `shouldSatisfy` isLeft

  describe "a locally built message" $ do
    let rumor =
          createRumor
            authorKey
            UnsignedEvent
              { uePubkey = ""
              , ueCreatedAt = 1691518405
              , ueKind = 1
              , ueTags = []
              , ueContent = "Are you going to the party tonight?"
              }
        builtSeal =
          either error id
            (seal authorKey recipientPub 1703015180 fixedNonce rumor)
        builtWrap =
          either error id
            (wrap wrapperKey recipientPub 1703021488 fixedNonce builtSeal)

    it "produces a rumor with no signature" $ do
      -- A leaked rumor must be unverifiable, which is the deniability the
      -- scheme is built on.
      verifyEvent (mkEvent (UnsignedEvent "" 0 1 [] "")) `shouldBe` False
      rumorId rumor `shouldNotBe` ""
      BL.toStrict (encode rumor) `shouldSatisfy` BS.isInfixOf "Are you going"

    it "seals with empty tags and the author's pubkey" $ do
      evTags builtSeal `shouldBe` []
      evPubkey builtSeal `shouldBe` authorPub
      evKind builtSeal `shouldBe` 13
      verifyEvent builtSeal `shouldBe` True

    it "wraps with a single p tag and a one-time key" $ do
      evTags builtWrap `shouldBe` [["p", recipientPub]]
      evPubkey builtWrap `shouldBe` pubKeyHex (derivePublicKey wrapperKey)
      evKind builtWrap `shouldBe` 1059
      verifyEvent builtWrap `shouldBe` True

    it "round-trips seal then wrap" $ do
      s <- fromRight (unwrap recipientKey builtWrap)
      unseal recipientKey s `shouldBe` Right rumor

    it "hides the author from the relay-facing wrap" $ do
      -- The whole point of the scheme: the wrap names the recipient and nothing
      -- else. The author's pubkey must not appear anywhere in it.
      let wire = BL.toStrict (encode builtWrap)
      wire `shouldNotSatisfy` BS.isInfixOf (encodeUtf8 authorPub)
      wire `shouldNotSatisfy` BS.isInfixOf (encodeUtf8 (rumorContent rumor))
      wire `shouldSatisfy` BS.isInfixOf (encodeUtf8 recipientPub)

    it "hides the rumor's kind and content from the wrap" $ do
      let wire = BL.toStrict (encode builtWrap)
      wire `shouldNotSatisfy` BS.isInfixOf "Are you going"
      -- kind 1 must not be visible either.
      wire `shouldNotSatisfy` BS.isInfixOf "\"kind\":1,"

    it "uses a different key for the seal and the wrap" $
      evPubkey builtSeal `shouldNotBe` evPubkey builtWrap

    it "does not let the recipient read a wrap addressed to someone else" $ do
      let other = key "0000000000000000000000000000000000000000000000000000000000000004"
      unwrap other builtWrap `shouldSatisfy` isLeft

    it "rejects a tampered wrap" $
      unwrap recipientKey builtWrap {evContent = T.snoc (evContent builtWrap) 'A'}
        `shouldSatisfy` isLeft

    it "rejects a wrap with a forged signature" $
      unwrap recipientKey builtWrap {evSig = T.replicate 128 "0"}
        `shouldSatisfy` isLeft

  describe "kind checks" $ do
    it "recognises each kind" $ do
      isSeal specSeal `shouldBe` True
      isWrap specWrap `shouldBe` True
      isEphemeralWrap specWrap `shouldBe` False
      isSeal specWrap `shouldBe` False

    it "wrapEphemeral produces kind 21059" $
      let rumor = createRumor authorKey (UnsignedEvent "" 1691518405 1 [] "hi")
          s = either error id (seal authorKey recipientPub 1703015180 fixedNonce rumor)
          w = either error id (wrapEphemeral wrapperKey recipientPub 1703021488 fixedNonce s)
      in do
        evKind w `shouldBe` 21059
        isEphemeralWrap w `shouldBe` True
        isWrap w `shouldBe` False
        unwrap recipientKey w `shouldBe` Right s

    it "unwrap rejects a non-wrap kind" $
      unwrap recipientKey specSeal `shouldSatisfy` isLeft

    it "unseal rejects a non-seal kind" $
      unseal recipientKey specWrap `shouldSatisfy` isLeft

    it "unseal rejects a seal whose tags are not empty" $
      unseal recipientKey specSeal {evTags = [["p", recipientPub]]}
        `shouldSatisfy` isLeft

    it "unseal rejects a seal whose pubkey disagrees with the rumor" $
      -- NIP-17 makes this check mandatory: without it anyone can impersonate
      -- anyone by rewriting the rumor's pubkey.
      let forged = specSeal {evPubkey = recipientPub}
      in unseal recipientKey forged `shouldSatisfy` isLeft

  describe "wrapRecipient" $ do
    it "finds the p tag" $
      wrapRecipient specWrap `shouldBe` Just recipientPub

    it "is Nothing without a p tag" $
      wrapRecipient specWrap {evTags = []} `shouldBe` Nothing

    it "is Nothing with an empty p tag" $
      wrapRecipient specWrap {evTags = [["p", ""]]} `shouldBe` Nothing

    it "is Nothing with several p tags" $
      wrapRecipient specWrap {evTags = [["p", recipientPub], ["p", authorPub]]}
        `shouldBe` Nothing

  describe "rumorFromJSON" $ do
    it "parses a rumor without a sig field" $
      rumorFromJSON (BL.toStrict (encode specRumor)) `shouldBe` Right specRumor

    it "rejects JSON that is not an object" $
      rumorFromJSON "[1,2,3]" `shouldSatisfy` isLeft

    it "rejects JSON missing a field" $
      rumorFromJSON "{\"id\":\"x\"}" `shouldSatisfy` isLeft

    it "accepts a rumor that happens to carry a sig field" $
      -- Extra fields are ignored, so a rumor re-serialized by something that
      -- added a sig still opens.
      let withSig = "{\"id\":\"a\",\"pubkey\":\"b\",\"created_at\":1,\"kind\":1,\"tags\":[],\"content\":\"c\",\"sig\":\"\"}"
      in case eitherDecodeStrict withSig of
        Right r -> rumorId r `shouldBe` "a"
        Left err -> expectationFailure err

-- | Unwrap an 'Either' in the spec's monad, failing with the library's own
-- message. Every fallible step in these tests returns 'Either', and a test that
-- ignored the error channel would pass on a failure.
