{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Nip42Spec (nip42Spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (POSIXTime)
import Krivostr.Event
import Krivostr.Key
import Krivostr.Nip.Nip01
import Krivostr.Nip.Nip42
import Test.Hspec

fromRight :: Either String a -> IO a
fromRight = either (ioError . userError) pure

-- Helper to generate a test key pair
-- We'll create deterministic keys for testing
mkKey :: (PrivateKey, PublicKey)
mkKey = case importHex "0000a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2" of
  Right sk -> (sk, derivePublicKey sk)
  Left e -> error ("should not happen in test: " ++ e)

mkKey2 :: (PrivateKey, PublicKey)
mkKey2 = case importHex "9f8e7d6c5b4a3928170605040302010f0e0d0c0b0a0908070605040302010000" of
  Right sk -> (sk, derivePublicKey sk)
  Left e -> error ("should not happen in test: " ++ e)

nip42Spec :: Spec
nip42Spec = describe "NIP-42" $ do
  let (sk, pk) = mkKey
  let relayUrl = "wss://relay.example.com/"
  let challenge = "challengestringhere"
  let now :: POSIXTime = 1700000000

  it "build-then-validate round-trip succeeds" $ do
    let authEvent = buildAuthEvent sk relayUrl challenge now
    -- The built event's id/signature verify
    verifyEvent authEvent `shouldBe` True
    -- Tags are exactly [["relay",...],["challenge",...]]
    evTags authEvent `shouldBe` [["relay", relayUrl], ["challenge", challenge]]
    -- Validate with correct params
    validateAuthEvent relayUrl challenge now 600 authEvent `shouldBe` Right ()

  it "validate rejects a wrong challenge" $ do
    let authEvent = buildAuthEvent sk relayUrl challenge now
    validateAuthEvent relayUrl "wrong" now 600 authEvent `shouldBe` Left "challenge mismatch"

  it "validate rejects a wrong relay url" $ do
    let authEvent = buildAuthEvent sk relayUrl challenge now
    validateAuthEvent "wss://other.example.com/" challenge now 600 authEvent
      `shouldBe` Left "relay tag mismatch"

  it "validate rejects an expired event (now far in the future)" $ do
    let authEvent = buildAuthEvent sk relayUrl challenge now
    let future :: POSIXTime = now + 1200  -- 20 minutes later, maxAge 600
    validateAuthEvent relayUrl challenge future 600 authEvent
      `shouldBe` Left "event too old"

  it "validate rejects a future-dated event" $ do
    let authEvent = buildAuthEvent sk relayUrl challenge now
    let earlierButEventFuture :: POSIXTime = now - 1200  -- event is in future relative to now? no - event created at now, checking from earlier is fine; better test: event at future time
    let eventFuture = now + 100  -- event created at now+100, we check at now
    let authFuture = buildAuthEvent sk relayUrl challenge eventFuture
    validateAuthEvent relayUrl challenge now 600 authFuture
      `shouldBe` Left "event created in the future"

  it "validate rejects a tampered challenge tag" $ do
    let authEvent = buildAuthEvent sk relayUrl challenge now
    -- Tamper the tags
    let tampered = authEvent { evTags = [["relay", relayUrl], ["challenge", "tampered"]] }
    validateAuthEvent relayUrl challenge now 600 tampered
      `shouldBe` Left "challenge mismatch"

  it "validate rejects a bad signature" $ do
    let authEvent = buildAuthEvent sk relayUrl challenge now
    -- Tamper content or signature - simplest: change sig to empty or wrong
    let tampered = authEvent { evSig = "00" <> T.drop 2 (evSig authEvent) }
    validateAuthEvent relayUrl challenge now 600 tampered
      `shouldBe` Left "bad signature or invalid id"

  it "validate rejects kind != 22242" $ do
    let authEvent = buildAuthEvent sk relayUrl challenge now
    let wrongKind = authEvent { evKind = 1 }
    validateAuthEvent relayUrl challenge now 600 wrongKind
      `shouldBe` Left "wrong kind (must be 22242)"

  it "validate rejects a missing relay tag" $ do
    let authEvent = buildAuthEvent sk relayUrl challenge now
    let noRelay = authEvent { evTags = [["challenge", challenge]] }
    validateAuthEvent relayUrl challenge now 600 noRelay
      `shouldBe` Left "missing relay tag"

  it "authEventRelay and authEventChallenge extract correctly" $ do
    let authEvent = buildAuthEvent sk relayUrl challenge now
    authEventRelay authEvent `shouldBe` Right relayUrl
    authEventChallenge authEvent `shouldBe` Right challenge

  it "authEventRelay rejects missing relay tag" $ do
    let authEvent = buildAuthEvent sk relayUrl challenge now
    let noRelay = authEvent { evTags = [["challenge", challenge]] }
    authEventRelay noRelay `shouldBe` Left "missing relay tag"

  it "authEventChallenge rejects missing challenge tag" $ do
    let authEvent = buildAuthEvent sk relayUrl challenge now
    let noChal = authEvent { evTags = [["relay", relayUrl]] }
    authEventChallenge noChal `shouldBe` Left "missing challenge tag"
