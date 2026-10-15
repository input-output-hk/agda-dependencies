{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
-- Shared structural codec. No conversion checking or general normalization.
module AgdaDeps.TermCodec
  ( Tree(..), binderInfo, ordinaryInfo, typeTree, termTree, removeCopies
  , Intern, intern, contextTrees, limitedTree ) where

import qualified Control.Monad.State.Strict as ST
import qualified Data.Aeson as A
import Data.Aeson ((.=))
import qualified Data.Map.Strict as M
import Data.List (isPrefixOf)

import Agda.Syntax.Common
  ( Arg(..), ArgInfo(..), defaultArgInfo, getArgInfo, getHiding, getRelevance, getQuantity
  , getCohesion, Modality(..), PolarityModality(..)
  , Quantity(..), Relevance(..) )
import Agda.Syntax.Internal
  ( Term(..), pattern Var, Type, Type''(..), Abs(..), domIsFinite, unDom, conName
  , Elim'(..), Sort, Sort'(..), Level, Level'(..), PlusLevel'(..)
  , Telescope, telToList )
import Agda.Syntax.Internal.Generic (TermLike, traverseTermM)
import Agda.Syntax.Literal (Literal(..))
import Agda.TypeChecking.Monad (TCM)
import Agda.TypeChecking.Reduce (reduceDefCopy)
import Agda.TypeChecking.Monad.Base (Reduced(..))
import AgdaDeps.NodeKey (nodeKeyOfQ)

data Tree = Tree String String [String] Bool [Tree] deriving (Eq, Ord, Show)

binderInfo :: ArgInfo -> [String]
binderInfo a = [show (getHiding a), relevance (getRelevance a), quantity (getQuantity a),
  show (modPolarityAnn p) ++ ":" ++ show (modPolarityLock p)]
  where
    p = modPolarity (argInfoModality a)
    relevance Relevant{} = "Relevant"
    relevance ShapeIrrelevant{} = "ShapeIrrelevant"
    relevance Irrelevant{} = "Irrelevant"
    quantity Quantity0{} = "0"
    quantity Quantity1{} = "1"
    quantity Quantityω{} = "omega"

dependent :: Abs a -> Bool
dependent Abs{} = True
dependent NoAbs{} = False

ordinaryInfo :: ArgInfo -> Bool
ordinaryInfo a = getCohesion a == getCohesion defaultArgInfo
  && argInfoAnnotation a == argInfoAnnotation defaultArgInfo

typeTree :: Type -> Tree
typeTree (El s t) = Tree "type" "" [] False [termTree t, sortTree s]

termTree :: Term -> Tree
termTree = \case
  Var n es -> elims (Tree "var" (show n) [] False []) es
  Def q es -> elims (Tree "def" (nodeKeyOfQ q) [] False []) es
  Con c _ es -> elims (Tree "con" (nodeKeyOfQ (conName c)) [] False []) es
  Lam a b | ordinaryInfo a -> Tree "lam" (absName b) (binderInfo a) (dependent b) [termTree (unAbs b)]
          | otherwise -> Tree "unsupported" "lambda-modality" [] False []
  -- Keep even unsupported binders in the telescope: inherited section
  -- parameters still consume these Pis, and the domain marks them unsupported.
  Pi d b ->
    Tree "pi" (absName b) (binderInfo (getArgInfo d)) (dependent b)
      [if ordinaryInfo (getArgInfo d) && not (domIsFinite d)
       then typeTree (unDom d)
       else Tree "unsupported" "pi-modality-or-finite-domain" [] False [],
       typeTree (unAbs b)]
  Sort s -> sortTree s
  Level l -> levelTree l
  Lit (LitQName q) -> Tree "lit" ("LitQName " ++ nodeKeyOfQ q) [] False []
  Lit l -> Tree "lit" (show l) [] False []
  DontCare t -> Tree "irrelevant" "" [] False [termTree t]
  MetaV m _ -> Tree "unsupported" ("meta:" ++ show m) [] False []
  Dummy reason _ -> Tree "unsupported" ("dummy:" ++ show reason) [] False []
  where
    elims = foldl one
    one f (Apply a) | ordinaryInfo (getArgInfo a) =
      Tree "app" "" (binderInfo (getArgInfo a)) False [f, termTree (unArg a)]
                    | otherwise = Tree "unsupported" "application-modality" [] False []
    one f (Proj _ q) = Tree "proj" (nodeKeyOfQ q) [] False [f]
    one _ IApply{} = Tree "unsupported" "cubical-application" [] False []

sortTree :: Sort -> Tree
sortTree = \case
  Univ u l -> Tree "sort" (show u) [] False [levelTree l]
  Inf u n -> Tree "sort-inf" (show u ++ ":" ++ show n) [] False []
  SizeUniv -> Tree "sort-constant" "SizeUniv" [] False []
  LockUniv -> Tree "sort-constant" "LockUniv" [] False []
  LevelUniv -> Tree "sort-constant" "LevelUniv" [] False []
  IntervalUniv -> Tree "sort-constant" "IntervalUniv" [] False []
  s -> Tree "unsupported" ("sort:" ++ show s) [] False []

levelTree :: Level -> Tree
levelTree (Max n xs) = Tree "level" (show n) [] False
  [Tree "level-plus" (show k) [] False [termTree t] | Plus k t <- xs]

-- Use Agda's dedicated module-copy reducer, not a conversion checker or
-- broad normalizer. Named user predicates and local helpers remain visible.
removeCopies :: TermLike a => a -> TCM a
removeCopies = traverseTermM (step (64 :: Int))
  where
    step 0 t = pure t
    step fuel t@(Def q es) = reduceDefCopy q es >>= \case
      NoReduction _ -> pure t
      YesReduction _ replacement -> traverseTermM (step (fuel - 1)) replacement
    step _ t = pure t

-- Hash-cons complete structural nodes after capture, in deterministic owner
-- order. Binder display names are retained but ignored by consumer matching.
type Intern = (M.Map (String,String,[String],Bool,[Int]) Int, M.Map Int A.Value)

intern :: Tree -> ST.State Intern Int
intern (Tree tag name info binds children) = do
  ids <- mapM intern children
  (keys, nodes) <- ST.get
  let key = (tag,name,info,binds,ids)
  case M.lookup key keys of
    Just n -> pure n
    Nothing -> do
      let n = M.size keys
      ST.put (M.insert key n keys, M.insert n (A.object
        ["tag" .= tag, "name" .= name, "info" .= info,
         "binds" .= binds, "children" .= ids]) nodes)
      pure n


contextTrees :: Telescope -> [Tree]
contextTrees telescope=
  [Tree "binder" nm (binderInfo (getArgInfo d)) False
    [if ordinaryInfo (getArgInfo d) && not (domIsFinite d)
      then typeTree ty else Tree "unsupported" "context-modality-or-finite-domain" [] False []]
  | d<-telToList telescope,let (nm,ty)=unDom d]

-- A bounded prefix of each contextual root. Limits do not masquerade as terms.
limitedTree :: Int -> Tree -> Tree
limitedTree cap tree=ST.evalState (go tree) cap
  where
    go :: Tree -> ST.State Int Tree
    go (Tree tag name info binds children)=do
      fuel<-ST.get
      if fuel<=0 then pure (Tree "unsupported" "capture-node-limit" [] False []) else do
        ST.put (fuel-1)
        let label=if tag=="unsupported" && "sort:" `isPrefixOf` name then takeWhile (/= ' ') name else name
        Tree tag label info binds <$> mapM go children
