{-# LANGUAGE StandaloneDeriving
           , DeriveDataTypeable
           #-}

-- (c) 2012 Martin Jonáš
-- (c) 2014 Vladimír Štill

module Testing where

import Control.Arrow

import System.Directory
import System.Timeout

import Data.List
import Data.Maybe
import Data.Typeable hiding (typeOf)
import qualified Data.Typeable as T

import Text.Printf

import qualified Test.QuickCheck as QC
import qualified Test.QuickCheck.Test as QCT

import Language.Haskell.Interpreter hiding ( WontCompile )
import qualified Language.Haskell.Interpreter as I
import Language.Haskell.Interpreter.Unsafe ( unsafeRunInterpreterWithArgs )


import Types.Parser
import Types.Processing
import Types.Comparing ( compareTypes )
import Types.TypeExpression
import Types.Arguments
import Types.Formating ( formatType )
import Files
import Result
import Config
import Testing.Test ( qcRunProperties, TestConfig ( .. ), Test ( .. ), ExpectedType ( .. ) )

deriving instance Typeable QC.Result

-- | Function compareExpressions compares two expressions using QuickCheck and return result as IO String
compareExpressions :: Maybe Int -> String -> String -> String -> IO TestingResult
compareExpressions lim a b c = 
    timeout (fromMaybe (-1) lim) (testFiles testExpressionValues a b c) >>= \r -> case r of
          Just x  -> return $ x
          Nothing -> return $ Timeout

-- | Function testFiles creates two testing modules containing student and solution expressions and runs given interpreter on those modules.
testFiles :: (String -> String -> String -> Interpreter TestingResult)
          -> String -> String -> String -> IO (TestingResult)
testFiles interpreter expression solution student = do
    solutionFile <- createSolutionFile solution
    studentFile <- createStudentFile student
    result <- run $ interpreter expression solutionFile studentFile
    removeFile solutionFile
    removeFile studentFile
    return result

-- | Function testTypeEquality compares two given type expressions.
testTypeEquality :: String -> String -> TypingResult
testTypeEquality solution student =
    case (parsedSolutionType, parsedStudentType) of
        (Right a, Right b) -> a `compareTypes` b
        (_, Left _) -> CannotParse student
        (Left _, _) -> CannotParse solution
    where
        parsedSolutionType = parseType solution
        parsedStudentType = parseType student

setupInterpreter :: [ String ] -- ^ Modules
                 -> [ (String, Maybe String) ] -- ^ optionally qualified imports
                 -> Interpreter ()
setupInterpreter mod imports = do
    set [ installedModulesInScope := False -- security reasons, avoid accessing internals
        ]
    loadModules mod
    setImportsQ $ [ ("Prelude", Nothing)
                  , ("Test.QuickCheck", Nothing)
                  , ("Testing.Limiting", Nothing)
                  , ("Testing.Test", Nothing)
                  , ("Types.Curry", Nothing)
                  ] ++ imports

-- | Function testExpressionValues is the main function of this module. It performs nearly all the useful work and almost all functions use it internally.
-- | This function compares given expressions within given time bounds and returns interpreter, which can be executed.
testExpressionValues :: String -> String -> String -> Interpreter TestingResult
testExpressionValues expression solutionFile studentFile = do
    setupInterpreter [ solutionFile, studentFile ]
                     [ ("Student", Just "Student")
                     , ("Solution", Just "Solution")
                     ]
    solutionType <- typeOf ("Solution." ++ expression)
    studentType <- typeOf ("Student." ++ expression)
    case testTypeEquality solutionType studentType of
        TypesEqual resultType -> do
            rta <- getTestableArguments resultType 
            case rta of
                Right ta -> do
                    let testExpression = createTestExpression expression ta
                    liftIO $ putStrLn testExpression
                    interpret
                        ("qcRunProperties (" ++ testExpression ++ ")")
                        (as :: (IO TestingResult))
                            >>= liftIO
                Left msg -> return $ NotTestable msg
        r -> return (TypesNotEqual r)

-- | Function createTestExpressions creates one string test expression from two function expressions.
-- | It creates lambda expression by prepending correct number of arguments and comparing result of given functions when applied to those arguments.
-- | Generated lambda expression also contains time limitation computed by function createLimits
createTestExpression :: String -> [ TestableArgument ] -> String
createTestExpression expression arguments = wrap . map property $ degeneralize arguments
  where
    wrap = ('[' :) . (++ "]") . intercalate ", "
    property :: [ TestableArgument ] -> String
    property []   = "AnyProperty (Solution.f <==> Student.f)"
    property args = concat [ "AnyProperty (\\", intercalate " " (params args), " -> "
                           , "(Just (", intercalate ", " (params args), ") :: ", types args, ")"
                           , " `seq` (Solution.", expr args, " <==> Student.", expr args, ") )"
                           ]

    params = flip (zipWith bindGen) [1..]
    expr = intercalate " " . (expression :) . flip (zipWith varGen) [1..]
    types = map qualifiedType >>>
            foldr (\(TypeExpression (TypeContext []) ty1) tys -> ty1 : tys) [] >>>
            TupleType >>>
            TypeApplication (TypeConstructor "Maybe") >>>
            formatType

runTestfile :: FilePath -> String -> IO TestingResult
runTestfile testfile student = do
    studentFile <- createStudentFile student
    result <- run $ runTestfile' testfile studentFile
    removeFile studentFile
    return result

runTestfile' :: FilePath -> FilePath -> Interpreter TestingResult
runTestfile' test student = do
    setupInterpreter [ test, student ] [ ("Student", Just "Student" ), ("Test", Nothing) ]
    config <- interpret "testConfig" (as :: TestConfig)
    solType <- case expectedType config of
        None        -> return $ ""
        TypeOf expr -> typeOf expr
        Fixed t     -> return $ t
    case solType of
        "" -> runTest config
        _  -> do
            studType <- typeOf $ "Student." ++ studentExpression config
            case testTypeEquality solType studType of
                TypesEqual _ -> runTest config
                r -> return $ TypesNotEqual r

runTest :: TestConfig -> Interpreter TestingResult
runTest TestConfig { test = TestEntry entry }  = typeOf entry >>= \t ->
    case (t == showType (infer :: TestingResult), t == showType (infer :: IO TestingResult) ) of
        (True, _) -> interpret entry (as :: TestingResult)
        (_, True) -> interpret entry (as :: IO TestingResult) >>= liftIO
runTest TestConfig { test = Properties props } = liftIO $ qcRunProperties props

showType :: Typeable a => a -> String
showType = show . T.typeOf


-- | Function run is convinience function which executes the interpreter and returns the result.
run :: Interpreter TestingResult -> IO TestingResult
run interpreter = do
    r <- unsafeRunInterpreterWithArgs args interpreter
    case r of
        (Left error) -> case error of
            I.UnknownError str -> ce $ "Unknown error: " ++ str
            I.NotAllowed  str  -> ce $ "Not allowed: " ++ str
            I.GhcException str -> ce $ "GHC exception: " ++ str
            I.WontCompile list -> ce $ "Compilation error:\n" ++ (unlines . nub . map I.errMsg) list
        (Right result) -> return result
  where
    ce = return . WontCompile
    args = pkgs ++ exts
    -- NOTE: it would seem better to use HINT's set feature to set language
    -- extensions (and it would be type safe) but there is bug somewhere
    -- which couses Prelude to go out of scope (at least on ghc 7.8.3 on nixos)
    -- if set [ languageExtensions := ... ] is used and prelude is not imported
    -- explicitly (which is kind of pain to do), so we do it here.
    exts = [ "-XNoMonomorphismRestriction" ]
    pkgs = map ("-package=" ++) [ "random", "tf-random", "QuickCheck", "hsExprTest" ]

