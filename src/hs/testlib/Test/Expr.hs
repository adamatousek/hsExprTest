{-# LANGUAGE TemplateHaskell, ExistentialQuantification, NamedFieldPuns
           , Unsafe, BangPatterns
           #-}

-- | Simple utility functions for testing.
--
-- (c) 2014-2018 Vladimír Štill

module Test.Expr (
                 -- * Test Entry
                   testMain
                 -- * Test Expression Building Blocks
                 , (<==>), testArgs, runProperty, Args (..), scheduleAlarm
                 ) where

import Test.QuickCheck ( Result (..), stdArgs, chatty, maxSuccess, replay, Property
                       , quickCheckWithResult, counterexample, Args (..), Testable )
import Test.QuickCheck.Random ( mkQCGen )

import Data.Typeable ( typeOf )
import Data.Function ( (&) )
import Data.Maybe ( isNothing )

import Control.Exception ( SomeException ( SomeException ), Exception, catch, evaluate )
import Control.DeepSeq ( force, NFData )
import Control.Monad ( when )
import Control.Applicative ( (<|>) )

import System.Exit ( exitSuccess, exitFailure )
import Language.Haskell.TH ( Q, Exp (..), Dec (..), Clause (..), Body (..), Lit (..), lookupValueName, mkName )

import System.IO.Unsafe ( unsafePerformIO )
import System.Posix.Signals ( scheduleAlarm )

import Text.Printf.Mauke.TH

import Test.Expr.Property

testArgs :: Args
testArgs = stdArgs { chatty = False
                   , maxSuccess = 1000
                   -- QC has no direct support for seeding, however,
                   -- replay also modifies size but it should only
                   -- (possibly) change size of the first testcase
                   , replay = Just (mkQCGen 0, 0)
                   }

type ExprName = String

testMain :: ExprName -> Q [Dec]
testMain name = do
    sname' <- lookupValueName sn
    fail ($(sprintf "Could not find student expression %s") name) & when (isNothing sname')
    tname <- lookupValueName tn
    eval  <- lookupValueName "Teacher.evaluator"
    fail ($(sprintf "Either teacher expression or evaluator has to be given for %s") name)
         & when (isNothing (tname <|> eval))
    let Just sname = sname'

    let timeout = maybe defimeout tmout <$> lookupValueName "Teacher.timeout"
    cmp <- maybe defcmp VarE <$> lookupValueName "Teacher.comparer"
    let args = maybe defargs VarE <$> lookupValueName "Teacher.args"

    let mainName = mkName "main"
    mainType <- [t| IO () |]
    body <- case (eval, tname) of
              (Just ev, _) -> [| scheduleAlarm $(timeout) >> $(pure $ VarE ev `AppE` VarE sname) |]
              (_, Just t)  -> [| scheduleAlarm $(timeout) >> runProperty $(args) $(prop cmp t sname) |]
              _ -> fail "impossible"
    pure $ [ SigD mainName mainType
           , FunD mainName [Clause [] (NormalB body) []] ]
  where
    defimeout = LitE $ IntegerL 10
    tmout x = VarE 'fromIntegral `AppE` VarE x
    defcmp = VarE '(<==>)
    defargs = VarE 'testArgs
    tn = "Teacher." ++ name
    sn = "Student." ++ name

runProperty :: Testable prp => Args -> prp -> IO ()
runProperty args prp = do
    r <- quickCheckWithResult args prp
    case r of
        Success {} -> exitSuccess
        GaveUp {} -> exitSuccess
        Failure { output } -> testFailure output
        NoExpectedFailure { output } -> testFailure output
        _ -> do print r
                exitFailure
  where
    testFailure output = do putStrLn output
                            exitFailure

-- | Exception aware comparison. If no exception is thrown when evaluating
-- either of the values, compares them using '(==)', if exception is thrown
-- in both, exception type is compared, otherwise if exception is thrown only
-- in one, property fails. Mismatching values are returned using
-- 'QC.counterexample' on failure.
(<==>) :: (Eq a, Show a, NFData a) => a -> a -> Property
infix 4 <==>
x <==> y = x `comp` y
  where
    wrap v = unsafePerformIO $ (evaluate . OK $ force v) `catch` handler
    handler (SomeException e) = return (Exc e)
    comp x0 y0 = counterexample (sx ++ " /= " ++ sy) (wx == wy)
      where
        wx = wrap x0
        wy = wrap y0
        sx = unwrap . wrap $ show wx
        sy = unwrap . wrap $ show wy
    unwrap  (OK str) = str
    unwrap ex@(Exc _) = show ex

data Wrapper a
    = OK !a
    | forall e. Exception e => Exc e

instance Eq a => Eq (Wrapper a) where
    (OK x)  == (OK y)  = x == y
    (Exc x) == (Exc y) = typeOf x == typeOf y
    _       == _       = False

instance Show a => Show (Wrapper a) where
    show (OK a)  = show a
    show (Exc e) = "{ EXCEPTION THROWN (" ++ show (typeOf e) ++ "): " ++ show e ++ " }"