{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoOverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

-- | Crypto and keys needed for signing transactions.
module Frontend.Crypto.Ed25519
  ( -- * Types & Classes
    PublicKey(..)
  , PrivateKey(..)
  , Signature(..)
  , unverifiedUserSuppliedSignature
  , parseSignature
  -- * Creation
  , genKeyPair
  , deriveKeyPairFromPrivateKey
  -- * Verifying
  , verifySignature
  -- * Signing
  , mkSignature
  -- * Parsing
  , parseKeyPair
  , parsePublicKey
  , parsePrivateKey
  -- * Utilities
  , keyToText
  , keyToTextFuture
  , textToKey
  , textToKeyFuture
  , fromPactPublicKey
  , toPactPublicKey
  , unsafePublicKey
  )
  where

import           Control.Lens
import           Control.Monad
import           Control.Monad.Fail          (MonadFail)
import           Control.Newtype.Generics    (Newtype (..))
import           Data.Aeson                  hiding (Object)
import           Control.Monad.Except        (MonadError, throwError)
import qualified Data.Text as T
import           Data.ByteString             (ByteString)
import qualified Data.ByteString             as BS
import           Data.Text                   (Text)
import qualified Data.Text.Encoding          as T
import           GHC.Generics                (Generic)
import           Language.Javascript.JSaddle 

import           Pact.Types.Util             (encodeBase64UrlUnpadded, decodeBase64UrlUnpadded)

#ifdef ghcjs_HOST_OS
import Data.JSVal.Promise
#endif

import Common.Wallet
import Frontend.Foundation

--------------------------------------------------------------------------
#ifdef ghcjs_HOST_OS

--TODO: Should we make this its own js library? to guarantee that script always exists?
bsToBuffer :: ByteString -> JSM JSVal
bsToBuffer bs = do
  cardanoCryptoLib <- jsg @Text "lib"
  buffer           <- cardanoCryptoLib ! ("Buffer" :: Text)
  buffer ^. js1 @Text @[Word8] "from" (BS.unpack bs)

-- handlePromise :: -> Maybe JSVal
handlePromise :: JSVal -> JSM (Maybe JSVal)
handlePromise rawProm = do
  mProm <- fromJSValUnchecked rawProm
  case mProm of
    Nothing -> pure Nothing
    Just promise -> do
      prom <- liftIO $ await promise
      case prom of
        Left jsval -> pure Nothing
        Right jsval -> pure $ Just jsval

mnemonicToRootJS :: [ Text ] -> JSM (Maybe PrivateKey)
mnemonicToRootJS mnemonics = do
  --TODO: Make it hex?
  --TODO: validate 12 words
  let phrase = T.unwords mnemonics
  cardanoCryptoLib <- jsg @Text "lib"
  rawProm <- cardanoCryptoLib ^. js2 @Text @_ @Int "mnemonicToRootKeypair" phrase 3
  mPrv <- handlePromise rawProm
  case mPrv of
    Nothing -> pure Nothing
    Just prv -> (fmap . fmap) (PrivateKey . BS.pack) $ fromJSValUnchecked prv

genKeyPairFromRoot :: PrivateKey -> Int -> JSM (PrivateKey, PublicKey)
genKeyPairFromRoot (PrivateKey root) index = do
  cardanoCryptoLib <- jsg @Text "lib"
  rootBuf <- bsToBuffer root
  derivePriv <- cardanoCryptoLib ^. js3 @Text @_ @Int @Int "derivePrivate" rootBuf (fromIntegral (0x80000000 .|. index)) 2
  getPublic <- cardanoCryptoLib ^. js1 @Text "toKadenaPublic" derivePriv
  prv <- fmap BS.pack $ fromJSValUnchecked derivePriv
  pub <- fmap BS.pack $ fromJSValUnchecked getPublic
  pure (PrivateKey prv, PublicKey pub)
#endif

--------------------------------------------------------------------------
--
-- | PrivateKey with a Pact compatible JSON representation.
newtype PrivateKey = PrivateKey { unPrivateKey :: ByteString }
  deriving (Generic)
--
-- | Signature with a Pact compatible JSON representation.
newtype Signature = Signature { unSignature :: ByteString }
  deriving (Eq,Ord,Show,Generic)

unverifiedUserSuppliedSignature :: MonadFail m => Text -> m Signature
unverifiedUserSuppliedSignature = fmap Signature . decodeBase16M . T.encodeUtf8

-- | Parse just a public key with some sanity checks applied.
parseSignature :: MonadError Text m => Text -> m Signature
parseSignature = throwDecodingErr . textToKey <=< checkSig . T.strip

checkSig :: MonadError Text m => Text -> m Text
checkSig t =
    if len /= 128
      then throwError $ T.pack "Signature is not the right length"
      else pure t
  where
    len = T.length t

mkKeyPairFromJS :: MakeObject s => s -> JSM (PrivateKey, PublicKey)
mkKeyPairFromJS jsPair = do
  privKey <- fromJSValUnchecked =<< jsPair ^. js "secretKey"
  pubKey <- fromJSValUnchecked =<< jsPair ^. js "publicKey"
  pure ( PrivateKey . BS.pack $ privKey
       , PublicKey . BS.pack $ pubKey
       )

-- | Generate a `PublicKey`, `PrivateKey` keypair.
genKeyPair :: MonadJSM m => m (PrivateKey, PublicKey)
genKeyPair = liftJSM $ eval "nacl.sign.keyPair()" >>= mkKeyPairFromJS

-- | Create a signature based on the given payload and `PrivateKey`.
verifySignature :: MonadJSM m => ByteString -> Signature -> PublicKey -> m Bool
verifySignature msg (Signature sig) (PublicKey key) = liftJSM $ do
  jsSign <- eval "(function(m, sig, pub) {return window.nacl.sign.detached.verify(Uint8Array.from(m), Uint8Array.from(sig), Uint8Array.from(pub));})"
  jsSig <- call jsSign valNull [BS.unpack msg, BS.unpack sig, BS.unpack key]
  fromJSValUnchecked jsSig
  {- pure $ Signature BS.empty -}

-- | Create a signature based on the given payload and `PrivateKey`.
mkSignature :: MonadJSM m => ByteString -> PrivateKey -> m Signature
mkSignature msg (PrivateKey key) = liftJSM $ do
  jsSign <- eval "(function(m, k) {return window.nacl.sign.detached(Uint8Array.from(m), Uint8Array.from(k));})"
  jsSig <- call jsSign valNull [BS.unpack msg, BS.unpack key]
  Signature . BS.pack <$> fromJSValUnchecked jsSig
  {- pure $ Signature BS.empty -}

-- | Parse a private key with additional checks given the corresponding public key.
-- `parsePublicKey` and `parsePrivateKey`.
parseKeyPair :: MonadError Text m => PublicKey -> Text -> m (PublicKey, Maybe PrivateKey)
parseKeyPair pubKey priv = do
    privKey <- parsePrivateKey pubKey priv
    unless (sanityCheck pubKey privKey) $ do
      throwError $ T.pack "Private key is not compatible with public key"
    pure (pubKey, privKey)
  where
    sanityCheck (PublicKey pubRaw) = \case
      Nothing -> True
      Just (PrivateKey privRaw) -> BS.isSuffixOf pubRaw privRaw

-- | Derive a keypair from the private key
deriveKeyPairFromPrivateKey :: MonadJSM m => ByteString -> m (PrivateKey, PublicKey)
deriveKeyPairFromPrivateKey privKeyBS = liftJSM $ do
  jsFrom <- eval "(function(k) {return window.nacl.sign.keyPair.fromSecretKey(Uint8Array.from(k));})"
  call jsFrom valNull [BS.unpack privKeyBS] >>= mkKeyPairFromJS

-- | Parse a private key, with some basic sanity checking.
parsePrivateKey :: MonadError Text m => PublicKey -> Text -> m (Maybe PrivateKey)
parsePrivateKey pubKey = throwDecodingErr . textToMayKey <=< throwWrongLengthPriv pubKey . T.strip

-- Utilities:

-- | Display key in Base64 format, as expected by some future Pact version (maybe).
--
--   Despite the name, this function is also used for serializing signatures.
keyToTextFuture :: (Newtype key, O key ~ ByteString) => key -> Text
keyToTextFuture = safeDecodeUtf8 . encodeBase64UrlUnpadded . unpack


-- | Read a key in Base64 format, as exepected by Pact in some future..? .
--
--   Despite the name, this function is also used for reading signatures.
textToKeyFuture
  :: (Newtype key, O key ~ ByteString, Monad m, MonadFail m)
  => Text
  -> m key
textToKeyFuture = fmap pack . decodeBase64M . T.encodeUtf8


-- Internal parsing helpers:
--

textToMayKey :: (Newtype key, O key ~ ByteString, MonadFail m) => Text -> m (Maybe key)
textToMayKey t =
  if T.null t
     then pure Nothing
     else Just <$> textToKey t

-- | Throw in case of invalid length, but accept zero length.
throwWrongLengthPriv :: MonadError Text m => PublicKey -> Text -> m Text
throwWrongLengthPriv pk t
  | T.null t = pure t
  | T.length t == 64 = do
    when (t == keyToText pk) $ throwError $ T.pack "Private key is the same as public key"
    pure $ t <> keyToText pk -- User entered a private key, append the public key
  | T.length t == 128 = pure t -- User entered a private+public key
  | otherwise = throwError $ T.pack "Key has unexpected length"


-- Boring instances:

instance ToJSON PrivateKey where
  toEncoding = toEncoding . keyToText
  toJSON = toJSON . keyToText

instance FromJSON PrivateKey where
  parseJSON = fmap pack . decodeBase16M <=< fmap T.encodeUtf8 . parseJSON

instance ToJSON Signature where
  toEncoding = toEncoding . keyToText
  toJSON = toJSON . keyToText

instance FromJSON Signature where
  parseJSON = fmap pack . decodeBase16M <=< fmap T.encodeUtf8 . parseJSON

decodeBase64M :: (Monad m, MonadFail m) => ByteString -> m ByteString
decodeBase64M i =
  case decodeBase64UrlUnpadded i of
    Left err -> fail err
    Right v -> pure v

instance Newtype PrivateKey

instance Newtype Signature
