{-# LANGUAGE TemplateHaskell, LambdaCase, TupleSections, Unsafe
           , NamedFieldPuns, RecordWildCards
           #-}

-- | Property generation. Allows to generate property which compares two
-- implementations of the same functionality.
--
-- (c) 2018 Vladimír Štill

module Test.Expr.Property ( prop, Prop (..) ) where

import Test.QuickCheck ( Blind (..), Arbitrary )
import Test.QuickCheck.Function ( Fun ( Fun ) )
import Control.Monad ( unless, replicateM, filterM, zipWithM )
import Language.Haskell.TH ( Q, Name, Cxt
                           , Info (..), Exp (..), Type (..), Pat (..), TyVarBndr (..)
                           , reportWarning, pprint, reify, newName, mkName )
import Language.Haskell.TH.ExpandSyns ( expandSyns )
import Data.Int ( Int16 )
import Data.List ( intercalate )
import Data.PartialOrder ( gte )
import Data.Coerce ( coerce )

import Text.Printf.Mauke.TH ( sprintf )

import Test.Expr.Types
import Test.Expr.Utils

type Student a = a
type Teacher a = a

data Prop = Prop { comparer :: Exp
                 , pattern :: Maybe Pat
                 , typeOrder :: TypeOrder
                 , teacherName :: Teacher Name
                 , studentName :: Student Name
                 } deriving ( Eq, Show )

-- | $(prop 'cmp 'a 'b) :: Property
-- >>> quickCheck $(prop '(===) 'drop 'drop)
-- +++ OK, passed 100 tests.
--
-- >>> quickCheck $(prop '(===) 'drop 'take)
-- *** Failed! Falsifiable (after 3 tests):
-- 0
-- [()]
-- [()] /= []
prop :: Prop -> Q Exp
prop p@Prop {..} = (,) <$> info teacherName <*> info studentName >>= \case
    ((_, Just (tnam, ttype)), (_, Just (snam, stype))) ->
            testFun p { teacherName = tnam, studentName = snam } ttype stype
    ((t, _), (s, _)) ->
            $(pfail "prop: Invarid arguments for prop:\n        %s\n        %s") (pprint t) (pprint s)

  where
    info x = ex <$> reify x

    ex :: Info -> (Info, Maybe (Name, Type))
    ex i@(VarI     nam typ _) = (i, Just (nam, typ))
    ex i@(ClassOpI nam typ _) = (i, Just (nam, typ))
    ex i@(DataConI nam typ _) = (i, Just (nam, typ))
    ex i                      = (i, Nothing)

testFun :: Prop -> Teacher Type -> Student Type -> Q Exp
testFun Prop {..} ttype0 stype0 = do
    let nttype = normalizeContext ttype0
    ttype <- expandSyns $ stripAnnotations nttype
    stype <- expandSyns $ normalizeContext stype0

    (ord, cmpty) <- unifyOrFail ttype stype
    unless (ord `gte` typeOrder) $ $(pfail "The student's type is not valid: expecting %s, but %s\n\tteacher: %s\n\tstudent: %s")
            (typeOrdExpected typeOrder) (typeOrdErr ord) (ppty ttype) (ppty stype)

    dcmpty <- degeneralize cmpty

    let (targs, rty) = uncurryType dcmpty
    let ar = length targs
    retEq <- rty `hasInstance` ''Eq
    unless retEq . $(pfail "testFun: return type not comparable: %s") $ pprint rty

    (pats, args) <- case pattern of
        Nothing -> do xs <- replicateM ar (newName "x")
                      pats <- zipWithM mkpat targs xs
                      args <- zipWithM mkvar targs xs
                      pure (pats, args)
        Just pats0 -> do let xs = extractVars pats0
                             pats = untupP pats0
                         unless (length xs == length targs) $(pfail "teacher-provided patter does not match arity of the expression's type")
                         args <- zipWithM mkvar targs xs
                         pure (pats, args)

    pure $ LamE pats (UInfixE (apply teacherName args `SigE` rty) comparer (apply studentName args `SigE` rty))

  where
    stripAnnotations = id

    unifyOrFail tty sty = unify tty sty >>= \case
        Left err -> uncurry typeFail err
        Right (ord, cmpty) -> pure (ord, cmpty)

    typeFail LeftType err = $(pfail "error in teacher type: %s\n\t%s") err (ppty ttype0)
    typeFail RightType err = $(pfail "error in student type: %s\n\t%s") err (ppty stype0)
    typeFail BothTypes err = $(pfail "type mismatch: %s\n\tteacher: %s\n\tstudent: %s") err (ppty ttype0) (ppty stype0)

    typeOrdExpected :: TypeOrder -> String
    typeOrdExpected TEqual = "types to be equal"
    typeOrdExpected TLessGeneral = "student's type to be more general"
    typeOrdExpected TMoreGeneral = "student's type to be less general"
    typeOrdExpected TUnifiable = "types to be unifiable"

    typeOrdErr :: TypeOrder -> String
    typeOrdErr TEqual = "they are equal"
    typeOrdErr TLessGeneral = "the student's type is more general then the teacher's type"
    typeOrdErr TMoreGeneral = "the student's type is less general then the teacher's type"
    typeOrdErr TUnifiable = "they are unifiable, but neither of them is more general then the other"

    -- | construct a pattern from its type and variable name (@x@)
    -- * for function types, it constructs @Fun _ x@
    -- * if the type is not Show-able, wraps the pattern in 'Blind'
    -- * otherwise, it constructs @x@
    mkpat :: Type -> Name -> Q Pat
    mkpat t x = do
        arb <- hasArbitrary baseT
        sh <- hasShow baseT
        unless arb . $(pfail "testFun: no instance of arbitrary for %s") $ pprint t
        let typed = SigP base baseT
        if sh
        then pure typed
        else do
            reportWarning . $(sprintf "testFun: no instance of Show for %s, using Blind") $ pprint t
            pure $ ConP 'Blind [typed]
      where
        base | isFunctionType t = ConP 'Fun [WildP, VarP x]
             | otherwise        = VarP x

        baseT | isFunctionType t = ConT ''Fun `AppT` foldl AppT (TupleT arrt) ct `AppT` rt
              | otherwise        = t

        (ct, rt) = uncurryType t
        arrt = length ct

    mkvar :: Type -> Name -> Q Exp
    mkvar t x = pure $ (VarE 'coerce `AppE` base) `SigE` t
      where
        base | isFunctionType t = VarE uc `AppE` VarE x
             | otherwise = VarE x

        (ta, _) = uncurryType t
        uc = mkName ("curry" ++ show (length ta))

    extractVars :: Pat -> [Name]
    extractVars (LitP _)            = []
    extractVars (VarP x)            = [x]
    extractVars (TupP ps)           = concatMap extractVars ps
    extractVars (UnboxedTupP ps)    = concatMap extractVars ps
    extractVars (UnboxedSumP p _ _) = extractVars p
    extractVars (ConP _ ps)         = concatMap extractVars ps
    extractVars (InfixP p1 _ p2)    = extractVars p1 ++ extractVars p2
    extractVars (UInfixP p1 _ p2)   = extractVars p1 ++ extractVars p2
    extractVars (ParensP p)         = extractVars p
    extractVars (TildeP p)          = extractVars p
    extractVars (BangP p)           = extractVars p
    extractVars (AsP _ p)           = extractVars p
    extractVars WildP               = []
    extractVars (RecP _ fp)         = concatMap (extractVars . snd) fp
    extractVars (ListP ps)          = concatMap extractVars ps
    extractVars (SigP p _)          = extractVars p
    extractVars (ViewP _ p)         = extractVars p


    untupP :: Pat -> [Pat]
    untupP (TupP ps) = ps
    untupP p         = [p]

type ClassName = Name
type TyVarName = Name

degeneralize :: Type -> Q Type
degeneralize t0 = degen [] [] $ normalizeContext t0
  where
    degen :: [TyVarBndr] -> Cxt -> Type -> Q Type
    degen bndr cxt (ForallT b c t) = degen (bndr ++ b) (cxt ++ c) t
    degen bndr0 cxt0 t = do
        substc <- extractCandidates bndr0
        cxt <- extractCxt cxt0
        sub <- filterSubstitutions substc cxt

        pure $ t // sub

    -- | extract simple contexts to
    extractCxt :: Cxt -> Q [(TyVarName, ClassName)]
    extractCxt = mapM ex
      where
        ex (AppT (ConT c) (VarT v)) = pure (v, c)
        ex x = $(pfail "degeneralize: Complex context %s not supported") $ pprint x

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
        ex ktv = $(pfail "degeneralize: Complex type variable %s not supported") $ pprint ktv

    filterSubstitutions :: [(TyVarName, [Type])] -> [(TyVarName, ClassName)] -> Q [(TyVarName, Type)]
    filterSubstitutions vs cxt = mapM (\(v, cs) -> subst v cs (map snd $ filter (\x -> fst x == v) cxt)) vs

    subst :: TyVarName -> [Type] -> [ClassName] -> Q (TyVarName, Type)
    subst v cands clss = filterM (\t -> and <$> mapM (\c -> t `hasInstance` c) clss) cands >>= \case
        []  -> $(pfail "degeneralize: Could not degeneralize %s with constraints %s")
                (pprint v) (intercalate "," $ map pprint clss)
        t:_ -> pure (v, t)

hasShow :: Type -> Q Bool
hasShow t = t `hasInstance` ''Show

hasArbitrary :: Type -> Q Bool
hasArbitrary t = t `hasInstance` ''Arbitrary
