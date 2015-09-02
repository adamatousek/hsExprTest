module Main ( main ) where

import Harness


main :: IO ()
main = runTests $
    [ -- unparametrized expressions
      ("f = 2^2^2", "f = (2^2)^2", "f", Success)
    , ("f = True", "f = False", "f", TestFailure ignored )
    , ("f = True", "f = 0", "f", TypeError ignored )
    -- simple functions
    , ("f m n = m `mod` n", "f = mod", "f", Success)
    , ("f _ 0 = 0; f m n = m `mod` n", "f = mod", "f", TestFailure ignored )
    -- polymorphic return type not dependent on argument
    , ("f m = fromIntegral m", "f = fromInteger . toInteger", "f", Success)
    -- , ("f = fromRational", "f m = fromRational m", "f", Success)
    -- generate noncomutative functions
    , ( "f :: (a -> a -> a) -> a -> [a] -> a; f = foldl"
      , "f :: (a -> a -> a) -> a -> [a] -> a; f = foldr"
      , "f", TestFailure ignored
      )
    -- indentation
    , ( "f :: a -> a -> a\nf x y = y"
      , "f :: a -> a -> a\nf = const"
      , "f", TestFailure ignored
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
    , ( "f = const", "f :: a -> a -> a; f = undefined", "f", TypeError ignored )
    -- no IO supported
    , ( "f :: Int -> IO Int; f x = return x", "f :: Int -> IO Int; f = return"
      , "f", RuntimeError ignored
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
    , ( "_map f = (foldr :: (a -> b -> b) -> b -> [a] -> b) (\\a bs -> f a : bs) []", "_map = map", "_map", Success )
    , ( "_map f = reverse . (foldl :: (b -> a -> b) -> b -> [a] -> b) (\\bs a -> f a : bs) []"
      , "_map :: (a -> b) -> [a] -> [b]; _map = map", "_map", Success
      )
    , ( "_rev = (foldl :: (b -> a -> b) -> b -> [a] -> b) (flip (:)) []"
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
    , ( "_rev = (foldr :: (a -> b -> b) -> b -> [a] -> b) (flip (:)) []", "_rev = reverse", "_rev", CompileError ignored )
    , ( "_rev = (foldr :: (a -> b -> b) -> b -> [a] -> b)(:) []", "_rev = reverse", "_rev", TestFailure ignored )
    , ( "_rev (x:xs) = (foldl :: (b -> a -> b) -> b -> [a] -> b) (flip (:)) [x] xs"
      , "_rev = reverse", "_rev", TestFailure ignored
      ) -- (exceptions for [])
    -- exception handling
    , ( unlines [ "binmap :: (a -> a -> b) -> [a] -> [b]"
                , "binmap _ []       = []"
                , "binmap _ [_]      = []"
                , "binmap f (x:y:xs) = f x y : binmap f xs" ]
      , unlines [ "binmap :: (a -> a -> b) -> [a] -> [b]"
                , "binmap f (x:y:xs) = f x y : binmap f xs" ]
      , "binmap", TestFailure ignored )
    , ( "f :: Maybe a -> Maybe (b -> a); f = undefined", "f :: Maybe a -> Maybe (b -> a); f = undefined", "f", RuntimeError ignored )
    ]
    -- ranges
    ++ map (\(x, y, f, r) -> let ir = ("import Test.QuickCheck.Range\n" ++) in (ir x, ir y, f, r))
    [ ( "f :: Range Int 0 10 -> Bool; f _ = True", "f :: Range Int 0 10 -> Bool; f (Range x) = x < 10;", "f", TestFailure ignored )
    ]
