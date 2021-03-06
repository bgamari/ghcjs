{-# LANGUAGE TupleSections #-}

module Gen2.Sinker (sinkPgm, needDelayedInit) where

import UniqSet
import VarSet
import UniqFM
import StgSyn
import Id
import Name
import Module
import Unique
import Literal
import Digraph

import Gen2.ClosureInfo

import Control.Applicative
import Control.Lens
import Data.Char
import Data.Data.Lens
import Data.Traversable
import Data.Maybe
import Data.List (partition)

import qualified Data.List as L
import Gen2.RtsTypes
import Gen2.StgAst
import Language.Javascript.JMacro
import Encoding
import qualified Data.Text as T
import Debug.Trace

{-
  GHC floats constants to the top level. This is fine in native code, but with JS
  they occupy some global variable name. We can unfloat some unexported things:

  - global constructors, as long as they're referenced only once by another global
       constructor and are not in a recursive binding group
  - literals (small literals may also be sunk if they are used more than once)
 -}

sinkPgm :: Module -> [StgBinding] -> (UniqFM StgExpr, [StgBinding])
-- sinkPgm m pgm = -- (emptyUFM, topSortDecls m pgm) -- still some problems
sinkPgm m pgm =
  let usedOnce = collectUsedOnce pgm
      as = concatMap alwaysSinkable pgm
      os = concatMap (onceSinkable m) pgm
      sinkables = listToUFM $
          concatMap alwaysSinkable pgm ++
          filter ((`elementOfUniqSet` usedOnce) . fst) (concatMap (onceSinkable m) pgm)
      isSunkBind (StgNonRec b e) | elemUFM b sinkables = True
      isSunkBind _                                     = False
  in (sinkables, filter (not . isSunkBind) $ topSortDecls m pgm)

-- always sinkable: small literals
alwaysSinkable :: StgBinding -> [(Id, StgExpr)]
alwaysSinkable (StgNonRec b rhs)
  | (StgRhsClosure _ccs _bi _ _upd _srt _ e@(StgLit l)) <- rhs,
     isSmallSinkableLit l && isLocal b = [(b,e)]
  | (StgRhsCon _ccs dc as@[StgLitArg l]) <- rhs,
     isSmallSinkableLit l && isLocal b && isUnboxableCon dc = [(b,StgConApp dc as)]
alwaysSinkable _ = []

isSmallSinkableLit :: Literal -> Bool
isSmallSinkableLit (MachChar c) = ord c < 100000
isSmallSinkableLit (MachInt i)  = i > -100000 && i < 100000
isSmallSinkableLit (MachWord i) = i < 100000
isSmallSinkableLit _            = False

onceSinkable :: Module -> StgBinding -> [(Id, StgExpr)]
onceSinkable m (StgNonRec b rhs)
  | Just e <- getSinkable rhs, isLocal b = [(b,e)]
  where
    getSinkable (StgRhsCon _ccs dc args) | not (any (needDelayedInit m) args)
      = Just (StgConApp dc args)
    getSinkable (StgRhsClosure _ccs _bi _ _upd _srt _ e@(StgLit{}))
      = Just e
    getSinkable _ = Nothing
onceSinkable _ _ = []

{- |
  does this argument force us to do delayed initialization:
    symbols in the current module are sorted, so in non-recursive
    bindings, we don't need to delay initialization

    names from ghc-prim are special, we make sure this package is
    always linked first
-}
needDelayedInit :: Module -> StgArg -> Bool
needDelayedInit m (StgVarArg i) =
  maybe False checkModule (nameModule_maybe . idName $ i)
    where
      checkModule m' =
        moduleName m' /= moduleName m &&
        not (modulePackageId m' == primPackageId && modulePackageId m /= primPackageId)
needDelayedInit _ _ = False

-- | collect all idents used only once in an argument at the top level
--   and never anywhere else
collectUsedOnce :: [StgBinding] -> IdSet
collectUsedOnce binds = intersectUniqSets (usedOnce foldArgs) (usedOnce foldArgsTop)
  where
    usedOnce f = fst . foldrOf (traverse . f) g (emptyUniqSet, emptyUniqSet) $ binds
    g i t@(once, mult)
      | i `elementOfUniqSet` mult = t
      | i `elementOfUniqSet` once
        = (delOneFromUniqSet once i, addOneToUniqSet mult i)
      | otherwise = (addOneToUniqSet once i, mult)

-- | fold over all id in StgArg used at the top level in an StgRhsCon
foldArgsTop :: Fold StgBinding Id
foldArgsTop f e@(StgNonRec b r) 
  | (StgRhsCon ccs dc args) <- r =
     StgNonRec b . StgRhsCon ccs dc <$> (traverse . foldArgsA) f args
  | otherwise                    = pure e
foldArgsTop f (StgRec bs) =
  StgRec <$> sequenceA (map (\(b,r) -> (,) b <$> g r) bs)
    where
      g (StgRhsCon ccs dc args) =
          StgRhsCon ccs dc <$> (traverse . foldArgsA) f args
      g x                       = pure x

-- | fold over all Id in StgArg in the AST
foldArgs :: Fold StgBinding Id
foldArgs f (StgNonRec b r) = StgNonRec b <$> foldArgsR f r
foldArgs f (StgRec bs)     =
  StgRec <$> sequenceA (map (\(b,r) -> (,) b <$> foldArgsR f r) bs)

foldArgsR :: Fold StgRhs Id
foldArgsR f (StgRhsClosure x0 x1 x2 x3 x4 x5 e) =
  StgRhsClosure x0 x1 x2 x3 x4 x5 <$> foldArgsE f e
foldArgsR f (StgRhsCon x y args)                =
  StgRhsCon x y <$> (traverse . foldArgsA) f args

foldArgsE :: Fold StgExpr Id
foldArgsE f (StgApp x args)            = StgApp <$> f x <*> (traverse . foldArgsA) f args
foldArgsE f (StgConApp c args)         = StgConApp c <$> (traverse . foldArgsA) f args
foldArgsE f (StgOpApp x args t)        = StgOpApp x  <$> (traverse . foldArgsA) f args <*> pure t
foldArgsE f (StgLam b e)               = StgLam b    <$> foldArgsE f e
foldArgsE f (StgCase e l1 l2 b s a alts) =
  StgCase <$> foldArgsE f e <*> pure l1 <*> pure l2
          <*> pure b <*> pure s <*> pure a
          <*> sequenceA (map (\(ac,bs,us,e) -> (,,,) ac bs us <$> foldArgsE f e) alts)
foldArgsE f (StgLet b e)               = StgLet <$> foldArgs f b <*> foldArgsE f e
foldArgsE f (StgLetNoEscape l1 l2 b e) = StgLetNoEscape l1 l2 <$> foldArgs f b <*> foldArgsE f e
foldArgsE f (StgSCC cc b1 b2 e)        = StgSCC cc b1 b2 <$> foldArgsE f e
foldArgsE f (StgTick m i e)            = StgTick m i <$> foldArgsE f e
foldArgsE f e                          = pure e

foldArgsA :: Fold StgArg Id
foldArgsA f (StgVarArg i) = StgVarArg <$> f i
foldArgsA _ a             = pure a

isLocal :: Id -> Bool
isLocal i = isNothing (nameModule_maybe . idName $ i)

-- | since we have sequential initialization,
--   topsort the non-recursive constructor bindings
topSortDecls :: Module -> [StgBinding] -> [StgBinding]
topSortDecls m binds = rest ++ nr'
  where
    (nr, rest) = partition isNonRec binds
    isNonRec (StgNonRec {}) = True
    isNonRec _              = False
    vs   = map getV nr
    keys = mkUniqSet (map snd vs)
    getV e@(StgNonRec b _) = (e, b)
    getV _                 = error "topSortDecls: getV, unexpected binding"
    collectDeps (StgNonRec b (StgRhsCon _ dc args)) =
      [ (i, b) | StgVarArg i <- args, i `elementOfUniqSet` keys ]
    collectDeps _ = []
    g = graphFromVerticesAndAdjacency vs (concatMap collectDeps nr)
    nr' | (not . null) [()| CyclicSCC _ <- stronglyConnCompG g]
            = error "topSortDecls: unexpected cycle"
        | otherwise = map fst (topologicalSortG g)
