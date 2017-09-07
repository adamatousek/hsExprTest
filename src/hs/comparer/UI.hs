-- (c) 2017 Vladimír Štill

module UI ( runUI ) where

import System.Exit ( exitSuccess, exitFailure )
import Data.Monoid ( Monoid(..), (<>), First ( First ), getFirst )
import Data.List.Split ( splitOn )
import Data.Bool ( bool )
import Testing ( runTest )
import Testing.Options
import Control.Monad ( (<=<), foldM )
import Control.Arrow ( second )
import System.IO ( hPutStrLn, stderr )

instance Monoid Options where
    mempty = Options { assignment = "", student = "", extraFiles = [], hint = False, logfile = Nothing, output = Nothing }
    mappend o1 o2 = Options { assignment = query assignment
                            , student = query student
                            , extraFiles = extraFiles o1 <> extraFiles o2
                            , hint = hint o1 || hint o2
                            , logfile = getFirst $ First (logfile o1) <> First (logfile o2)
                            , output = getFirst $ First (output o1) <> First (output o2)
                            }
      where
        query get = if null (get o1) then get o2 else get o1

getOptions :: [String] -> Either String Options
getOptions (a:s:options) = validate . snd <=< foldM compose (False, base) $ dup
  where
    base = mempty { assignment = a, student = s }
    dup = zip options (map Just (drop 1 options) ++ [Nothing])
    get ("--hint", _)        = next $ mempty { hint = True }
    get ("--extra", Just fs) = eat $ mempty { extraFiles = splitOn "," fs }
    get ("--log", Just log)  = eat $ mempty { logfile = Just log }
    get ("--out", Just o) = eat $ mempty { output = Just o }
    get (opt, _)             = Left $ "unknown option " ++ opt ++ ", or expecting argument and found none\n" ++ usage
    validate x
      | null (assignment x) = Left $ "missing assignment\n" ++ usage
      | null (student x)    = Left $ "missing student's solution\n" ++ usage
      | otherwise           = Right x
    next x = Right (False, x)
    eat x  = Right (True, x)
    compose (True, opts) _  = Right (False, opts)
    compose (False, opts) x = fmap (second (opts <>)) (get x)
getOptions _ = Left usage

usage = "usage: assignment student [--hint] [--extra file] [--log file] [--out file]"

runUI :: [String] -> IO ()
runUI opts = case getOptions opts of
                Right options -> runTest options >>= bool exitFailure exitSuccess
                Left msg      -> hPutStrLn stderr msg >> exitFailure
