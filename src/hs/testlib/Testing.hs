{-# LANGUAGE TupleSections, FlexibleContexts #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | Core module of hsExprTest, most of test processing and running takes
-- place here.
--
-- * (c) 2014 - 2016 Vladimír Štill
-- * (c) 2012 Martin Jonáš

module Testing ( runTest ) where

import Prelude hiding ( fail )

import Control.Arrow ( (>>>) )
import Control.Exception ( Exception, SomeException (..), throw, fromException )
import Control.Monad ( when, unless, forM )
import Control.Monad.Catch ( MonadMask, try )
import Control.Monad.Fail as F ( MonadFail, fail )
import Control.Monad.IO.Class ( MonadIO, liftIO )
import Control.Monad.Reader.Fail ()
import Control.Monad.Reader.Generalized ( GMonadReader, greader )
import Control.Monad.Trans.Class ( lift )

import Data.Either ( isLeft )
import Data.List ( nub, find )
import Data.Maybe ( fromMaybe, isNothing, isJust )

import System.Process ( cwd, std_in, std_out, std_err, proc
                      , createProcess, waitForProcess
                      , StdStream ( Inherit, UseHandle ) )
import System.Exit ( ExitCode ( ExitSuccess, ExitFailure ) )
import System.Posix.Signals ( sigALRM )

import Language.Haskell.Interpreter ( InterpreterT
                                    , InterpreterError ( UnknownError, NotAllowed
                                                       , GhcException, WontCompile )
                                    , typeOf, errMsg, set, installedModulesInScope
                                    , OptionVal ( (:=) ), loadModules, setImportsQ )
import Language.Haskell.Interpreter.Unsafe ( unsafeRunInterpreterWithArgs )


import Files ( WorkDir, WithWorkDir, withWorkDir, createStudentFile
             , createSolutionFile, createTestFile, getWorkDir )
import Testing.Options ( Options, doLog, doOut, WithOptions, withOptions
                       , optHint, optIncludeDirs, withIOStreams )
import Testing.Arguments ( buildTestExpression, buildTestExpressionsWithComparer
                         , getDegeneralizedTypes )
import Testing.Assignment ( Assignment (..), Typecheck (..), AssignmentType (..)
                          , WithAssignment, readAssignment, asgnSolution
                          , doStudentOut, doStudentOut', HintMode (..) )
import Text.PrettyPrint ( pp )
import Types ( unifyTypes, getType, (//), compareTypes, TypeExpression, addImpliedOrderings )
import Types.Parser ( parseType )

data TestError = TestError String deriving ( Show )
instance Exception TestError

testError :: MonadIO m => String -> m ()
testError = throw . TestError

instance MonadFail m => MonadFail (InterpreterT m) where
    fail = lift . fail

runTest :: Options -> IO Bool
runTest opts = withOptions opts . (res =<<) . try . readAssignment . withWorkDir
               $ runAssignment
  where
    res :: Either SomeException () -> WithOptions IO Bool
    res (Left ex) = case fromException ex of
        Just (TestError err) -> doLog err >> doOut err >>pure False
        Nothing -> let msg = "EXCEPTION: " ++ show ex
                   in doLog msg >> doOut msg >> pure False
    res (Right ()) = pure True

type MStack = WithWorkDir (WithAssignment (WithOptions IO))

runAssignment :: MStack ()
runAssignment = do
    doLog "starting assignment"
    atype <- greader asgnType
    case atype of
        HaskellType -> runHaskellTypesAssignment
        HaskellExpression -> runHaskellAssignment
    doLog "assignment ended"

runHaskellTypesAssignment :: MStack ()
runHaskellTypesAssignment = do
    student <- filt (/= "{-# LINE 1 \"Student.hs\" #-}") 1 <$> greader asgnStudent
    solution <- filt (\x -> take 2 x == "--") 0 <$> greader asgnSolution
    runHaskellTypesAssignment' student solution
  where
    filt f n = lines >>> dropWhile f >>> drop n >>> unlines

runHaskellTypesAssignment' :: String -> String -> MStack ()
runHaskellTypesAssignment' student solution =
    case (parseType student, parseType solution) of
        (Left ste, Left soe) -> perr' "student" ste >> perr' "solution" soe >> end
        (Left ste, _) -> perr "student" ste
        (_, Left soe) -> perr "solution" soe
        (Right stt, Right sot) -> runHaskellTypesAssignmentParsed stt sot
  where
    perr who what = perr' who what >> end
    perr' who what = doStudentOut' ("could not parse " ++ who ++ " type") >>
                     doLog ("type parser failed: " ++ pp what)
    end = fail "invalid type"

runHaskellTypesAssignmentParsed :: TypeExpression -> TypeExpression -> MStack ()
runHaskellTypesAssignmentParsed stt sot = do
    let (result, message) = compareTypes stt sot
    typecheckMode <- greader asgnTypecheck
    let RequireTypeOrdering required0 = typecheckMode
    let required = addImpliedOrderings required0

    unless (typecheckMode == NoTypecheck || result `elem` required) $ do
       doStudentOut TypeMismatchInfo $ "Expected one of " ++ show required ++
                          " but got " ++ show result ++ " (" ++ message ++ ")."
       testError "type mismatch"

runHaskellAssignment :: MStack ()
runHaskellAssignment = do
    stfile <- createStudentFile =<< greader asgnStudent
    sofile <- createSolutionFile =<< greader asgnSolution

    expr' <- greader asgnExpr
    when (isNothing expr') $ fail "Missing 'expr' in assignment"
    let Just expr = expr'

    wrap <- greader asgnWrapper
    comparer <- greader asgnComparer
    let stexpr = "Student." ++ expr
        soexpr = "Solution." ++ expr
        stwrap = fromMaybe stexpr $ ("Student." ++) <$> wrap
        sowrap = fromMaybe soexpr $ ("Solution." ++) <$> wrap
        compexpr = ("Solution." ++) <$> comparer

    let getExprTypeStudent = getExprType stfile "Student"
        getExprTypeSolution = getExprType sofile "Solution"
        interpreter' = interpreter [ sofile, stfile ] [ importQ "Solution", importQ "Student" ] NoOutput NoOutput

    studentType <- getExprTypeStudent stexpr StudentCompileOut TypeMismatchInfo
    studentWrapType <- getExprTypeStudent stwrap NoOutput TypeMismatchInfo
    solutionType <- getExprTypeSolution soexpr NoOutput TypeMismatchInfo
    solutionWrapType <- getExprTypeSolution sowrap NoOutput TypeMismatchInfo

    runHaskellTypesAssignment' studentType solutionType
    sttype <- emsg "parsing student type" $ parseType studentWrapType
    sotype <- emsg "parsing solution type" $ parseType solutionWrapType
    mgu <- emsg "unifying types" $ unifyTypes (getType sttype) (getType sotype)
    let comtype = sttype // fst mgu

    testtypes <- interpreter' $ getDegeneralizedTypes comtype
    fmap mconcat . forM testtypes $ \testtype -> do
        testExpr <- interpreter' $ fromMaybe (buildTestExpression stexpr soexpr testtype)
                (pure . buildTestExpressionsWithComparer stexpr soexpr <$> compexpr)
        doLog $ "testing expression: " ++ testExpr
        isHint <- greader optHint
        hintLevel <- greader asgnHint
        when (not isHint || hintLevel >= Test) $ withIOStreams $ \outs _ -> do
            test <- mkTestFile testExpr
            includes <- getIncludeOpts
            wd <- greader getWorkDir
            let opts = includes ++ [test]
                runghc = (proc "runghc" (ghcOptions ++ opts))
                          { cwd = Just wd
                          , std_in = Inherit
                          , std_out = UseHandle outs
                          , std_err = UseHandle outs
                          }
            (_, _, _, h) <- liftIO $ createProcess runghc
            ec <- liftIO $ waitForProcess h
            case ec of
                ExitSuccess   -> doStudentOut' "Test passed."
                ExitFailure v | -v == fromIntegral sigALRM -> doOut "Timeout" >> testError "timeout"
                              | otherwise                  -> doOut "Test failed" >> testError "test failed"
  where
    emsg :: Show e => String -> Either e a -> MStack a
    emsg msg (Left x)  = doStudentOut' ("Error " ++ msg ++ ": " ++ show x) >>
                         fail "terminated by emsg"
    emsg _   (Right x) = pure x

mkTestFile :: String -> MStack FilePath
mkTestFile expr = do
    lim <- fromMaybe 10 <$> greader asgnLimit
    imports <- greader asgnImports
    let contents = unlines $
            [ "import " ++ m | m <- loadedModules ++ imports ] ++
            [ ""
            , "test :: AnyProperty"
            , "test = " ++ expr
            , "limit :: Int"
            , "limit = " ++ show lim
            , ""
            , "main :: IO ()"
            , "main = mainRunProperty limit test"
            ]
    createTestFile contents


getExprType :: FilePath -> String -> String -> HintMode -> HintMode -> MStack String
getExprType filePath moduleName expr hintModeCondition hintModeConditionFull =
    interpreter [ filePath ] [ importQ moduleName ] hintModeCondition hintModeConditionFull $ typeOf expr

interpreter :: [FilePath] -> [(String, Maybe String)] -> HintMode -> HintMode
          -> InterpreterT MStack a -> MStack a
interpreter files modules hintModeCondition hintModeConditionFull act = do
    r <- withInterpreter files modules act
    hint <- greader optHint
    hintSettings <- greader asgnHint
    let doFullHint = not hint || (hintModeConditionFull <= hintSettings)
        studentfile x = doFullHint || f == "Student.hs"
          where
            f = takeWhile (/= ':') x
    when (isLeft r) $ do
        case fromLeft r of
            UnknownError str -> doStudentOut' $ "Error 'UnknownError' while interpreting "
                                                ++ moduleName ++ " file: " ++ str
            NotAllowed str -> doStudentOut' $ "'Error NotAllowd' while interpreting "
                                                ++ moduleName ++ " file: " ++ str
            GhcException str -> doStudentOut' $ "Error 'GhcException' while interpreting "
                                                ++ moduleName ++ " file: " ++ str
            WontCompile msgs0 -> do
                let msgs = nub $ map errMsg msgs0
                doStudentOut hintModeCondition $ "Compilation error in "
                                  ++ moduleName ++ " file:\n"
                                  ++ unlines (filter studentfile msgs)
                                  ++ if isJust (find (not . studentfile) msgs)
                                        then "Could find student function or could not call it due to type error"
                                        else ""
        testError $ "interpreter failed on " ++ moduleName
    pure $ fromRight r
  where
    moduleName = case modules of
                    (x,_):_ -> x
                    _       -> "(unknown)"

fromLeft :: Either a b -> a
fromLeft (Left x) = x
fromLeft _ = error "fromLeft: Right"

fromRight :: Either a b -> b
fromRight (Right x) = x
fromRight _ = error "fromRight: Left"

importQ :: String -> (String, Maybe String)
importQ m = (m, Just m)

getIncludeOpts :: (Monad m, GMonadReader Options m, GMonadReader WorkDir m) => m [String]
getIncludeOpts = do
    wd <- greader getWorkDir
    includes <- greader optIncludeDirs
    pure $ map ("-i" ++) (wd:includes)

withInterpreter :: (MonadIO m, MonadMask m, GMonadReader WorkDir m, GMonadReader Options m)
                => [FilePath] -> [(String, Maybe String)]
                -> InterpreterT m a -> m (Either InterpreterError a)
withInterpreter modules imports action = do
    includes <- getIncludeOpts
    -- NOTE: it would seem better to use HINT's set feature to set language
    -- extensions (and it would be type safe) but there is bug somewhere
    -- which couses Prelude to go out of scope (at least on ghc 7.8.3 on nixos)
    -- if set [ languageExtensions := ... ] is used and prelude is not imported
    -- explicitly (which is kind of pain to do), so we do it here.
    let pkgs = map ("-package=" ++) [ "random", "tf-random", "QuickCheck", "hsExprTest" ]
    let extra = ghcOptions ++ includes
    let args = pkgs ++ extra

    unsafeRunInterpreterWithArgs args $ do
        -- this seems to only affect interactive, not solutions in file; also, it is
        -- needed to make instances available
        set [ installedModulesInScope := True ]
        loadModules modules
        setImportsQ $ map (, Nothing) loadedModules ++ imports
        action

ghcOptions :: [String]
ghcOptions = [ "-XNoMonomorphismRestriction" -- needed to avoid certain code which runs in ghci but fails in ghc
             , "-XDeriveDataTypeable"
             , "-XStandaloneDeriving"
             , "-XDataKinds"
             , "-XTemplateHaskell"
             , "-Werror"
             ]
loadedModules :: [String]
loadedModules = [ "Prelude", "Data.Word", "Data.Int", "Test.QuickCheck"
                , "Test.QuickCheck.Modifiers", "Test.QuickCheck.Function"
                , "Test.QuickCheck.Arbitrary", "Test.QuickCheck.Range"
                , "Testing.Test", "Types.Curry", "Control.DeepSeq" ]
