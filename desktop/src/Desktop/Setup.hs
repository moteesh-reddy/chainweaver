{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Wallet setup screens
module Desktop.Setup (runSetup, form, kadenaWalletLogo) where

import Control.Error (hush,isRight)
import Control.Applicative (liftA2)
import Control.Lens ((<>~), (?~), (%~))
import Control.Monad (unless,void,join)
import Control.Monad.Fix (MonadFix)
import Control.Monad.IO.Class
import Data.Maybe (isNothing, fromMaybe)
import Data.Bifunctor
import Data.ByteArray (ByteArrayAccess)
import Data.ByteString (ByteString)
import Data.String (IsString, fromString)
import Data.Functor ((<&>), ($>))
import Data.Text (Text)
import Reflex.Dom.Core
import qualified Cardano.Crypto.Wallet as Crypto
import qualified Crypto.Encoding.BIP39 as Crypto
import qualified Crypto.Encoding.BIP39.English as Crypto
import qualified Crypto.Random.Entropy
import qualified Data.ByteArray as BA
import qualified Data.List as L
import qualified Data.Set as S
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import Frontend.UI.Button
import Frontend.UI.Widgets
import Obelisk.Generated.Static

-- | Used for changing the settings in the passphrase widget.
data PassphraseStage
  = Setup
  | Recover
  deriving (Show, Eq)

-- | Wrapper for the index of the word in the passphrase
newtype WordKey = WordKey { _unWordKey :: Int }
  deriving (Show, Eq, Ord, Enum)

-- | Setup stage
data WalletScreen
  = Password
  | CreatePassphrase
  | VerifyPassphrase
  | RecoverPassphrase
  | SplashScreen
  | Done
  deriving (Show, Eq, Ord)

walletScreenClass :: WalletScreen -> Text
walletScreenClass = walletClass . T.toLower . tshow

wordsToPhraseMap :: [Text] -> Map.Map WordKey Text
wordsToPhraseMap = Map.fromList . zip [WordKey 1 ..]

walletClass :: Text -> Text
walletClass = mappend "wallet__"

walletDiv :: MonadWidget t m => Text -> m a -> m a
walletDiv t = divClass (walletClass t)

mkPhraseMapFromMnemonic
  :: forall mw.
     Crypto.ValidMnemonicSentence mw
  => Crypto.MnemonicSentence mw
  -> Map.Map WordKey Text
mkPhraseMapFromMnemonic = wordsToPhraseMap . T.words . baToText
  . Crypto.mnemonicSentenceToString @mw Crypto.english

showWordKey :: WordKey -> Text
showWordKey = T.pack . show . _unWordKey

-- | Convenience function for unpacking byte array things into 'Text'
baToText :: ByteArrayAccess b => b -> Text
baToText = T.decodeUtf8 . BA.pack . BA.unpack

textTo :: IsString a => Text -> a
textTo = fromString . T.unpack

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | Form wrapper which will automatically handle submit on enter
form :: DomBuilder t m => Text -> m a -> m a
form c = elAttr "form" ("onsubmit" =: "return false;" <> "class" =: c)

-- | Wallet logo
kadenaWalletLogo :: DomBuilder t m => m ()
kadenaWalletLogo = divClass "logo" $ do
  elAttr "img" ("src" =: static @"img/Klogo.png" <> "class" =: walletClass "kadena-logo") blank

type SetupWF t m = Workflow t m (Event t Crypto.XPrv)

finishSetupWF :: (Reflex t, Applicative m) => a -> m (Event t x, a)
finishSetupWF = pure . (,) never

walletSetupRecoverHeader
  :: MonadWidget t m
  => WalletScreen
  -> m (Event t ())
walletSetupRecoverHeader currentScreen = walletDiv "workflow-header" $ do
  eBack <- fmap (domEvent Click . fst) . walletDiv "back-link"
    . el "span" . elClass' "i" "fa fa-3x fa-chevron-left" $ text "Back"

  elClass "ol" (walletClass "workflow-icons") $ do
    faEl "1" "Password" Password
    faEl "2" "Recovery" CreatePassphrase
    faEl "3" "Verify" VerifyPassphrase
    faEl "4" "Done" Done

  pure eBack
  where
    faEl n lbl sid =
      let
        isActive = currentScreen == sid
      in
        elClass "li" (walletClass "workflow-icon" <> if isActive then " active" else T.empty) $ do
          elClass "div" (walletClass "workflow-icon-circle" <> (" wallet__workflow-screen-" <> T.toLower lbl)) $
            walletDiv "workflow-icon-inner" $
            if isActive then
              elClass "i" ("fa fa-check fa-lg fa-inverse" <> walletClass "workflow-icon-active") blank
            else
              text n
          text lbl

runSetup :: forall t m. MonadWidget t m => m (Event t Crypto.XPrv)
runSetup = divClass "fullscreen" $ divClass "wrapper" $ 
  switchDyn <$> workflow splashScreen

splashScreen :: MonadWidget t m => SetupWF t m
splashScreen = Workflow $ walletDiv "splash" $ do
  elAttr "img" ("src" =: static @"img/Wallet_Graphic_1.png" <> "class" =: walletClass "splash-bg") blank
  kadenaWalletLogo

  (agreed, create, recover) <- walletDiv "splash-terms-buttons" $ do
    agreed <- fmap value $ uiCheckbox def False def $ walletDiv "terms-conditions-checkbox" $ do
      text "I have read & agree to the "
      elAttr "a" ("href" =: "https://kadena.io/" <> "target" =: "_blank") (text "Terms of Service")

    create <- confirmButton def "Create a new wallet"
    recover <- uiButton btnCfgSecondary $ text "Restore existing wallet"
    pure (agreed, create, recover)

  let hasAgreed = gate (current agreed)

  finishSetupWF $ leftmost
    [ createNewWallet <$ hasAgreed create
    , recoverWallet <$ hasAgreed recover
    ]

data BIP39PhraseError
  = BIP39PhraseError_Dictionary Crypto.DictionaryError
  | BIP39PhraseError_MnemonicWordsErr Crypto.MnemonicWordsError
  | BIP39PhraseError_InvalidPhrase

passphraseLen :: Int
passphraseLen = 12

recoverWallet :: MonadWidget t m => SetupWF t m
recoverWallet = Workflow $ do
  eBack <- walletSetupRecoverHeader RecoverPassphrase

  el "h1" $ text "Recover your wallet"
  el "p" $ text "Type in your recovery phrase"

  rec 
    phraseMap <- holdDyn (wordsToPhraseMap $ replicate passphraseLen T.empty)
      $ flip Map.union <$> current phraseMap <@> onPhraseMapUpdate
    onPhraseMapUpdate <- passphraseWidget phraseMap (pure Recover)

  let sentenceOrError = ffor phraseMap $ \pm -> do
        phrase <- first BIP39PhraseError_MnemonicWordsErr . Crypto.mnemonicPhrase @12 $ textTo <$> Map.elems pm
        unless (Crypto.checkMnemonicPhrase Crypto.english phrase) $ Left BIP39PhraseError_InvalidPhrase
        first BIP39PhraseError_Dictionary $ Crypto.mnemonicPhraseToMnemonicSentence Crypto.english phrase

  passphrase <- divClass "checkbox-wrapper" $ do
    usePassphrase <- fmap value $ uiCheckbox def False def $ text "Use a BIP39 passphrase"
    fmap value $ uiInputElement $ def
      & initialAttributes .~
        "type" =: "password" <>
        "placeholder" =: "BIP39 passphrase" <>
        "class" =: "hidden passphrase"
      & modifyAttributes .~ ffor (updated usePassphrase)
        (\u -> if u then "class" =: Just "input passphrase" else "class" =: Just "hidden passphrase")

  dyn_ $ ffor sentenceOrError $ \case
    Right _ -> pure ()
    Left e -> divClass "message-wrapper" $ divClass "message" $ text $ case e of
      BIP39PhraseError_MnemonicWordsErr (Crypto.ErrWrongNumberOfWords actual expected)
        -> "Wrong number of words: expected " <> tshow expected <> ", but got " <> tshow actual
      BIP39PhraseError_InvalidPhrase
        -> "Invalid phrase"
      BIP39PhraseError_Dictionary (Crypto.ErrInvalidDictionaryWord word)
        -> "Invalid word in phrase: " <> baToText word

  let toSeed :: Crypto.ValidMnemonicSentence mw => Text -> Crypto.MnemonicSentence mw -> Crypto.Seed
      toSeed p s = Crypto.sentenceToSeed s Crypto.english $ textTo p

      eSeedUpdated = attachWithMaybe (\p -> hush . fmap (toSeed p))
        (current passphrase)
        (updated sentenceOrError)

      waitingForPhrase = do
        text "waiting for the passphrase"
        pure never

      withSeedConfirmPassword seed = do
        dSetPw <- holdDyn Nothing =<< fmap pure <$> setPassword (pure seed)
        continue <- continueButton (fmap isNothing dSetPw)
        pure $ tagMaybe (current dSetPw) continue

  dSetPassword <- widgetHold waitingForPhrase $
    withSeedConfirmPassword <$> eSeedUpdated

  pure
    ( switchDyn dSetPassword
    , splashScreen <$ eBack
    )

passphraseWordElement
  :: MonadWidget t m
  => Dynamic t PassphraseStage
  -> WordKey
  -> Dynamic t Text
  -> m (Event t Text)
passphraseWordElement currentStage k wrd = walletDiv "passphrase-widget-elem-wrapper" $ do
  pb <- getPostBuild

  walletDiv "passphrase-widget-key-wrapper" $
    text (showWordKey k)
  
  let
    commonAttrs cls =
      "type" =: "text" <>
      "size" =: "8" <>
      "class" =: walletClass cls

  void . uiInputElement $ def
    & inputElementConfig_initialValue .~ "********"
    & initialAttributes .~ (commonAttrs "passphrase-widget-word-hider" <> "disabled" =: "true")

  fmap _inputElement_input $ walletDiv "passphrase-widget-word-wrapper". uiInputElement $ def
    & inputElementConfig_setValue .~ (current wrd <@ pb)
    & initialAttributes .~ commonAttrs "passphrase-widget-word"
    & modifyAttributes .~ (("readonly" =:) . canEditOnRecover <$> current currentStage <@ pb)

  where
    canEditOnRecover Recover = Nothing
    canEditOnRecover Setup = Just "true"

passphraseWidget
  :: MonadWidget t m
  => Dynamic t (Map.Map WordKey Text)
  -> Dynamic t PassphraseStage
  -> m (Event t (Map.Map WordKey Text))
passphraseWidget dWords dStage = do
  walletDiv "passphrase-widget-wrapper" $
    listViewWithKey dWords (passphraseWordElement dStage)

continueButton
  :: MonadWidget t m
  => Dynamic t Bool
  -> m (Event t ())
continueButton isDisabled = 
  walletDiv "continue-button" $
    confirmButton (def & uiButtonCfg_disabled .~ isDisabled) "Continue"

createNewWallet :: forall t m. MonadWidget t m => SetupWF t m
createNewWallet = Workflow $ do
  eBack <- walletSetupRecoverHeader Password
  ePb <- getPostBuild

  el "h1" $ text "Set a password"
  walletDiv "new-wallet-password-text" $ do
    el "div" $ text "Enter a strong and unique password"
    el "div" $ text "to protect acces to your Chainweaver wallet"

  (eGenError, eGenSuccess) <- fmap fanEither . performEvent $ genMnemonic <$ ePb

  let
    generating = do
      dynText =<< holdDyn "Generating your mnemonic..." eGenError
      pure never

    proceed :: Crypto.MnemonicSentence 12 -> m (Event t (SetupWF t m))
    proceed mnem = do
      dPassword <- setPassword (pure $ Crypto.sentenceToSeed mnem Crypto.english "")
        >>= holdDyn Nothing . fmap pure
      continue <- continueButton (fmap isNothing dPassword) 
      pure $ precreatePassphraseWarning dPassword mnem <$ continue
      
  dContinue <- widgetHold generating (proceed <$> eGenSuccess)

  finishSetupWF $ leftmost
    [ splashScreen <$ eBack
    , switchDyn dContinue
    ]

precreatePassphraseWarning
  :: MonadWidget t m
  => Dynamic t (Maybe Crypto.XPrv)
  -> Crypto.MnemonicSentence 12
  -> SetupWF t m
precreatePassphraseWarning dPassword mnemonicSentence = Workflow $ do
  eBack <- walletSetupRecoverHeader Password
  
  walletDiv "recovery-phrase-warning" $ do
    line "In the next step you will record your 12 word recovery phrase."
    line "Your recovery phrase makes it easy to restore your wallet on a new device."
    line "Anyone with this phrase can take control your wallet, keep this phrase private."

  walletDiv "recovery-phrase-highlighted-warning" $
    line "Kadena cannot access your recovery phrase if lost, please store it safely."

  dUnderstand <- fmap value $ walletDiv "checkbox-wrapper" $ uiCheckbox def False def
    $ text "I understand that if I lose my recovery phrase, I will not be able to restore my wallet."

  eContinue <- continueButton (fmap not dUnderstand)

  finishSetupWF $ leftmost
    [ createNewWallet <$ eBack
    , createNewPassphrase dPassword mnemonicSentence <$ eContinue
    ]
  where
    line = el "div" . text

doneScreen
  :: MonadWidget t m
  => Crypto.XPrv
  -> SetupWF t m
doneScreen passwd = Workflow $ do
  eBack <- walletSetupRecoverHeader Done

  el "h1" $ text "Wallet Created"

  eContinue <- walletDiv "continue-button" $
    confirmButton def "Done"

  pure ( passwd <$ eContinue
       , createNewWallet <$ eBack
       )

-- | UI for generating and displaying a new mnemonic sentence.
createNewPassphrase
  :: MonadWidget t m
  => Dynamic t (Maybe Crypto.XPrv)
  -> Crypto.MnemonicSentence 12
  -> SetupWF t m
createNewPassphrase dPassword mnemonicSentence = Workflow $ do
  eBack <- walletSetupRecoverHeader CreatePassphrase

  el "h1" $ text "Record Recovery Phrase"
  walletDiv "record-phrase-msg" $ do
    el "div" $ text "Write down or copy these words in the correct order and store them safely."
    el "div" $ text "The recovery words are hidden for security. Mouseover the numbers to reveal."
        
  rec
    dPassphrase <- passphraseWidget dPassphrase (pure Setup)
      >>= holdDyn (mkPhraseMapFromMnemonic mnemonicSentence)

  eCopyClick <- elClass "div" (walletClass "recovery-phrase-copy") $ do
    uiButton def $ elClass "span" (walletClass "recovery-phrase-copy-word") $ do
      elClass "i" "fa fa-copy" blank
      text "Copy"
      
    -- <a class="btn btn-default btn-sm" href="#">
    --   <i class="fa fa-cog"></i> Settings</a>

  eCopySuccess <- copyToClipboard $
    T.unwords . Map.elems <$> current dPassphrase <@ eCopyClick 


  dIsStored <- fmap value $ walletDiv "checkbox-wrapper" $ uiCheckbox def False def
    $ text "I have safely stored my recovery phrase."

  eContinue <- continueButton (fmap not dIsStored)

  finishSetupWF $ leftmost
    [ createNewWallet <$ eBack
    , confirmPhrase dPassword mnemonicSentence <$ eContinue
    ]

-- | UI for mnemonic sentence confirmation: scramble the phrase, make the user
-- choose the words in the right order.
confirmPhrase
  :: MonadWidget t m
  => Dynamic t (Maybe Crypto.XPrv)
  -> Crypto.MnemonicSentence 12
  -- ^ Mnemonic sentence to confirm
  -> SetupWF t m
confirmPhrase dPassword mnemonicSentence = Workflow $ do
  eBack <- walletSetupRecoverHeader VerifyPassphrase

  el "h1" $ text "Verify Recovery Phrase"
  walletDiv "verify-phrase-msg" $ do
    el "div" $ text "Please confirm your recovery phrase by"
    el "div" $ text "typing the words in the correct order."

  let actualMap = mkPhraseMapFromMnemonic mnemonicSentence

  rec
    onPhraseUpdate <- passphraseWidget dConfirmPhrase (pure Recover)

    dConfirmPhrase <- holdDyn (wordsToPhraseMap $ replicate passphraseLen T.empty)
      $ flip Map.union <$> current dConfirmPhrase <@> onPhraseUpdate

  let done = (== actualMap) <$> dConfirmPhrase

  -- TODO: Remove me before release, I'm a dev hack
  skip <- uiButton btnCfgTertiary $ text "Skip"

  continue <- continueButton (fmap not done)

  finishSetupWF $ leftmost
    [ doneScreen <$> tagMaybe (current dPassword) (leftmost [continue, skip])
    , createNewWallet <$ eBack
    ]

setPassword
  :: MonadWidget t m
  => Dynamic t Crypto.Seed
  -> m (Event t Crypto.XPrv)
setPassword dSeed = form "" $ do
  let uiPassword ph = uiInputElement $ def & initialAttributes .~
                      ( "type" =: "password" <>
                        "placeholder" =: ph <>
                        "class" =: walletClass "password"
                      )

  p1elem <- uiPassword "Enter password"
  p2elem <- uiPassword "Confirm password" 

  let p1 = current $ value p1elem
      p2 = current $ value p2elem

      inputsNotEmpty = not <$> liftA2 (||) (T.null <$> p1) (T.null <$> p2)

  eCheckPassword <- fmap (gate inputsNotEmpty) $ delay 0.4 $ leftmost
    [ _inputElement_input p1elem
    , _inputElement_input p2elem
    ]

  let (err, pass) = fanEither $
        checkPassword <$> p1 <*> p2 <@ eCheckPassword

  lastError <- holdDyn Nothing $ leftmost
    [ Just <$> err
    , Nothing <$ pass
    ]

  let dMsgClass = lastError <&> \m -> walletClass "message " <> case m of
        Nothing -> walletClass "hide-pw-error"
        Just _ -> walletClass "show-pw-error"

  elDynClass "div" dMsgClass $
    dynText $ fromMaybe T.empty <$> lastError

  pure $ Crypto.generate <$> current dSeed <@> (T.encodeUtf8 <$> pass)

  where
    -- TODO: CHANGE BACK TO 10 BEFORE MERGE.
    -- makes workflow faster to move through
    minPasswordLength = 1
    checkPassword p1 p2
      | T.length p1 < minPasswordLength =
          Left $ "Passwords must be at least " <> tshow minPasswordLength <> " characters long"
      | p1 /= p2 =
          Left "Passwords must match"
      | otherwise =
          Right p1

-- | Generate a 12 word mnemonic sentence, using cryptonite.
--
-- These values for entropy must be set according to a predefined table:
-- https://github.com/kadena-io/cardano-crypto/blob/master/src/Crypto/Encoding/BIP39.hs#L208-L218
genMnemonic :: MonadIO m => m (Either Text (Crypto.MnemonicSentence 12))
genMnemonic = liftIO $ bimap tshow Crypto.entropyToWords . Crypto.toEntropy @128
  -- This size must be a 1/8th the size of the 'toEntropy' size: 128 / 8 = 16
  <$> Crypto.Random.Entropy.getEntropy @ByteString 16

