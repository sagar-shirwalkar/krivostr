{-# LANGUAGE OverloadedStrings #-}

-- | NIP-13 proof-of-work tests.
--
-- The centrepiece is the mined note from the spec. It is a complete vector: id,
-- nonce counter, committed target and signature are published together, so one
-- test pins canonical serialization, PoW difficulty and Schnorr verification
-- against a value that no amount of self-consistency could invent. If the
-- canonical bytes were wrong the id would differ, and if they were right but
-- the difficulty counting were wrong the assertion on 21 would.
module Nip13Spec (nip13Spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import Krivostr.Event
import Krivostr.Key
import Krivostr.Nip.Nip01
import Krivostr.Nip.Nip13
import Test.Hspec

-- | The note the spec publishes under "Example mined note".
--
-- The signature spans two source lines with a Haskell string gap; a stray
-- space inside the hex would make verification fail with no useful message.
minedNote :: Event
minedNote =
  Event
    { evId = "000006d8c378af1779d2feebc7603a125d99eca0ccf1085959b307f64e5dd358"
    , evPubkey = "a48380f4cfcc1ad5378294fcac36439770f9c878dd880ffa94bb74ea54a6f243"
    , evCreatedAt = 1651794653
    , evKind = 1
    , evTags = [["nonce", "776797", "20"]]
    , evContent = "It's just me mining my own business"
    , evSig =
        "284622fc0a3f4f1303455d5175f7ba962a3300d136085b9566801bc2e0699de0c\
        \7e31e44c81fb40ad9049173742e904713c3594a1da0fc5d2382a25c11aba977"
    }

-- | 'minedNote' before signing: same fields, blank id and signature.
unsignedNote :: Event
unsignedNote = minedNote {evId = "", evSig = ""}

-- | The same note with the nonce tag removed, i.e. before any mining.
unminedNote :: Event
unminedNote = minedNote {evId = "", evSig = "", evTags = []}

-- | An arbitrary throwaway key. The spec's pubkey has no published private
-- key, so the signing tests can only assert self-consistency.
testKey :: PrivateKey
testKey =
  either (error . ("bad test key: " ++)) id
    (importHex "0000000000000000000000000000000000000000000000000000000000000003")

-- | Decode an even-length hex 'Text'. @B16.decode@ takes 'BS.ByteString',
-- and an OverloadedStrings literal would be a 'Text', so the encoding is
-- explicit here.
unhex :: Text -> BS.ByteString
unhex t =
  case B16.decode (TE.encodeUtf8 t) of
    Right bs -> bs
    Left err -> error ("bad hex: " ++ T.unpack t ++ " (" ++ err ++ ")")

isNothing' :: Maybe a -> Bool
isNothing' Nothing = True
isNothing' _ = False

tagCount :: Event -> Text -> Int
tagCount e name =
  length [() | t <- evTags e, case t of (n : _) -> n == name; _ -> False]

hasTag :: Event -> Text -> Bool
hasTag e name = tagCount e name > 0

mineOrFail :: Int -> Event -> Word64 -> (Event, Word64)
mineOrFail target e budget =
  case mine target e budget of
    Nothing -> error ("no nonce found for difficulty " ++ show target)
    Just found -> found

nip13Spec :: Spec
nip13Spec = describe "NIP-13 proof of work" $ do
  describe "the spec's mined note" $ do
    it "recomputes to the published id" $
      -- If canonical serialization were wrong this would differ, which is what
      -- makes the difficulty assertion below mean anything.
      computeEventId unsignedNote `shouldBe` evId minedNote

    it "verifies with the published signature" $
      verifyEvent minedNote `shouldBe` True

    it "carries 21 bits of work against a committed target of 20" $ do
      difficultyOfEvent minedNote `shouldBe` 21
      targetDifficulty minedNote `shouldBe` Just 20
      parseNonce minedNote `shouldBe` Just 776797

    it "satisfies hasWork up to 21 bits and not 22" $ do
      hasWork 20 minedNote `shouldBe` True
      hasWork 21 minedNote `shouldBe` True
      hasWork 22 minedNote `shouldBe` False

    it "accepts 20 bits committed and 20 bits achieved" $ do
      hasCommittedWork 20 minedNote `shouldBe` True
      hasCommittedWork 19 minedNote `shouldBe` True

    it "rejects 21 bits because only 20 was committed" $ do
      -- The note achieves 21 bits, so hasWork 21 passes, but it only committed
      -- to 20. A caller demanding 21 must still refuse it: that gap is exactly
      -- the cheap-mining spammer the third tag element exists to catch, and
      -- closing it here is the whole reason hasCommittedWork exists separately
      -- from hasWork.
      hasWork 21 minedNote `shouldBe` True
      hasCommittedWork 21 minedNote `shouldBe` False
      hasCommittedWork 22 minedNote `shouldBe` False

    it "rejects work when the tag is missing entirely" $
      -- Mining without a commitment cannot be told apart from guessing.
      hasCommittedWork 1 unminedNote `shouldBe` False

    it "ignores the id field when counting difficulty" $ do
      -- The id is attacker-supplied until verification runs. Claiming a forged
      -- id must not change the measured work.
      difficultyOfEvent (minedNote {evId = T.replicate 64 "f"})
        `shouldBe` difficultyOfEvent minedNote

    it "agrees with the difficulty implied by the published id" $
      difficultyOfId (evId minedNote) `shouldBe` Just 21


  describe "leading zero bits" $ do
    it "counts a zero byte as eight bits" $
      leadingZeroBits (BS.pack [0, 0, 0x06, 0xd8]) `shouldBe` 21

    it "counts an all-zero hash as its full width" $
      leadingZeroBits (BS.replicate 32 0) `shouldBe` 256

    it "stops at the first non-zero byte" $ do
      leadingZeroBits (BS.pack [0x80]) `shouldBe` 0
      leadingZeroBits (BS.pack [0x40]) `shouldBe` 1
      leadingZeroBits (BS.pack [0x0f]) `shouldBe` 4
      leadingZeroBits (BS.pack [0x01]) `shouldBe` 7

    it "agrees with the spec's JavaScript reference on nibble boundaries" $
      mapM_
        (\h -> leadingZeroBitsHex h `shouldBe` Just (leadingZeroBits (unhex h)))
        [ "000006d8c378af1779d2feebc7603a125d99eca0ccf1085959b307f64e5dd358"
        , "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        , "0000000000000000000000000000000000000000000000000000000000000001"
        , "000000000000000000000000000000000000000000000000000000000000000f"
        , "00000000000000000000000000000000000000000000000000000000000000f0"
        , "8000000000000000000000000000000000000000000000000000000000000000"
        , "0000000000000000000000000000000000000000000000000000000000000008"
        , "0000000000000000000000000000000000000000000000000000000000000007"
        , "000000000000000000000000000000000000000000000000000000000000000a"
        , "00000000"
        ]

    it "accepts upper-case hex" $
      leadingZeroBitsHex "000006D8" `shouldBe` Just 21

    it "rejects non-hex and the empty string" $ do
      leadingZeroBitsHex "" `shouldBe` Nothing
      leadingZeroBitsHex "xyz" `shouldBe` Nothing
      leadingZeroBitsHex "00 11" `shouldBe` Nothing

  describe "the nonce tag" $ do
    it "builds a three element tag" $
      nonceTag 776797 20 `shouldBe` ["nonce", "776797", "20"]

    it "is absent from an unmined note" $ do
      parseNonce unminedNote `shouldBe` Nothing
      targetDifficulty unminedNote `shouldBe` Nothing

    it "reads a counter without a target" $ do
      let e = unsignedNote {evTags = [["nonce", "1"]]}
      parseNonce e `shouldBe` Just 1
      targetDifficulty e `shouldBe` Nothing

    it "rejects a non-numeric counter" $ do
      let tags cs = unsignedNote {evTags = [["nonce"] <> cs]}
      parseNonce (tags ["x", "20"]) `shouldBe` Nothing
      parseNonce (tags ["-1", "20"]) `shouldBe` Nothing
      parseNonce (tags ["1 ", "20"]) `shouldBe` Nothing
      parseNonce (tags ["", "20"]) `shouldBe` Nothing
      parseNonce (tags ["12abc", "20"]) `shouldBe` Nothing

    it "rejects a non-numeric target" $
      targetDifficulty (unsignedNote {evTags = [["nonce", "1", "2e1"]]})
        `shouldBe` Nothing

    it "takes the first tag when a note somehow carries two" $ do
      let e = unsignedNote {evTags = [["nonce", "5", "20"], ["nonce", "9", "30"]]}
      parseNonce e `shouldBe` Just 5
      targetDifficulty e `shouldBe` Just 20

  describe "mining" $ do
    it "finds a nonce meeting the target and fixes the id" $
      let (mined, counter) = mineOrFail 8 unsignedNote 200000
      in do
        difficultyOfEvent mined `shouldSatisfy` (>= 8)
        evId mined `shouldBe` computeEventId mined
        parseNonce mined `shouldBe` Just counter
        targetDifficulty mined `shouldBe` Just 8

    it "produces a note that signs and verifies" $
      -- Mining must use the key that will sign: signEvent fills in the pubkey,
      -- and the pubkey is part of the canonical bytes, so mining before setting
      -- it would invalidate the work.
      let ready = unsignedNote {evPubkey = pubKeyHex (derivePublicKey testKey)}
          (mined, _) = mineOrFail 8 ready 200000
          signed = signEvent testKey mined
      in do
        verifyEvent signed `shouldBe` True
        difficultyOfEvent signed `shouldSatisfy` (>= 8)

    it "loses its work if the pubkey changes after mining" $
      -- The counterpart of the previous test, and the reason mining is done
      -- with the final key: a different pubkey is a different id.
      let (mined, _) = mineOrFail 16 unsignedNote 2000000
          resigned = signEvent testKey mined
      in difficultyOfEvent resigned `shouldNotBe` difficultyOfEvent mined

    it "keeps exactly one nonce tag when the note already had one" $
      let (mined, _) = mineOrFail 4 unsignedNote 200000
      in tagCount mined "nonce" `shouldBe` 1

    it "keeps unrelated tags and adds a nonce tag when there was none" $ do
      let (withTag, _) = mineOrFail 4 (unsignedNote {evTags = [["t", "post"]]}) 200000
      hasTag withTag "t" `shouldBe` True
      hasTag withTag "nonce" `shouldBe` True

    it "is satisfied immediately at difficulty zero" $
      case mine 0 unsignedNote 0 of
        Nothing -> expectationFailure "difficulty 0 must always succeed"
        Just (mined, counter) -> counter `shouldBe` 0

    it "gives up rather than searching past the budget" $
      mine 60 unsignedNote 50 `shouldSatisfy` isNothing'

    it "changes the id as the counter advances" $
      -- Two different counters are different work, so they must not collide.
      let a = evId (fst (mineOrFail 4 unsignedNote 200000))
          b = evId (fst (mineOrFail 4 (unsignedNote {evCreatedAt = 1651794654}) 200000))
      in a `shouldNotBe` b