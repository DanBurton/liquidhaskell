{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances    #-}

-- | This module contains the code that DOES reflection; i.e. converts Haskell
--   definitions into refinements.

module Language.Haskell.Liquid.Bare.Axiom ( makeHaskellAxioms ) where

import Prelude hiding (error)
import Prelude hiding (mapM)
import qualified Control.Exception         as Ex

import           Control.Monad.Except      hiding (forM, mapM)
import           Control.Monad.State       hiding (forM, mapM)
import qualified Text.PrettyPrint.HughesPJ as PJ -- (text)
import qualified Data.HashSet              as S
import qualified Data.Maybe                as Mb 

import           Language.Fixpoint.Misc
import qualified Language.Haskell.Liquid.Measure as Ms
import qualified Language.Fixpoint.Types as F
import qualified Language.Haskell.Liquid.GHC.API as Ghc 
import           Language.Haskell.Liquid.Types.RefType
import           Language.Haskell.Liquid.Transforms.CoreToLogic
import           Language.Haskell.Liquid.GHC.Misc
import           Language.Haskell.Liquid.Types

import           Language.Haskell.Liquid.Bare.Types as Bare
-----------------------------------------------------------------------------------------------
makeHaskellAxioms :: GhcSrc -> Ms.BareSpec -> F.TCEmb Ghc.TyCon -> Bare.Env -> Bare.TycEnv -> GhcSpecSig 
                  -> [(Ghc.Var, LocSpecType, F.Equation)]
-----------------------------------------------------------------------------------------------
makeHaskellAxioms embs cbs spec sp adts = mempty -- undefined -- TODO-REBARE 
{- 
do
  xtvds <- getReflectDefs spec sp cbs
  forM_ xtvds $ \(x,_,v,_) -> updateLMapXV x v
  lmap  <- logicEnv <$> get
  let dm = dataConMap adts
  mapM (makeAxiom embs lmap dm) xtvds
-}

getReflectDefs :: GhcSpecSig -> Ms.BareSpec -> [Ghc.CoreBind] 
               -> [(LocSymbol, Maybe SpecType, Ghc.Var, Ghc.CoreExpr)]
getReflectDefs sig sp cbs = findVarDefType cbs sigs <$> xs
  where
    sigs                  = gsTySigs sig 
    xs                    = S.toList (Ms.reflects sp)

findVarDefType :: [Ghc.CoreBind] -> [(Ghc.Var, LocSpecType)] -> LocSymbol
               -> (LocSymbol, Maybe SpecType, Ghc.Var, Ghc.CoreExpr)
findVarDefType cbs sigs x = case findVarDef (val x) cbs of
  Just (v, e) -> if Ghc.isExportedId v
                   then (x, val <$> lookup v sigs, v, e)
                   else Ex.throw $ mkError x ("Lifted functions must be exported; please export " ++ show v)
  Nothing     -> Ex.throw $ mkError x "Cannot lift haskell function"



{- 

updateLMapXV :: LocSymbol -> Var -> BareM ()
updateLMapXV x v = do
  updateLMap x x v
  updateLMap (x {val = (F.symbol . showPpr . getName) v}) x v

--------------------------------------------------------------------------------
makeAxiom :: F.TCEmb TyCon
          -> LogicMap
          -> DataConMap
          -> (LocSymbol, Maybe SpecType, Var, CoreExpr)
          -> BareM (Var, LocSpecType, AxiomEq)
--------------------------------------------------------------------------------
makeAxiom tce lmap dm (x, mbT, v, def) = do
  insertAxiom v Nothing
  updateLMap x x v
  updateLMap (x{val = (F.symbol . showPpr . getName) v}) x v
  let (t, e) = makeAssumeType tce lmap dm x mbT v def
  return (v, t, e)

updateLMap :: LocSymbol -> LocSymbol -> Var -> BareM ()
updateLMap x y vv
  | val x /= val y && isFun (varType vv)
  = insertLogicEnv ("UPDATELMAP: vv =" ++ show vv) x ys (F.eApps (F.EVar $ val y) (F.EVar <$> ys))
  | otherwise
  = return ()
  where
    nargs = dropWhile isClassType $ ty_args trep
    trep  = toRTypeRep ((ofType $ varType vv) :: RRType ())
    ys    = zipWith (\i _ -> F.symbol ("x" ++ show i)) [1..] nargs

    isFun (FunTy _ _)    = True
    isFun (ForAllTy _ t) = isFun t
    isFun  _             = False

-}

mkError :: LocSymbol -> String -> Error
mkError x str = ErrHMeas (sourcePosSrcSpan $ loc x) (pprint $ val x) (PJ.text str)

makeAssumeType
  :: F.TCEmb Ghc.TyCon -> LogicMap -> DataConMap -> LocSymbol -> Maybe SpecType
  -> Ghc.Var -> Ghc.CoreExpr
  -> (LocSpecType, F.Equation)
makeAssumeType tce lmap dm x mbT v def
  = (x {val = at `strengthenRes` F.subst su ref},  F.mkEquation (val x) xts le out)
  where
    t     = Mb.fromMaybe (ofType $ Ghc.varType v) mbT
    out   = rTypeSort tce (ty_res tRep)
    at    = F.notracepp ("AXIOM-TYPE: " ++ showpp (x, toType t)) $ axiomType x t
    tRep  = toRTypeRep at
    xArgs = F.EVar <$> [x | (x, t) <- zip (ty_binds tRep) (ty_args tRep), not (isClassType t)]
    _msg  = unwords [showpp x, showpp mbT]
    le    = case runToLogicWithBoolBinds bbs tce lmap dm mkErr (coreToLogic def') of
              Right e -> e
              Left  e -> panic Nothing (show e)
    ref        = F.Reft (F.vv_, F.PAtom F.Eq (F.EVar F.vv_) le)
    mkErr s    = ErrHMeas (sourcePosSrcSpan $ loc x) (pprint $ val x) (PJ.text s)
    bbs        = filter isBoolBind xs
    (xs, def') = grabBody (normalize def)
    su         = F.mkSubst  $ zip (F.symbol     <$> xs) xArgs
                           ++ zip (simplesymbol <$> xs) xArgs
    xts        = zipWith (\x t -> (F.symbol x, rTypeSortExp tce t)) xs ts
    ts         = filter (not . isClassType) (ty_args tRep)

rTypeSortExp :: F.TCEmb Ghc.TyCon -> SpecType -> F.Sort
rTypeSortExp tce = typeSort tce . Ghc.expandTypeSynonyms . toType

-- makeSMTAxiom :: LocSymbol -> [(Symbol, F.Sort)] -> F.Expr -> F.Sort -> AxiomEq
-- makeSMTAxiom = F.mkEquation . val

grabBody :: Ghc.CoreExpr -> ([Ghc.Var], Ghc.CoreExpr)
grabBody (Ghc.Lam x e)  = (x:xs, e') where (xs, e') = grabBody e
grabBody (Ghc.Tick _ e) = grabBody e
grabBody e              = ([], e)

isBoolBind :: Ghc.Var -> Bool
isBoolBind v = isBool (ty_res $ toRTypeRep ((ofType $ Ghc.varType v) :: RRType ()))

strengthenRes :: SpecType -> F.Reft -> SpecType
strengthenRes t r = fromRTypeRep $ trep {ty_res = ty_res trep `strengthen` F.ofReft r }
  where
    trep = toRTypeRep t


class Subable a where
  subst :: (Ghc.Var, Ghc.CoreExpr) -> a -> a

instance Subable Ghc.Var where
  subst (x, ex) z 
    | x == z, Ghc.Var y <- ex = y
    | otherwise           = z

instance Subable Ghc.CoreExpr where
  subst (x, ex) (Ghc.Var y)
    | x == y    = ex
    | otherwise = Ghc.Var y
  subst su (Ghc.App f e)
    = Ghc.App (subst su f) (subst su e)
  subst su (Ghc.Lam x e)
    = Ghc.Lam x (subst su e)
  subst su (Ghc.Case e x t alts)
    = Ghc.Case (subst su e) x t (subst su <$> alts)
  subst su (Ghc.Let (Ghc.Rec xes) e)
    = Ghc.Let (Ghc.Rec (mapSnd (subst su) <$> xes)) (subst su e)
  subst su (Ghc.Let (Ghc.NonRec x ex) e)
    = Ghc.Let (Ghc.NonRec x (subst su ex)) (subst su e)
  subst su (Ghc.Cast e t)
    = Ghc.Cast (subst su e) t
  subst su (Ghc.Tick t e)
    = Ghc.Tick t (subst su e)
  subst _ e 
    = e 

instance Subable Ghc.CoreAlt where
  subst su (c, xs, e) = (c, xs, subst su e)

-- | Specification for Haskell function
axiomType
  :: (TyConable c) => LocSymbol -> RType c tv RReft
  -> RType c tv RReft
axiomType s t = fromRTypeRep (tr {ty_res = res, ty_binds = xs})
  where
    res           = strengthen (ty_res tr) (singletonApp s ys)
    ys            = fst $ unzip $ dropWhile (isClassType . snd) xts
    xts           = safeZip "axiomBinds" xs (ty_args tr)
    xs            = zipWith unDummy bs [1..]
    tr            = toRTypeRep t
    bs            = ty_binds tr

unDummy :: F.Symbol -> Int -> F.Symbol
unDummy x i
  | x /= F.dummySymbol = x
  | otherwise          = F.symbol ("lq" ++ show i)

singletonApp :: F.Symbolic a => LocSymbol -> [a] -> UReft F.Reft
singletonApp s ys = MkUReft r mempty mempty
  where
    r             = F.exprReft (F.mkEApp s (F.eVar <$> ys))
