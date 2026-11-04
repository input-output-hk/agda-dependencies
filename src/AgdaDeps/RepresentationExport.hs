{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
-- Optional declaration inventories and bounded constructor views. No proof
-- claims, graph edges, source edits, or independent term representation.
module AgdaDeps.RepresentationExport
  ( initializeRepresentations, noteRepresentationSelection, captureRepresentation
  , representationReferences, encodeRepresentations ) where

import Control.DeepSeq (NFData, force)
import Control.Exception (evaluate)
import Control.Monad (forM_, when)
import Control.Monad.Except (catchError)
import Control.Monad.IO.Class (liftIO)
import qualified Control.Monad.State.Strict as ST
import qualified Data.Aeson as A
import Data.Aeson ((.=))
import Data.IORef
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Maybe (isJust)
import GHC.Generics (Generic)
import System.IO.Unsafe (unsafePerformIO)
import Agda.Syntax.Abstract.Name (QName)
import Agda.Syntax.Common (HasEta'(..), PatternOrCopattern(..), Induction(..))
import Agda.Syntax.Internal (conName, unDom)
import Agda.TypeChecking.Monad
  ( TCM, Definition(..), pattern Datatype, pattern Record, pattern Constructor
  , dataPars, dataIxs, dataCons, dataMutual, dataClause
  , recPars, recConHead, recFields, recNamedCon, recMutual, recClause
  , recInduction, recEtaEquality, conData
  , getConstInfo, inTopContext, inConcreteMode, notUnderOpaque )
import qualified Agda.TypeChecking.Monad as TC
import Agda.TypeChecking.Telescope (telView)
import Agda.TypeChecking.Substitute (TelV(..))
import AgdaDeps.TermCodec
import AgdaDeps.NodeKey (nodeKeyOfQ)
import AgdaDeps.Util (boundedQueryTCM)

data Decl = Decl
  { declName :: String, declKind :: String, declParameters :: Int, declIndices :: Int
  , declConstructors :: [String], declRecursion :: String, declRecord :: Maybe A.Value
  , declFields :: [String], declLimits :: [String]
  } deriving Generic
instance NFData Decl
data View a = View String String [a] (Maybe a) String [String] deriving Generic
instance NFData a => NFData (View a)
data RepState = RepState (M.Map String Decl) (M.Map String (View Int)) (S.Set String) (M.Map String String)
{-# NOINLINE repRef #-}
repRef :: IORef RepState
repRef = unsafePerformIO (newIORef (RepState M.empty M.empty S.empty M.empty))

initializeRepresentations :: IO ()
initializeRepresentations = do
  writeIORef repRef (RepState M.empty M.empty S.empty M.empty)
  writeIORef pendingRef M.empty

noteRepresentationSelection :: Definition -> TCM ()
noteRepresentationSelection Defn{..} = case theDef of
  Datatype{} -> note
  Record{} -> note
  _ -> pure ()
  where note = liftIO $ modifyIORef' repRef $ \(RepState ds vs selected omitted) ->
          RepState ds vs (S.insert (nodeKeyOfQ defName) selected) omitted

recursion :: Maybe [a] -> String
recursion Nothing = "unknown"
recursion (Just []) = "nonrecursive"
recursion (Just _) = "recursive"

-- Called only after the ordinary term definition was interned, so following
-- constructor/field signatures cannot recursively recapture its owner.
captureRepresentation :: (QName -> String) -> Definition -> (Definition -> TCM ()) -> TCM ()
captureRepresentation keyOf d@Defn{..} ensure = case theDef of
  Datatype{..} -> do
    let cs = dataCons
        limits = ["module-copy" | isJust dataClause] ++ pathLimits
        pathLimits = ["path-constructors" | not (null $ TC.dataPathCons theDef)]
    save (Decl key "datatype" dataPars dataIxs (map keyOf cs)
          (recursion dataMutual) Nothing [] limits) cs []
  Record{..} -> do
    let cs = [conName recConHead]
        fs = map unDom recFields
        eta = Just $ case recEtaEquality theDef of YesEta -> True; NoEta _ -> False
        matching :: String
        matching = case recEtaEquality theDef of
          YesEta -> "both"; NoEta PatternMatching -> "pattern"; NoEta CopatternMatching -> "copattern"
        induction :: String
        induction = case recInduction of Just CoInductive -> "coinductive"; Just Inductive -> "inductive"; _ -> "unspecified"
        info = A.object ["fields" .= map keyOf fs,"namedConstructor" .= recNamedCon,
          "eta" .= eta,"matching" .= matching,"induction" .= induction]
        limits = ["module-copy" | isJust recClause] ++ ["coinductive" | induction == "coinductive"] ++
          ["constructor-patterns-unavailable" | matching `notElem` ["both","pattern"]]
    save (Decl key "record" recPars 0 (map keyOf cs) (recursion recMutual)
          (Just info) (map keyOf fs) limits) cs fs
  _ -> pure ()
  where
    key = nodeKeyOfQ defName
    save decl cs fs = do
      RepState existing _ _ _ <- liftIO $ readIORef repRef
      when (M.notMember key existing) $ if M.size existing >= 512
        then liftIO $ modifyIORef' repRef $ \(RepState ds vs selected omitted) ->
          RepState ds vs selected (M.insert key "declaration-limit" omitted)
        else do
          let boundary = ["abstract-or-opaque" | show (TC.defAbstract d) == "AbstractDef" || show (TC.defOpaque d) /= "TransparentDef"]
              unsupported = boundary ++ declLimits decl ++
                ["indexed" | declIndices decl /= 0] ++
                ["multiple-or-zero-constructors" | length cs /= 1] ++
                ["recursion-" ++ declRecursion decl | declRecursion decl /= "nonrecursive"]
              saved = decl {declLimits = boundary ++ declLimits decl}
          -- Retained metadata must not keep the signature resolver alive.
          _ <- liftIO $ evaluate (force saved)
          liftIO $ modifyIORef' repRef $ \(RepState ds vs selected omitted) ->
            RepState (M.insert key saved ds) vs selected omitted
          forM_ (cs ++ fs) $ \q -> catchError (getConstInfo q >>= ensure) (\_ -> pure ())
          forM_ cs $ \q -> do
            let name = keyOf q
            raw <- if not (null unsupported) then pure $ View name key [] Nothing "unavailable" unsupported else do
              attempt <- boundedQueryTCM 200000 $ inTopContext $ inConcreteMode $ notUnderOpaque $ do
                constructor <- getConstInfo q
                case TC.theDef constructor of
                  Constructor{} | keyOf (conData $ TC.theDef constructor) == key -> do
                    TelV tel result <- telView (TC.defType constructor)
                    telescope <- removeCopies tel
                    codomain <- removeCopies result
                    let Tree _ _ _ _ forest = limitedTree 10000 (Tree "view" "" [] False (contextTreesWith keyOf telescope ++ [typeTreeWith keyOf codomain]))
                        unsupportedTree (Tree tag _ _ _ children) = tag == "unsupported" || any unsupportedTree children
                    pure $ if length (take 258 forest) > 257 then View name key [] Nothing "unavailable" ["binder-limit"]
                      else if any unsupportedTree forest then View name key [] Nothing "partial" ["unsupported-telescope"]
                      else case reverse forest of
                        resultTree : reversedContext ->
                          let resultOwner (Tree "type" _ _ _ (first:_)) = resultOwner first
                              resultOwner (Tree "app" _ _ _ (first:_)) = resultOwner first
                              resultOwner (Tree "def" n _ _ _) = Just n
                              resultOwner _ = Nothing
                              complete = resultOwner resultTree == Just key
                          in View name key (reverse reversedContext) (Just resultTree)
                            (if complete then "complete" else "partial") ["blocked-constructor-result" | not complete]
                        [] -> View name key [] Nothing "unavailable" ["telescope-unavailable"]
                  _ -> pure $ View name key [] Nothing "unavailable" ["constructor-owner-unavailable"]
              pure $ case attempt of Just view -> view; Nothing -> View name key [] Nothing "unavailable" ["telescope-query-failed-or-timeout"]
            liftIO $ modifyIORef' pendingRef (M.insert name raw)

-- Tree results are short lived: TermExport drains them immediately through
-- representationReferences and interns them in its existing pool.
{-# NOINLINE pendingRef #-}
pendingRef :: IORef (M.Map String (View Tree))
pendingRef = unsafePerformIO (newIORef M.empty)

representationReferences :: String -> Intern -> IO ([String], Intern)
representationReferences owner pool = do
  pending <- atomicModifyIORef' pendingRef (\xs -> (M.empty, xs))
  let (packed, nextPool) = ST.runState (mapM pack pending) pool
  _ <- evaluate (force packed)
  modifyIORef' repRef $ \(RepState ds vs selected omitted) ->
    RepState ds (M.union vs packed) selected omitted
  RepState ds _ _ _ <- readIORef repRef
  pure (maybe [] (\d -> declConstructors d ++ declFields d) (M.lookup owner ds), nextPool)
  where pack (View n d ctx result status limits) = View n d <$> mapM intern ctx <*> mapM intern result <*> pure status <*> pure limits

encodeRepresentations :: M.Map String (Maybe Int) -> IO A.Value
encodeRepresentations available = do
  RepState ds views selected omitted <- readIORef repRef
  let keys = M.keysSet available
      kept = M.filterWithKey (\name _ -> S.member name keys) ds
      missing d = filter (`S.notMember` keys) (declConstructors d ++ declFields d) ++
        [name | name <- declConstructors d,M.lookup name available /= Just (Just (declParameters d))]
      declaration d = A.object ["name" .= declName d,"kind" .= declKind d,
        "parameterCount" .= declParameters d,"indexCount" .= declIndices d,
        "constructors" .= declConstructors d,"recursion" .= declRecursion d,"record" .= declRecord d,
        "inventoryComplete" .= null (missing d),"limitations" .= (declLimits d ++ ["missing-member-signatures" | not $ null $ missing d])]
      view (View name owner ctx result status limits) =
        let incomplete = maybe True (not . null . missing) (M.lookup owner kept)
        in A.object ["name" .= name,"owner" .= owner,"telescope" .= ctx,"resultType" .= result,
          "status" .= (if incomplete && status == "complete" then "partial" else status),
          "limitations" .= (limits ++ ["owner-inventory-incomplete" | incomplete && status == "complete"])]
      absent = M.union omitted (M.fromSet (const "declaration-not-retained") (selected S.\\ M.keysSet kept))
  pure $ A.object ["v" .= (1::Int),"declarations" .= map declaration (M.elems kept),
    "constructorViews" .= [view v | (name,v@(View _ owner _ _ _ _)) <- M.toAscList views,
      S.member name keys, M.member owner kept],
    "coverage" .= A.object ["selectedDeclarations" .= S.size selected,
      "omittedDeclarations" .= [A.object ["name" .= n,"reason" .= r] | (n,r) <- M.toAscList absent],
      "declarationLimit" .= (512::Int),"viewNodeLimit" .= (10000::Int),"viewBinderLimit" .= (256::Int),"viewQueryMicros" .= (200000::Int)]]
