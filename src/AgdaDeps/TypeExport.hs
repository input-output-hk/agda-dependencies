{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
-- Optional structural type evidence in the expanded-v2 graph contract.
-- No normalization/conversion checker; unsupported forms stay explicit.
module AgdaDeps.TypeExport
  ( initializeTypeExport, captureTypeDefinition, readTypeTerms ) where

import Control.Monad (forM, when)
import Control.Monad.IO.Class (liftIO)
import qualified Control.Monad.State.Strict as ST
import qualified Data.Aeson as A
import Data.Aeson ((.=))
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.IORef
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import System.IO.Unsafe (unsafePerformIO)

import Agda.Syntax.Common
  ( Arg(..), ArgInfo(..), defaultArgInfo, getArgInfo, getHiding, getRelevance, getQuantity
  , getCohesion, Modality(..), PolarityModality(..)
  , Quantity(..), Relevance(..) )
import Agda.Syntax.Internal
  ( Term(..), pattern Var, Type, Type''(..), Abs(..), domIsFinite, unDom, conName
  , Elim'(..), Sort, Sort'(..), Level, Level'(..), PlusLevel'(..)
  , Clause(..), telToList, qnameModule )
import Agda.Syntax.Internal.Generic (TermLike, traverseTermM)
import Agda.Syntax.Literal (Literal(..))
import Agda.TypeChecking.Monad
  ( TCM, Definition(..), pattern Function, funClauses, lookupSection )
import Agda.Utils.Size (size)
import Agda.TypeChecking.Telescope (telView)
import Agda.TypeChecking.Substitute (TelV(..))
import Agda.TypeChecking.Reduce (reduceDefCopy)
import Agda.TypeChecking.Monad.Base (Reduced(..))
import AgdaDeps.NodeKey (nodeKeyOfQ, moduleKeyOfQ, bindingLineOfQ)

data Tree = Tree String String [String] Bool [Tree] deriving (Eq, Ord, Show)
data Captured = Captured String String (Maybe Int) (Maybe FilePath) Int Tree
  [(Tree, [Tree])] deriving Show
data ExportState = ExportState Bool (M.Map String Captured)

{-# NOINLINE exportRef #-}
exportRef :: IORef ExportState
exportRef = unsafePerformIO (newIORef (ExportState False M.empty))

initializeTypeExport :: Bool -> IO ()
initializeTypeExport enabled = writeIORef exportRef (ExportState enabled M.empty)

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

captureTypeDefinition :: Maybe FilePath -> Definition -> TCM ()
captureTypeDefinition file Defn{..} = do
  ExportState enabled _ <- liftIO (readIORef exportRef)
  let owner = moduleKeyOfQ defName
  when enabled $ do
    -- Only body-bearing functions need the reducing telescope view. A
    -- postulate's structural signature may contain a nonterminating alias.
    clauses <- case theDef of
      Function{..} | any (isJust . clauseBody) funClauses -> do
        TelV _ result <- telView defType
        pure $ case unEl result of Sort{} -> funClauses; _ -> []
      _ -> pure []
    -- Module-copy wrappers are removed from the exported terms below.
    signature <- removeCopies defType
    sectionParameters <- size <$> lookupSection (qnameModule defName)
    bodies <- fmap concat $ forM clauses $ \cl -> case clauseBody cl of
      Nothing -> pure []
      Just rawBody -> do
        body <- removeCopies rawBody
        telescope <- removeCopies (clauseTel cl)
        pure [ (termTree body,
              [Tree "binder" nm (binderInfo (getArgInfo d)) False
                [if ordinaryInfo (getArgInfo d) && not (domIsFinite d)
                 then typeTree ty else Tree "unsupported" "context-modality-or-finite-domain" [] False []]
              | d <- telToList telescope, let (nm, ty) = unDom d]) ]
    let key = nodeKeyOfQ defName
        entry = Captured key owner (bindingLineOfQ defName) file sectionParameters (typeTree signature) bodies
    liftIO $ modifyIORef' exportRef $ \(ExportState p defs) ->
      ExportState p (M.insert key entry defs)

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

encodeCaptured :: Captured -> ST.State Intern A.Value
encodeCaptured (Captured name owner line file sectionParameters signature bodies) = do
  sig <- intern signature
  bs <- forM bodies $ \(body, ctx) -> do
    root <- intern body
    telescope <- mapM intern ctx
    pure (A.object ["root" .= root, "context" .= telescope])
  pure $ A.object ["name" .= name, "module" .= owner, "line" .= line,
    "file" .= file, "sectionParameters" .= sectionParameters,
    "signature" .= sig, "bodies" .= bs]

-- Only retain definitions in the final graph; no hidden second scope or file.
readTypeTerms :: [String] -> IO (Maybe String)
readTypeTerms retained = do
  ExportState enabled defs <- readIORef exportRef
  if not enabled then pure Nothing else do
    let selected = M.elems (M.restrictKeys defs (M.keysSet $ M.fromList [(n,()) | n <- retained]))
        (entries, (_, nodes)) = ST.runState
          (mapM encodeCaptured selected) (M.empty, M.empty)
    pure $ Just $ T.unpack $ TE.decodeUtf8 $ BL.toStrict $ A.encode $ A.object
      ["v" .= (1 :: Int), "nodes" .= M.elems nodes, "definitions" .= entries]
