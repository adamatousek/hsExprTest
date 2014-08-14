{-# LANGUAGE NamedFieldPuns
           , Unsafe
           , DeriveDataTypeable
           , ExistentialQuantification
           #-}
-- | Simple interface to testing
module Teacher.Test (
    -- * Result re-exports
      TestingResult ( DifferentValues, Success, Timeout )
    -- * Configuration
    , Expression
    , ExpectedType ( .. )
    , Test ( .. )
    , TestConfig ( .. )
    , defaultConfig
    -- * Utility functions
    , firstFailed
    , qcToResult
    , qcFirstFailed
    , qcRunProperties
    -- Utility types
    , AnyProperty ( AnyProperty )
    -- * InteractiveImports re-export
    , module InteractiveImports.DataTypes
    ) where

import Result
import qualified Test.QuickCheck.Test as QCT
import Control.Monad ( mapM )
import Test.QuickCheck ( Testable )
import Data.Monoid
import Data.List
import Data.Typeable
import InteractiveImports.DataTypes

data AnyProperty = forall a. Testable a => AnyProperty a
    deriving ( Typeable )

type Expression = String

data ExpectedType
    = TypeOf { etTypeOf :: Expression }
    | Fixed { etFixed :: String }
    | None
    deriving ( Typeable, Show )

data Test
    = TestEntry { tTestEntry :: String }
    | Properties { tProperties :: [ AnyProperty ] }
    deriving ( Typeable )

data TestConfig = TestConfig
    { expectedType      :: ExpectedType
    , studentExpression :: String
    , test              :: Test
    } deriving ( Typeable )

defaultConfig :: TestConfig
defaultConfig = TestConfig { expectedType = None
                           , studentExpression = "f"
                           , test = Properties []
                           }

qcToResult :: QCT.Result -> TestingResult
qcToResult (QCT.Success {}) = Success
qcToResult (QCT.GaveUp {})  = Success
qcToResult (QCT.Failure { QCT.reason = r, QCT.output = o })
    = if "<<timeout>>" `isInfixOf` r then Timeout else DifferentValues o
qcToResult (QCT.NoExpectedFailure { QCT.output = o }) = DifferentValues o

firstFailed :: [ TestingResult ] -> TestingResult
firstFailed = mconcat

qcFirstFailed :: [ QCT.Result ] -> TestingResult
qcFirstFailed = firstFailed . map qcToResult

qcRunProperties :: [ AnyProperty ] -> IO TestingResult
qcRunProperties props = mapM applyQC props >>= return . qcFirstFailed
  where applyQC (AnyProperty p) = QCT.quickCheckWithResult (QCT.stdArgs { QCT.chatty = False }) p
