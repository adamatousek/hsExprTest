module Main ( main ) where

import Testing
import Result

import System.IO.Unsafe
import Data.IORef
import System.Exit
import Data.Data
import Control.Monad

ignored :: a
ignored = undefined

main :: IO ()
main = do
    r@(_, failed) <- foldM test (0, 0)
              [ ("f = 2^2^2", "f = (2^2)^2", "f", Success)
              -- , ("f x = x . ((.).)", "f = (.((.).))", "f", Success)
              , ("f m n = m `mod` n", "f = mod", "f", Success)
              , ("f _ 0 = 0; f m n = m `mod` n", "f = mod", "f", DifferentValues ignored )

              -- generate noncomutative functions
              , ( "f :: (a -> a -> a) -> a -> [a] -> a; f = foldl"
                , "f :: (a -> a -> a) -> a -> [a] -> a; f = foldr"
                , "f", DifferentValues ignored
                )
              -- indentation
              , ( "f :: a -> a -> a\nf x y = y"
                , "f :: a -> a -> a\nf = const"
                , "f", DifferentValues ignored
                )
              -- monomorphism restriction
              , ( "f x = x", "f = id", "f", Success )
              -- layout rule
              , ( "f = g\n  where g x = x", "f = id", "f", Success )
              -- higher order generated function, monomorphism restriction
              , ( unlines [ "f :: Integral b => ((Int -> b) -> b) -> Int"
                          , "f g = fromIntegral (g (\\x -> fromIntegral (x + 1)))" ]
                , unlines [ "f :: Integral i => ((Int -> i) -> i) -> Int"
                          , "f = fromIntegral . ($ (fromIntegral . (+ 1)))" ]
                , "f", Success
                )
              -- type mismatch
              , ( "f = const", "f :: a -> a -> a; f = undefined", "f", TypesNotEqual ignored )
              -- no IO supported
              , ( "f :: Int -> IO Int; f x = return x", "f :: Int -> IO Int; f = return"
                , "f", NotTestable ignored
                )
              -- wrapped function
              , ( "f :: Maybe (a -> a) -> a -> a; f Nothing x = x; f (Just g) x = g x"
                , "f :: Maybe (a -> a) -> a -> a; f Nothing = id; f (Just g) = g"
                , "f", Success
                )
              -- some equivalent functions
              , ( "_map :: (a -> b) -> [a] -> [b]; _map g xs = [ g x | x <- xs ]"
                , "_map = map", "_map", Success
                )
              , ( "_map f = foldr (\\a bs -> f a : bs) []", "_map = map", "_map", Success )
              , ( "_map f = reverse . foldl (\\bs a -> f a : bs) []"
                , "_map :: (a -> b) -> [a] -> [b]; _map = map", "_map", Success
                )
              , ( "_rev = foldl (flip (:)) []"
                , "_rev :: [a] -> [a]; _rev = reverse", "_rev", Success
                )
              , ( "_rev (x:xs) = _rev xs ++ [x]; _rev [] = []"
                , "_rev :: [a] -> [a]; _rev = reverse", "_rev", Success
                )
              , ( unlines [ "_rev xs = arev xs []"
                          , "   where"
                          , "     arev [] rs = rs"
                          , "     arev (x:xs) rs = arev xs (x:rs)" ]
                , "_rev :: [a] -> [a]; _rev = reverse", "_rev", Success
                )
              -- and some noequivalent
              , ( "_rev = foldr (flip (:)) []", "_rev = reverse", "_rev", WontCompile ignored )
              , ( "_rev = foldr (:) []", "_rev = reverse", "_rev", DifferentValues ignored )
              , ( "_rev (x:xs) = foldl (flip (:)) [x] xs"
                , "_rev = reverse", "_rev", DifferentValues ignored
                ) -- (exceptions for [])
              ]
    putStrLn $ banner r
    if failed > 0 then exitFailure
                 else exitSuccess

banner (passed, 0) = "OK: Passed all " ++ show passed ++ " tests."
banner (passed, failed) = "FAIL: Passed " ++ show passed ++ " out of " ++ show (passed + failed) ++ " tests."

test :: (Integer, Integer) -> (String, String, String, TestingResult) -> IO (Integer, Integer)
test (passed, failed) (student, solution, expr, expected) = do
    putStrLn $ concat [ "Testing ", student, " =?= ", solution, " ..." ]
    res <- compareExpressions expr solution student
    if toConstr res == toConstr expected
        then putStrLn "OK" >> return (passed + 1, failed)
        else do
          putStrLn "FAILED"
          putStrLn $ concat [ showConstr (toConstr res), " /= ", showConstr (toConstr expected) ]
          putStrLn $ show res
          return (passed, failed + 1)


