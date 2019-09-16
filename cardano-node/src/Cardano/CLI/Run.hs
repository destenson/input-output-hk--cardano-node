{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE NumericUnderscores         #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE StrictData                 #-}
{-# LANGUAGE TypeApplications           #-}

{-# OPTIONS_GHC -Wno-all-missed-specialisations #-}
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

module Cardano.CLI.Run (
    CliError (..)
  , ClientCommand(..)
  , runCommand
  --
  , NewDirectory(..)
  , SigningKeyFile(..)
  , NewSigningKeyFile(..)
  , VerificationKeyFile(..)
  , NewVerificationKeyFile(..)
  , CertificateFile(..)
  , NewCertificateFile(..)
  , TxFile(..)
  , NewTxFile(..)
  ) where

import           Cardano.Prelude hiding (option, show, trace)

import           Codec.Serialise (serialise)
import           Control.Monad.Trans.Except (ExceptT)
import qualified Data.ByteString.Lazy as LB
import           Data.Semigroup ((<>))
import qualified Data.Text.Lazy.IO as TL
import qualified Data.Text.Lazy.Builder as Builder
import qualified Formatting as F
import           System.Directory (doesPathExist)

import qualified Cardano.Chain.Common as Common
import qualified Cardano.Chain.Delegation as Delegation
import qualified Cardano.Chain.Genesis as Genesis
import           Cardano.Chain.Slotting (EpochNumber(..))
import qualified Cardano.Chain.UTxO as UTxO
import           Cardano.Crypto (ProtocolMagicId)
import qualified Cardano.Crypto.Hashing as Crypto
import qualified Cardano.Crypto.Signing as Crypto
import qualified Test.Cardano.Chain.Genesis.Dummy as Dummy

import           Cardano.CLI.Delegation
import           Cardano.CLI.Genesis
import           Cardano.CLI.Key
import           Cardano.CLI.Ops
import           Cardano.CLI.Tx
import           Cardano.Config.CommonCLI
import           Cardano.Config.Presets (mainnetConfiguration)
import           Cardano.Common.Orphans ()
import           Cardano.Common.Protocol
import           Cardano.Node.Configuration.Topology


-- | Sub-commands of 'cardano-cli'.
data ClientCommand
  = Genesis
    NewDirectory
    GenesisParameters
  | PrettySigningKeyPublic
    SigningKeyFile
  | MigrateDelegateKeyFrom
    Protocol
    NewSigningKeyFile
    SigningKeyFile
  | DumpHardcodedGenesis
    NewDirectory
  | PrintGenesisHash
    GenesisFile
  | PrintSigningKeyAddress
    Common.NetworkMagic  -- TODO:  consider deprecation in favor of ProtocolMagicId,
                         --        once Byron is out of the picture.
    SigningKeyFile
  | Keygen
    NewSigningKeyFile
    PasswordRequirement
  | ToVerification
    SigningKeyFile
    NewVerificationKeyFile

    --- Delegation Related Commands ---

  | IssueDelegationCertificate
    ProtocolMagicId
    EpochNumber
    -- ^ The epoch from which the delegation is valid.
    SigningKeyFile
    -- ^ The issuer of the certificate, who delegates their right to sign blocks.
    VerificationKeyFile
    -- ^ The delegate, who gains the right to sign blocks on behalf of the issuer.
    NewCertificateFile
    -- ^ Filepath of the newly created delegation certificate.
  | CheckDelegation
    ProtocolMagicId
    CertificateFile
    VerificationKeyFile
    VerificationKeyFile

    -----------------------------------

  | SubmitTx
    TopologyInfo
    TxFile
    -- ^ Filepath of transaction to submit.
    CommonCLI
  | SpendGenesisUTxO
    NewTxFile
    -- ^ Filepath of the newly created transaction.
    SigningKeyFile
    -- ^ Signing key of genesis UTxO owner.
    Common.Address
    -- ^ Genesis UTxO address.
    (NonEmpty UTxO.TxOut)
    -- ^ Tx output.
    CommonCLI
  | SpendUTxO
    NewTxFile
    -- ^ Filepath of the newly created transaction.
    SigningKeyFile
    -- ^ Signing key of Tx underwriter.
    (NonEmpty UTxO.TxIn)
    -- ^ Inputs available for spending to the Tx underwriter's key.
    (NonEmpty UTxO.TxOut)
    -- ^ Genesis UTxO output Address.
    CommonCLI

runCommand :: CLIOps IO -> ClientCommand -> ExceptT CliError IO ()
runCommand co (Genesis outDir params) = do
  gen <- mkGenesis params
  dumpGenesis co outDir `uncurry` gen

runCommand co (DumpHardcodedGenesis dir) =
  dumpGenesis co dir (Genesis.configGenesisData Dummy.dummyConfig) Dummy.dummyGeneratedSecrets

runCommand co (PrettySigningKeyPublic skF) = do
  sK <- readSigningKey co skF
  liftIO . putTextLn . prettyPublicKey $ Crypto.toVerification sK

runCommand co (MigrateDelegateKeyFrom fromVer (NewSigningKeyFile newKey) oldKey) = do
  ops <- liftIO $ decideCLIOps fromVer
  sk <- readSigningKey ops oldKey
  sDk <- liftIO $ coSerialiseDelegateKey co sk
  liftIO $ ensureNewFileLBS newKey sDk

runCommand _ (PrintGenesisHash genFp) = do
  eGen <- readGenesis genFp

  let formatter :: (a, Genesis.GenesisHash)-> Text
      formatter = F.sformat Crypto.hashHexF . Genesis.unGenesisHash . snd

  liftIO . putTextLn $ formatter eGen

runCommand co (PrintSigningKeyAddress netMagic skF) = do
  sK <- readSigningKey co skF
  let sKeyAddress = prettyAddress . Common.makeVerKeyAddress netMagic $ Crypto.toVerification sK
  liftIO $ putTextLn sKeyAddress

runCommand co (Keygen (NewSigningKeyFile skF) passReq) = do
  pPhrase <- liftIO $ getPassphrase ("Enter password to encrypt '" <> skF <> "': ") passReq
  sK <- liftIO $ keygen pPhrase
  serDk <- liftIO $ coSerialiseDelegateKey co sK
  liftIO $ ensureNewFileLBS skF serDk

runCommand co (ToVerification skFp (NewVerificationKeyFile vkFp)) = do
  sk <- readSigningKey co skFp
  let vKey = Builder.toLazyText . Crypto.formatFullVerificationKey $ Crypto.toVerification sk
  liftIO $ ensureNewFile TL.writeFile vkFp vKey

runCommand co (IssueDelegationCertificate magic epoch issuerSK delegateVK cert) = do
  vk <- readVerificationKey delegateVK
  sk <- readSigningKey co issuerSK
  let byGenDelCert :: Delegation.Certificate
      byGenDelCert = issueByronGenesisDelegation magic epoch sk vk
  sCert <- liftIO $ coSerialiseDelegationCert co byGenDelCert
  liftIO $ ensureNewFileLBS (nFp cert) sCert

runCommand _ (CheckDelegation magic cert issuerVF delegateVF) = do
  issuerVK <- readVerificationKey issuerVF
  delegateVK <- readVerificationKey delegateVF
  liftIO $ checkByronGenesisDelegation cert magic issuerVK delegateVK

runCommand co (SubmitTx topology fp common) = do
  cc <- liftIO $ mkConfiguration mainnetConfiguration common
  tx <- liftIO $ readByronTx fp
  liftIO $ nodeSubmitTx co topology cc tx

runCommand co (SpendGenesisUTxO (NewTxFile ctTx) ctKey genRichAddr outs common) = do
  cc <- liftIO $ mkConfiguration mainnetConfiguration common
  sk <- readSigningKey co ctKey
  tx <- liftIO $ issueGenesisUTxOExpenditure co genRichAddr outs cc sk
  liftIO . ensureNewFileLBS ctTx $ serialise tx

runCommand co (SpendUTxO (NewTxFile ctTx) ctKey ins outs common) = do
  cc <- liftIO $ mkConfiguration mainnetConfiguration common
  sk <- readSigningKey co ctKey
  gTx <- liftIO $ issueUTxOExpenditure co ins outs cc sk
  liftIO . ensureNewFileLBS ctTx $ serialise gTx

{-------------------------------------------------------------------------------
  Supporting functions
-------------------------------------------------------------------------------}

-- TODO:  we'd be better served by a combination of a temporary file
--        with an atomic rename.
-- | Checks if a path exists and throws and error if it does.
ensureNewFile :: (FilePath -> a -> IO ()) -> FilePath -> a -> IO ()
ensureNewFile writer outFile blob = do
  exists <- doesPathExist outFile
  when exists $
    throwIO $ OutputMustNotAlreadyExist outFile
  writer outFile blob

ensureNewFileLBS :: FilePath -> LB.ByteString -> IO ()
ensureNewFileLBS = ensureNewFile LB.writeFile