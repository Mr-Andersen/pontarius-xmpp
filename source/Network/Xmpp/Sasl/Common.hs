{-# OPTIONS_HADDOCK hide #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}

module Network.Xmpp.Sasl.Common where

import           Control.Applicative ((<$>))
import           Control.Monad
import           Control.Monad.Except
import qualified Data.Attoparsec.ByteString.Char8 as AP
import           Data.Bits
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import           Data.Maybe (maybeToList)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import           Data.Word (Word8)
import           Data.XML.Pickle
import           Data.XML.Types
import           Network.Xmpp.Marshal
import           Network.Xmpp.Sasl.StringPrep
import           Network.Xmpp.Sasl.Types
import           Network.Xmpp.Stream
import           Network.Xmpp.Types

import qualified System.Random as Random

import           Control.Monad.State.Strict

--makeNonce :: ExceptT AuthFailure (StateT StreamState IO) BS.ByteString
makeNonce :: IO BS.ByteString
makeNonce = do
    g <- liftIO Random.newStdGen
    return $ B64.encode . BS.pack . map toWord8 . take 15 $ Random.randoms g
  where
    toWord8 :: Int -> Word8
    toWord8 x = fromIntegral x :: Word8

-- The <auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/> element, with an
-- optional round-trip value.
saslInitE :: Text.Text -> Maybe Text.Text -> Element
saslInitE mechanism rt =
    Element "{urn:ietf:params:xml:ns:xmpp-sasl}auth"
        [("mechanism", [ContentText mechanism])]
        (maybeToList $ NodeContent . ContentText <$> rt)

-- SASL response with text payload.
saslResponseE :: Maybe Text.Text -> Element
saslResponseE resp =
    Element "{urn:ietf:params:xml:ns:xmpp-sasl}response"
    []
    (maybeToList $ NodeContent . ContentText <$> resp)

-- The <success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/> element.
xpSuccess :: PU [Node] (Maybe Text.Text)
xpSuccess = xpElemNodes "{urn:ietf:params:xml:ns:xmpp-sasl}success"
    (xpOption $ xpContent xpId)

-- Parses the incoming SASL data to a mapped list of pairs.
pairs :: BS.ByteString -> Either String Pairs
pairs = AP.parseOnly . flip AP.sepBy1 (void $ AP.char ',') $ do
    AP.skipSpace
    name <- AP.takeWhile1 (/= '=')
    _ <- AP.char '='
    qt <- ((AP.char '"' >> return True) `mplus` return False)
    content <- AP.takeWhile1 (AP.notInClass [',', '"'])
    when qt . void $ AP.char '"'
    return (name, content)

-- Failure element pickler.
xpFailure :: PU [Node] SaslFailure
xpFailure = xpWrap
    (\(txt, (failure, _, _)) -> SaslFailure failure txt)
    (\(SaslFailure failure txt) -> (txt,(failure,(),())))
    (xpElemNodes
        "{urn:ietf:params:xml:ns:xmpp-sasl}failure"
        (xp2Tuple
             (xpOption $ xpElem
                  "{urn:ietf:params:xml:ns:xmpp-sasl}text"
                  xpLangTag
                  (xpContent xpId))
        (xpElemByNamespace
             "urn:ietf:params:xml:ns:xmpp-sasl"
             xpSaslError
             (xpUnit)
             (xpUnit))))

xpSaslError :: PU Text.Text SaslError
xpSaslError = ("xpSaslError", "") <?>
        xpIso saslErrorFromText saslErrorToText
  where
    saslErrorToText SaslAborted              = "aborted"
    saslErrorToText SaslAccountDisabled      = "account-disabled"
    saslErrorToText SaslCredentialsExpired   = "credentials-expired"
    saslErrorToText SaslEncryptionRequired   = "encryption-required"
    saslErrorToText SaslIncorrectEncoding    = "incorrect-encoding"
    saslErrorToText SaslInvalidAuthzid       = "invalid-authzid"
    saslErrorToText SaslInvalidMechanism     = "invalid-mechanism"
    saslErrorToText SaslMalformedRequest     = "malformed-request"
    saslErrorToText SaslMechanismTooWeak     = "mechanism-too-weak"
    saslErrorToText SaslNotAuthorized        = "not-authorized"
    saslErrorToText SaslTemporaryAuthFailure = "temporary-auth-failure"
    saslErrorFromText "aborted" = SaslAborted
    saslErrorFromText "account-disabled" = SaslAccountDisabled
    saslErrorFromText "credentials-expired" = SaslCredentialsExpired
    saslErrorFromText "encryption-required" = SaslEncryptionRequired
    saslErrorFromText "incorrect-encoding" = SaslIncorrectEncoding
    saslErrorFromText "invalid-authzid" = SaslInvalidAuthzid
    saslErrorFromText "invalid-mechanism" = SaslInvalidMechanism
    saslErrorFromText "malformed-request" = SaslMalformedRequest
    saslErrorFromText "mechanism-too-weak" = SaslMechanismTooWeak
    saslErrorFromText "not-authorized" = SaslNotAuthorized
    saslErrorFromText "temporary-auth-failure" = SaslTemporaryAuthFailure
    saslErrorFromText _ = SaslNotAuthorized

-- Challenge element pickler.
xpChallenge :: PU [Node] (Maybe Text.Text)
xpChallenge = xpElemNodes "{urn:ietf:params:xml:ns:xmpp-sasl}challenge"
                      (xpOption $ xpContent xpId)

-- | Pickler for SaslElement.
xpSaslElement :: PU [Node] SaslElement
xpSaslElement = xpAlt saslSel
                [ xpWrap SaslSuccess   (\(SaslSuccess x)   -> x) xpSuccess
                , xpWrap SaslChallenge (\(SaslChallenge c) -> c) xpChallenge
                ]
  where
    saslSel (SaslSuccess   _) = 0
    saslSel (SaslChallenge _) = 1

-- | Add quotationmarks around a byte string.
quote :: BS.ByteString -> BS.ByteString
quote x = BS.concat ["\"",x,"\""]

saslInit :: Text.Text -> Maybe BS.ByteString -> ExceptT AuthFailure (StateT StreamState IO) ()
saslInit mechanism payload = do
    r <- lift . pushElement . saslInitE mechanism $
        Text.decodeUtf8 . encodeEmpty . B64.encode <$> payload
    case r of
        Right () -> return ()
        Left e  -> throwError $ AuthStreamFailure e
  where
    -- §6.4.2
    encodeEmpty "" = "="
    encodeEmpty x = x

-- | Pull the next element.
pullSaslElement :: ExceptT AuthFailure (StateT StreamState IO) SaslElement
pullSaslElement = do
    mbse <- lift $ pullUnpickle (xpEither xpFailure xpSaslElement)
    case mbse of
        Left e -> throwError $ AuthStreamFailure e
        Right (Left e) -> throwError $ AuthSaslFailure e
        Right (Right r) -> return r

-- | Pull the next element, checking that it is a challenge.
pullChallenge :: ExceptT AuthFailure (StateT StreamState IO) (Maybe BS.ByteString)
pullChallenge = do
  e <- pullSaslElement
  case e of
      SaslChallenge Nothing -> return Nothing
      SaslChallenge (Just scb64)
          | Right sc <- B64.decode . Text.encodeUtf8 $ scb64
             -> return $ Just sc
      _ -> throwError AuthOtherFailure -- TODO: Log

-- | Extract value from Just, failing with AuthOtherFailure on Nothing.
saslFromJust :: Maybe a -> ExceptT AuthFailure (StateT StreamState IO) a
saslFromJust Nothing = throwError $ AuthOtherFailure -- TODO: Log
saslFromJust (Just d) = return d

-- | Pull the next element and check that it is success.
pullSuccess :: ExceptT AuthFailure (StateT StreamState IO) (Maybe Text.Text)
pullSuccess = do
    e <- pullSaslElement
    case e of
        SaslSuccess x -> return x
        _ -> throwError $ AuthOtherFailure -- TODO: Log

-- | Pull the next element. When it's success, return it's payload.
-- If it's a challenge, send an empty response and pull success.
pullFinalMessage :: ExceptT AuthFailure (StateT StreamState IO) (Maybe BS.ByteString)
pullFinalMessage = do
    challenge2 <- pullSaslElement
    case challenge2 of
        SaslSuccess   x -> decode x
        SaslChallenge x -> do
            _b <- respond Nothing
            _s <- pullSuccess
            decode x
  where
    decode Nothing  = return Nothing
    decode (Just d) = case B64.decode $ Text.encodeUtf8 d of
        Left _e -> throwError $ AuthOtherFailure -- TODO: Log
        Right x -> return $ Just x

-- | Extract p=q pairs from a challenge.
toPairs :: BS.ByteString -> ExceptT AuthFailure (StateT StreamState IO) Pairs
toPairs ctext = case pairs ctext of
    Left _e -> throwError AuthOtherFailure -- TODO: Log
    Right r -> return r

-- | Send a SASL response element. The content will be base64-encoded.
respond :: Maybe BS.ByteString -> ExceptT AuthFailure (StateT StreamState IO) ()
respond m = do
    r <- lift . pushElement . saslResponseE . fmap (Text.decodeUtf8 . B64.encode) $ m
    case r of
        Left e -> throwError $ AuthStreamFailure e
        Right () -> return ()

-- | Run the appropriate stringprep profiles on the credentials.
-- May fail with 'AuthStringPrepFailure'
prepCredentials :: Text.Text -> Maybe Text.Text -> Text.Text
                -> ExceptT AuthFailure (StateT StreamState IO) (Text.Text, Maybe Text.Text, Text.Text)
prepCredentials authcid authzid password = case credentials of
    Nothing -> throwError $ AuthIllegalCredentials
    Just creds -> return creds
  where
    credentials = do
        ac <- normalizeUsername authcid
        az <- case authzid of
          Nothing -> Just Nothing
          Just az' -> Just <$> normalizeUsername az'
        pw <- normalizePassword password
        return (ac, az, pw)

-- | Bit-wise xor of byte strings
xorBS :: BS.ByteString -> BS.ByteString -> BS.ByteString
xorBS x y = BS.pack $ BS.zipWith xor x y

-- | Join byte strings with ","
merge :: [BS.ByteString] -> BS.ByteString
merge = BS.intercalate ","

-- | Infix concatenation of byte strings
(+++) :: BS.ByteString -> BS.ByteString -> BS.ByteString
(+++) = BS.append
