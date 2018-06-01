{-# LANGUAGE TemplateHaskell, LambdaCase, TupleSections #-}

module Test.Expr.Property where

import Test.QuickCheck ( (===), Blind (..), Arbitrary )
import Test.QuickCheck.Function ( Fun ( Fun ) )
import Control.Monad ( when, replicateM, filterM, zipWithM )
import Language.Haskell.TH ( Q, Name, Cxt
                           , Info (..), Exp (..), Type (..), Pat (..), TyVarBndr (..)
                           , reportWarning, pprint, lookupValueName
                           , reify, newName, mkName )
import Language.Haskell.TH.ExpandSyns ( substInType )
import Data.Int ( Int16 )

import Test.Expr.Types
import Test.Expr.Utils

sprop :: String -> String -> Q Exp
sprop teacher student = (,) <$> lookupValueName teacher <*> lookupValueName student >>= \case
    (Just tname, Just sname) -> prop tname sname
    (Nothing, Nothing) -> fail $ "sprop: Could not find " ++ teacher ++ " and " ++ student
    (Nothing, _)       -> fail $ "sprop: Could not find " ++ teacher
    (_, Nothing)       -> fail $ "sprop: Could not find " ++ student

-- | $(prop 'a 'b) :: Property
-- >>> quickCheck $(prop 'drop 'drop)
-- +++ OK, passed 100 tests.
--
-- >>> quickCheck $(prop 'drop 'take)
-- *** Failed! Falsifiable (after 3 tests):
-- 0
-- [()]
-- [()] /= []
prop :: Name -> Name -> Q Exp
prop teacher student = (,) <$> info teacher <*> info student >>= \case
    ((_, Just (tnam, ttype)), (_, Just (snam, stype))) -> testFun tnam ttype snam stype
    ((t, _), (s, _)) -> fail $ "prop: Invarid arguments for prop:\n        " ++ pprint t ++ "\n        " ++ pprint s

  where
    info x = ex <$> reify x

    ex :: Info -> (Info, Maybe (Name, Type))
    ex i@(VarI     nam typ _) = (i, Just (nam, typ))
    ex i@(ClassOpI nam typ _) = (i, Just (nam, typ))
    ex i@(DataConI nam typ _) = (i, Just (nam, typ))
    ex i                      = (i, Nothing)

testFun :: Name -> Type -> Name -> Type -> Q Exp
testFun tname ttype sname stype = do
    dtty <- degeneralize ttype
    dsty <- degeneralize stype

    when (dtty /= dsty) . fail $ "testFun: incompatible degeneralized types derived:\n        " ++
                                 "teacher: " ++ pprint dtty ++ "\n        " ++
                                 "student: " ++ pprint dsty

    let (targs, rty) = uncurryType dtty
    let ar = length targs
    retEq <- rty `hasInstance` ''Eq
    when (not retEq) . fail $ "testFun: return type not comparable: " ++ pprint rty

    xs <- replicateM ar (newName "x")

    pats <- zipWithM mkpat targs xs
    args <- zipWithM mkvar targs xs
    pure $ LamE pats (VarE '(===) `AppE` (apply tname args) `AppE` (apply sname args))

  where
    -- | construct a pattern from its type and variable name (@x@)
    -- * for function types, it constructs @Fun _ x@
    -- * if the type is not Show-able, wraps the pattern in 'Blind'
    -- * otherwise, it constructs @x@
    mkpat :: Type -> Name -> Q Pat
    mkpat t x = do
        arb <- hasArbitrary baseT
        sh <- hasShow baseT
        when (not arb) . fail $ "testFun: no instance of arbitrary for " ++ pprint t
        let typed = SigP base baseT
        if sh
        then pure typed
        else do
            reportWarning $ "testFun: no instance of Show for " ++ pprint t ++ ", using Blind"
            pure $ ConP 'Blind [typed]
      where
        base | isFunctionType t = ConP 'Fun [WildP, VarP x]
             | otherwise        = VarP x

        baseT | isFunctionType t = ConT ''Fun `AppT` (foldl AppT (TupleT arrt) ct) `AppT` rt
              | otherwise        = t

        (ct, rt) = uncurryType t
        arrt = length ct

    mkvar :: Type -> Name -> Q Exp
    mkvar t x = pure base
      where
        base | isFunctionType t = VarE uc `AppE` VarE x
             | otherwise = VarE x

        (ta, _) = uncurryType t
        uc = mkName ("curry" ++ show (length ta))

type ClassName = Name
type TyVarName = Name

degeneralize :: Type -> Q Type
degeneralize = degen [] []
  where
    degen :: [TyVarBndr] -> Cxt -> Type -> Q Type
    degen bndr cxt (ForallT b c t) = degen (bndr ++ b) (cxt ++ c) t
    degen bndr0 cxt0 t = do
        substc <- extractCandidates bndr0
        cxt <- extractCxt cxt0
        sub <- filterSubstitutions substc cxt

        pure $ foldr substInType t sub

    -- | extract simple contexts to
    extractCxt :: Cxt -> Q [(TyVarName, ClassName)]
    extractCxt = mapM ex
      where
        ex (AppT (ConT c) (VarT v)) = pure (v, c)
        ex x = fail $ "degeneralize: Complex context " ++ pprint x ++ " not supported"

    extractCandidates :: [TyVarBndr] -> Q [(TyVarName, [Type])]
    extractCandidates = mapM ex
      where
        ex (PlainTV x) = ex (KindedTV x StarT)
        ex (KindedTV x StarT) = (x, ) <$> sequence
                                            [ [t| Integer |]  -- the default
                                            , [t| Rational |] -- for fractional
                                            , [t| Int16 |]    -- for bounded
                                            , [t| Double |]   -- for floating-point
                                            ]
        ex (KindedTV x (AppT (AppT ArrowT StarT) StarT)) = (x, ) . (:[]) <$> [t| [] |]
        ex ktv = fail $ "degeneralize: Complex type variable " ++ pprint ktv ++ " not supported"

    filterSubstitutions :: [(TyVarName, [Type])] -> [(TyVarName, ClassName)] -> Q [(TyVarName, Type)]
    filterSubstitutions vs cxt = mapM (\(v, cs) -> subst v cs (map snd $ filter (\x -> fst x == v) $ cxt)) vs

    subst :: TyVarName -> [Type] -> [ClassName] -> Q (TyVarName, Type)
    subst v cands clss = filterM (\t -> and <$> mapM (\c -> t `hasInstance` c) clss) cands >>= \case
        []  -> fail $ "degeneralize: Could not degeneralize " ++ pprint v ++ " with constraints " ++ show cands
        t:_ -> pure (v, t)

hasShow :: Type -> Q Bool
hasShow t = t `hasInstance` ''Show

hasArbitrary :: Type -> Q Bool
hasArbitrary t = t `hasInstance` ''Arbitrary
