{-# LANGUAGE OverloadedStrings #-}

-- | NIP-57 lightning zaps: requests, receipts, and invoice amounts.
--
-- Two events with opposite visibility: a zap *request* (kind 9734) is signed
-- by the sender and sent to the recipient's LNURL callback, never published
-- to relays; a zap *receipt* (kind 9735) is published by the recipient's
-- wallet after the invoice is paid. The receipt names the recipient in @p@,
-- the sender in @P@ when they chose to be public, the invoice in @bolt11@,
-- and the original request as JSON in @description@.
--
-- The spec is candid that a receipt is not proof of payment -- trusting it
-- means trusting its author -- so validation is structural (required tags
-- present, amounts agreeing) rather than a verdict. Fetching LNURL
-- endpoints and paying invoices is IO and lives with the callers.
module Krivostr.Nip.Nip57
  ( zapRequestKind
  , zapReceiptKind
  , ZapRequest(..)
  , zapRequestOf
  , buildZapRequestTags
  , ZapReceipt(..)
  , zapReceiptOf
  , invoiceAmountMsats
  , invoiceAmountSats
  ) where

import Data.Aeson (eitherDecodeStrict)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Krivostr.Event

-- | Kind 9734: signed by the sender, sent to the LNURL callback.
zapRequestKind :: Int
zapRequestKind = 9734

-- | Kind 9735: published by the recipient's wallet after payment.
zapReceiptKind :: Int
zapReceiptKind = 9735

-- | A parsed zap request.
data ZapRequest = ZapRequest
  { zrRecipient :: !Text
  , zrAmountMsats :: !(Maybe Integer)
  , zrRelays    :: ![Text]
  , zrLnurl     :: !(Maybe Text)
  , zrEvent     :: !(Maybe Text)
  , zrAddress   :: !(Maybe Text)
  , zrComment   :: !Text
  } deriving (Show, Eq)

-- | Parse a kind 9734 event. The recipient @p@ tag is mandatory -- a
-- request without one names nobody to pay -- and the amount must parse when
-- present. Anything else is not a zap request.
zapRequestOf :: Event -> Maybe ZapRequest
zapRequestOf e
  | evKind e /= zapRequestKind = Nothing
  | otherwise = case (firstOf "p", parseAmount (firstOf "amount")) of
      (Just recipient, Just amount) -> Just ZapRequest
        { zrRecipient = recipient
        , zrAmountMsats = amount
        , zrRelays = relaysOf e
        , zrLnurl = firstOf "lnurl"
        , zrEvent = firstOf "e"
        , zrAddress = firstOf "a"
        , zrComment = evContent e
        }
      _ -> Nothing
  where
    firstOf name = case [v | (t : v : _) <- evTags e, t == name] of
      (v : _) -> Just v
      _       -> Nothing

    relaysOf ev = case [rest | ("relays" : rest) <- evTags ev] of
      (rs : _) -> rs
      _        -> []

    -- A missing amount is no amount; a present one must be millisats.
    parseAmount Nothing  = Just Nothing
    parseAmount (Just t) = case reads (T.unpack t) of
      [(n, "")] | n >= 0 -> Just (Just n)
      _                  -> Nothing

-- | The tags for a zap request: relays, amount in millisats, the recipient,
-- and the zapped event or address when zapping something rather than
-- someone. The comment rides in the content, not the tags.
buildZapRequestTags :: Text -> Integer -> [Text] -> Maybe Text -> Maybe Text -> Maybe Text -> [[Text]]
buildZapRequestTags recipient msats relays lnurl eventId address =
  [["relays"] ++ relays]
    ++ [["amount", T.pack (show msats)]]
    ++ [["p", recipient]]
    ++ maybe [] (\l -> [["lnurl", l]]) lnurl
    ++ maybe [] (\i -> [["e", i]]) eventId
    ++ maybe [] (\a -> [["a", a]]) address

-- | A parsed zap receipt.
data ZapReceipt = ZapReceipt
  { zpRecipient :: !Text
  , zpSender    :: !(Maybe Text)
  , zpEvent     :: !(Maybe Text)
  , zpAddress   :: !(Maybe Text)
  , zpBolt11    :: !Text
  , zpRequest   :: !(Maybe ZapRequest)
  , zpPreimage  :: !(Maybe Text)
  } deriving (Show, Eq)

-- | Parse a kind 9735 event. @p@, @bolt11@, and @description@ are mandatory;
-- the description is the JSON zap request, parsed when it parses. A receipt
-- whose description is not a zap request is still a receipt -- the invoice
-- is the claim, and the request is corroboration -- so a bad description
-- yields 'Nothing' for the request rather than rejecting the receipt.
zapReceiptOf :: Event -> Maybe ZapReceipt
zapReceiptOf e
  | evKind e /= zapReceiptKind = Nothing
  | otherwise = case (firstOf "p", firstOf "bolt11", firstOf "description") of
      (Just recipient, Just invoice, Just desc) -> Just ZapReceipt
        { zpRecipient = recipient
        , zpSender = firstOf "P"
        , zpEvent = firstOf "e"
        , zpAddress = firstOf "a"
        , zpBolt11 = invoice
        , zpRequest = case eitherDecodeStrict (TE.encodeUtf8 desc) of
            Right ev -> zapRequestOf ev
            Left _   -> Nothing
        , zpPreimage = firstOf "preimage"
        }
      _ -> Nothing
  where
    firstOf name = case [v | (t : v : _) <- evTags e, t == name] of
      (v : _) -> Just v
      _       -> Nothing

-- | The millisats encoded in a bolt11 invoice, if it encodes any. Invoices
-- without an amount are valid -- any amount may be paid -- so absence is
-- 'Nothing', not a failure. A multiplier that does not divide evenly into
-- millisats is likewise 'Nothing': rounding an amount up would overpay.
invoiceAmountMsats :: Text -> Maybe Integer
invoiceAmountMsats invoice = do
  rest <- T.stripPrefix "ln" invoice
  let amountPart = T.dropWhile (not . isDigit) rest
  (digits, afterDigits) <- Just (T.span isDigit amountPart)
  guard (not (T.null digits))
  amount <- readInteger digits
  -- At most one multiplier character follows the digits; whatever comes
  -- after belongs to the invoice data and is ignored. Without a multiplier
  -- the digit run may bleed into the data part -- inherent to reading the
  -- amount without a full bech32 decode, so amountless invoices in the wild
  -- still read as 'Nothing' only when no digits lead.
  let base = amount * 100000000000
  case T.uncons afterDigits of
    Just (c, _) | c `elem` ("munp" :: String) -> applyMult c base
    _ -> Just base
  where
    isDigit c = c >= '0' && c <= '9'
    guard True  = Just ()
    guard False = Nothing
    readInteger t = case reads (T.unpack t) of
      [(n, "")] -> Just n
      _         -> Nothing
    applyMult 'm' base = Just (base `div` 1000)
    applyMult 'u' base = Just (base `div` 1000000)
    applyMult 'n' base = Just (base `div` 1000000000)
    applyMult 'p' base
      | base `mod` 1000000000000 == 0 = Just (base `div` 1000000000000)
      | otherwise = Nothing
    applyMult _ _ = Nothing

-- | Whole sats in an invoice, if it encodes a whole number of them.
invoiceAmountSats :: Text -> Maybe Integer
invoiceAmountSats invoice = do
  msats <- invoiceAmountMsats invoice
  guard (msats `mod` 1000 == 0)
  pure (msats `div` 1000)
  where
    guard True  = Just ()
    guard False = Nothing
