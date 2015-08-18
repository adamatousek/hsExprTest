{-# LANGUAGE StandaloneDeriving, DeriveDataTypeable, NamedFieldPuns
           , TupleSections, LambdaCase, MultiWayIf #-}

-- (c) 2012 Martin Jonáš
-- (c) 2014, 2015 Vladimír Štill

module Testing (
      Test(..)
    , Typecheck(..)
    , CompareMode(..)
    , runTest
    ) where

import Control.Exception
import Control.Applicative
import Control.Monad.Trans.Error

import Data.Monoid
import Data.List
import Data.Typeable ( Typeable )

import qualified Test.QuickCheck as QC ( Result )

import Language.Haskell.Interpreter
import Language.Haskell.Interpreter.Unsafe ( unsafeRunInterpreterWithArgs )

import Testing.Test ( qcRunProperty, AnyProperty )
import Types
import Types.Parser
import Types.Arguments
import Files
import Result
import PrettyPrint

deriving instance Typeable QC.Result

data Typecheck = NoTypecheck -- ^ do not perform any typechecking step
               | RequireTypeOrdering [TypeOrdering]
               -- ^ require that student type compared to solution type satisfies
               -- one of given ordering, for example:
               -- @RequireTypeOrdering ['Equal', 'MoreGeneral']@ means that
               -- student's type must be equal or more general then solution's
               deriving (Eq, Read, Show)

-- | Specify what should be output from comparison
data CompareMode = JustCompile -- ^ run just compilation (type parsing for type comparison)
                 | CompileAndTypecheck -- ^ run compilation and typechecking
                 | FullComparison -- ^ perform full test
                 deriving (Eq, Read, Show)

-- | Test definition
data Test
    -- | compare expressions of given name, optionally with time limit
    -- (in milliseconds), following actions are performed:
    --
    -- 1. compilation
    -- 2. type comparison, if @typecheckMode@ is not 'TypecheckDisable'
    -- 3. execution of test
    = CompareExpressions { student        :: String
                         , solution       :: String
                         , expressionName :: String
                         , limit          :: Maybe Int
                         , typecheckMode  :: Typecheck
                         , compareMode    :: CompareMode
                         }
    -- | compare types by given specification (if @'NoTypecheck'@ is given,
    -- just parse types and return parse errors).
    | CompareTypes { student       :: String
                   , solution      :: String
                   , typecheckMode :: Typecheck
                   , compareMode   :: CompareMode
                   }

runTest :: Test -> IO TestResult
runTest (CompareTypes { student, solution, typecheckMode, compareMode }) =
    return $ compareTypesCmd student solution typecheckMode compareMode

runTest (CompareExpressions { student, solution, expressionName, limit, typecheckMode, compareMode }) =
    withContext $ \c -> do
        studf <- createStudentFile c student
        solf <- createSolutionFile c solution
        withInterpreter c [ studf, solf ] [ importQ "Student", importQ "Solution" ] $ do
            sttype <- typeOf stexpr
            sotype <- typeOf soexpr
            case compareTypesCmd sttype sotype typecheckMode compareMode of
                Success -> if compareMode == FullComparison
                    then cmp sttype sotype
                    else return Success
                r -> return r
  where
    stexpr = "Student." ++ expressionName
    soexpr = "Solution." ++ expressionName

    cmp :: String -> String -> Interpreter TestResult
    cmp sttype0 sotype0 = runErrorT (getDegeneralizedTypes comtype) >>= \case
        Right testtypes -> mconcat <$> mapM test testtypes
        Left emsg       -> return . RuntimeError $ emsg
      where
        -- this is after typechecking, so type parsing and unification
        -- must succeed
        Right sttype = parseType sttype0
        Right sotype = parseType sotype0
        Right mgu = unifyTypes (getType sttype) (getType sotype)
        comtype = sttype // fst mgu

    test testtype = do
        expr <- buildTestExpression stexpr soexpr testtype
        prop <- interpret expr (as :: AnyProperty)
        liftIO $ qcRunProperty limit prop

compareTypesCmd :: String -> String -> Typecheck -> CompareMode -> TestResult
compareTypesCmd student solution typecheckMode compareMode =
    case (parseType student, parseType solution) of
        (Left ste, Left soe) -> CompileError $ "Parse error: " ++ perr "student" ste ++
                                  ", " ++ perr "solution" soe ++ "."
        (Left ste, _) -> CompileError $ "Parse error: " ++ perr "student" ste ++ "."
        (_, Left soe) -> CompileError $ "Parse error: " ++ perr "solution" soe ++ "."
        (Right stt, Right sot) ->
            if | compareMode == JustCompile || typecheckMode == NoTypecheck -> Success
               | result `elem` required -> Success
               | otherwise -> TypeError $ "Expected one of " ++ show required ++
                                  " but got " ++ show result ++ " (" ++ message ++ ")."
            where
              RequireTypeOrdering required = typecheckMode
              (result, message) = compareTypes stt sot
  where
    perr who what = "could not parse " ++ who ++ " type: `" ++ pp what ++ "'"

importQ :: String -> (String, Maybe String)
importQ m = (m, Just m)

withInterpreter :: FileContext -> [FilePath] -> [(String, Maybe String)]
                -> Interpreter TestResult -> IO TestResult
withInterpreter ctx modules imports action = fmap output . try . unsafeRunInterpreterWithArgs args $ do
    -- this seems to only affect interactive, not solutions in file also it is
    -- needed to make instances available
    set [ installedModulesInScope := True ]
    loadModules modules
    setImportsQ $ map (, Nothing) [ "Prelude", "Data.Word", "Data.Int"
                                   , "Test.QuickCheck", "Test.QuickCheck.Modifiers"
                                   , "Test.QuickCheck.Arbitrary", "Testing.Test"
                                   , "Types.Curry", "Control.DeepSeq" ]
                  ++ imports
    action
  where
    output (Left (SomeException ex)) = RuntimeError (show ex)
    output (Right (Left err)) = case err of
        UnknownError str -> RuntimeError $ "Unknown error: " ++ str
        NotAllowed  str  -> RuntimeError $ "Not allowed: " ++ str
        GhcException str -> RuntimeError $ "GHC exception: " ++ str
        WontCompile list -> CompileError . unlines . nub . map errMsg $ list
    output (Right (Right result)) = result
    args = pkgs ++ extra
    -- NOTE: it would seem better to use HINT's set feature to set language
    -- extensions (and it would be type safe) but there is bug somewhere
    -- which couses Prelude to go out of scope (at least on ghc 7.8.3 on nixos)
    -- if set [ languageExtensions := ... ] is used and prelude is not imported
    -- explicitly (which is kind of pain to do), so we do it here.
    extra = [ "-XNoMonomorphismRestriction" -- needed to avoid certain code which runs in ghci but fails in ghc
            , "-XDeriveDataTypeable"
            , "-XStandaloneDeriving"
            , "-Werror", "-i" ++ getContext ctx ]
    pkgs = map ("-package=" ++) [ "random", "tf-random", "QuickCheck", "hsExprTest" ]

