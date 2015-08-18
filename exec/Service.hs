{-# LANGUAGE NamedFieldPuns #-}
-- (c) 2014 Vladimír Štill

module Main ( main ) where

import UI

import Control.Exception
import Control.Arrow
import Control.Applicative
import Control.Monad

import System.Environment ( getArgs )
import System.IO.Error
import System.Directory
import System.Exit
import System.IO
import System.Posix.Files
import System.FilePath
import System.Clock

import Network.Socket

import Text.Read ( readEither )
import Data.Char
import Data.Typeable ( typeOf )
import Data.Maybe
import Data.Monoid
import Data.Bits ( (.|.) )
import Data.List

data Query
    = Query { transactId :: Integer
            , questionId :: Integer
            , content    :: String
            }
    deriving ( Eq, Show, Read )

-- http://stackoverflow.com/a/8502391/1620753
removeIfExists :: FilePath -> IO ()
removeIfExists fileName = removeFile fileName `catch` handleExists
  where handleExists e
            | isDoesNotExistError e = return ()
            | otherwise = throwIO e

defaultsock, defaultqdir :: FilePath
defaultsock = "/var/lib/checker/socket"
defaultqdir = "/var/lib/checker/qdir"

deflimit :: Int
deflimit = 2000 * 1000 -- 1 seconds

doLog :: String -> IO ()
doLog = hPutStrLn stderr

main :: IO ()
main = getArgs >>= \args -> case args of
  [ sockaddr, qdir ] -> runSocket sockaddr qdir
  [ sockaddr ]       -> runSocket sockaddr defaultqdir
  []                 -> runSocket defaultsock defaultqdir
  _                  -> error "usage: hsExprTestService [ sockaddr [ qdir ] ]"


runSocket :: FilePath -> FilePath -> IO ()
runSocket sockaddr qdir = do
    setCurrentDirectory qdir
    removeIfExists sockaddr
    listener <- socket AF_UNIX Stream defaultProtocol
    bind listener (SockAddrUnix sockaddr)
    setFileMode sockaddr $ foldr1 (.|.) [ ownerReadMode, ownerWriteMode
                                        , groupReadMode, groupWriteMode
                                        , otherReadMode, otherWriteMode ]
    listen listener 1
    loop $ do
        doLog "accepting socket..."
        bracket (fst <$> accept listener) close $ \sock -> do
            doLog $ "accepted fd=" ++ show ((\(MkSocket fd _ _ _ _) -> fd) sock)

            doLog "receiving query..."
            query <- recv sock 65536
            start <- getTime Monotonic
            doLog "done"

            hPutStrLn stderr $ "Received: '" ++ query ++ "'"
            case parseQ query of
                Left msg -> void $ send sock ("INVALID: " ++ msg ++ "\n\n")
                Right query -> do
                    doLog . ("Running query: " ++ ) . show $ query
                    runQuery qdir query sock
                    doLog "query done"
            end <- getTime Monotonic
            putStrLn $ "took " ++ show (diffTime (10^3) end start) ++ " milliseconds"
  where
    loop :: IO () -> IO ()
    loop x = x `catch` ignore >> loop x

    ignore :: SomeException -> IO ()
    ignore (SomeException e) = case (fromException (SomeException e) :: Maybe IOException) of
        Just ioe -> putStrLn $ "WARNING: Exception: " ++ show ioe
        Nothing  -> do putStrLn $ "FATAL: Exception (" ++ show (typeOf e) ++ "): " ++ show e
                       exitFailure

    diffTime :: Integer -> TimeSpec -> TimeSpec -> Integer
    diffTime prec a b = ndiff + sdiff
      where
        ndiff = (`div` (10^9 `div` prec)) . fromIntegral $ nsec a - nsec b
        sdiff = (* prec) . fromIntegral $ sec a - sec b

runQuery :: FilePath -> Query -> Socket -> IO ()
runQuery qpath (Query { transactId, questionId, content }) sock = do
    let qfile = qpath </> show questionId `addExtension` "q.hs"
    fe <- doesFileExist qfile
    if not fe then void (send sock "FATAL: Question does not exits") else do
        question <- decodeQ content <$> readFile qfile
        case question of
            Left emsg -> void $ send sock ("FATAL: Invalid question: " ++ emsg)
            Right q   -> do
                doLog "running expressionTester"
                (ok, msg) <- runExpressionTester q
                doLog "done"
                let reply = concat [ "I", show transactId
                                   , "P", if ok then "ok" else "nok"
                                   , "C", msg ]
                doLog $ "replying on socket, reply = " ++ reply
                send sock reply
                doLog "reply sent"
                return ()
  where
    decodeQ :: String -> String -> Either String Main
    decodeQ student q = case span ("-- @ " `isPrefixOf`) (lines q) of
        ([], _)           -> Left "Missing instructions"
        (instr, solution) -> fromInstr student (unlines solution) (map (drop 5) instr)

    fromInstr student0 solution instrs0 = do
        let instrs = map (span (/= ':') >>> second (drop 2)) instrs0
        case (lookup "type" instrs, lookup "expr" instrs) of
            (Just _, Nothing) -> return CompareTypes { student = student0, solution }
            (Nothing, Just expressionName) -> do
                limit <- fmap Just $ case lookup "limit" instrs of
                    Nothing   -> Right deflimit
                    Just sLim -> readEither sLim
                student <- if isJust (lookup "inject" instrs)
                    then do
                        let toInject = unlines . takeWhile (/= "-- @ INJECT END")
                                               . dropWhile (/= "-- @ INJECT BEGIN")
                                               . lines $ solution
                        Right $ unlines [ "{-# LINE 1 \"Inject.hs\" #-}"
                                        , toInject
                                        , ""
                                        , "{-# LINE 1 \"Student.hs\" #-}"
                                        , student0
                                        ]
                    else Right student0
                return CompareExpressions { student, solution, expressionName, limit }
            _ -> Left "Invalid instructions"

{-
            do
                (ok, msg) <- runExpressionTester conf
                send sock $ unlines
                    [ if ok then "OK" else "FAIL"
                    , ""
                    , msg
                    , ""
                    ]

-}

both :: Monoid e => (Either e a, Either e b) -> Either e (a, b)
both (Right x, Right y) = Right (x, y)
both (Left x, Left y)   = Left (x `mappend` y)
both (Left x, _)        = Left x
both (_, Left y)        = Left y

-- FORMAT: "I<xid>Q<id>S<len><odp>";
parseQ :: String -> Either String Query
parseQ ('I':qs) = span isDigit >>> readEither *** parseQuestion >>> both >>> fmap toQuery $ qs
  where
    parseQuestion :: String -> Either String (Integer, String)
    parseQuestion ('Q':qs) = span isDigit >>> readEither *** parseContent >>> both $ qs
    parseQuestion _        = Left "Expected 'Q'. "

    parseContent :: String -> Either String String
    parseContent ('S':qs) = Right qs
    parseContent _        = Left "Expected 'S'. "

    toQuery (transactId, (questionId, content)) = Query { transactId, questionId, content }
parseQ _ = Left "Expected 'I' at the beginning. "

