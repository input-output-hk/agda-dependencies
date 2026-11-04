{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
-- Optional structural type evidence in the expanded-v2 graph contract.
-- No normalization/conversion checker; unsupported forms stay explicit.
module AgdaDeps.TypeExport
  ( initializeTypeExport, captureTypeDefinition, readTypeTerms ) where

import Control.Monad (forM, when)
import Control.DeepSeq (NFData,force)
import Control.Exception (evaluate)
import GHC.Generics (Generic)
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

import Agda.Syntax.Internal (Term(..), Type''(..), Clause(..))
import Agda.TypeChecking.Monad (TCM, Definition(..), pattern Function, funClauses)
import Agda.TypeChecking.Telescope (telView)
import Agda.TypeChecking.Substitute (TelV(..))
import AgdaDeps.Util (definitionSectionParameters)
import AgdaDeps.TermCodec
import AgdaDeps.NodeKey (nodeKeyResolver, nodeKeyForDefinition, moduleKeyOfQ, bindingLineOfQ)

data Captured a = Captured String String (Maybe Int) (Maybe FilePath) Int a
  [(a, [a])] deriving (Show,Generic)
instance NFData a => NFData (Captured a)
data ExportState = ExportState Bool (M.Map String (Captured Int)) Intern

{-# NOINLINE exportRef #-}
exportRef :: IORef ExportState
exportRef = unsafePerformIO (newIORef (ExportState False M.empty (M.empty,M.empty)))

initializeTypeExport :: Bool -> IO ()
initializeTypeExport enabled = writeIORef exportRef (ExportState enabled M.empty (M.empty,M.empty))

captureTypeDefinition :: Maybe FilePath -> Definition -> TCM ()
captureTypeDefinition file definition@Defn{..} = do
  ExportState enabled _ _ <- liftIO (readIORef exportRef)
  let owner = moduleKeyOfQ defName
  when enabled $ do
    keyOf <- nodeKeyResolver
    let typeTree = typeTreeWith keyOf
        termTree = termTreeWith keyOf
    -- Only body-bearing functions need the reducing telescope view. A
    -- postulate's structural signature may contain a nonterminating alias.
    clauses <- case theDef of
      Function{..} | any (isJust . clauseBody) funClauses -> do
        TelV _ result <- telView defType
        pure $ case unEl result of Sort{} -> funClauses; _ -> []
      _ -> pure []
    -- Module-copy wrappers are removed from the exported terms below.
    signature <- removeCopies defType
    sectionParameters <- definitionSectionParameters definition
    bodies <- fmap concat $ forM clauses $ \cl -> case clauseBody cl of
      Nothing -> pure []
      Just rawBody -> do
        body <- removeCopies rawBody
        telescope <- removeCopies (clauseTel cl)
        pure [(termTree body, contextTreesWith keyOf telescope)]
    let key = nodeKeyForDefinition definition
        entry = Captured key owner (bindingLineOfQ defName) file sectionParameters (typeTree signature) bodies
    -- Intern at the capture boundary rather than retaining trees whose name
    -- resolver closes over Agda's current/imported signatures. Output below
    -- canonically reindexes the selected DAG, independent of hook order.
    liftIO $ do
      ExportState p defs pool <- readIORef exportRef
      let (packed,nextPool)=ST.runState (mapCapturedM intern entry) pool
      _<-evaluate $ force packed
      _<-evaluate $ M.size $ snd nextPool
      writeIORef exportRef (ExportState p (M.insert key packed defs) nextPool)

mapCapturedM :: Monad m => (a -> m b) -> Captured a -> m (Captured b)
mapCapturedM f (Captured name owner line file sectionParameters signature bodies) =
  Captured name owner line file sectionParameters <$> f signature <*>
    mapM (\(body,ctx)->(,) <$> f body <*> mapM f ctx) bodies

encodeCaptured :: Captured Int -> A.Value
encodeCaptured (Captured name owner line file sectionParameters sig bodies) =
  A.object ["name" .= name, "module" .= owner, "line" .= line,
    "file" .= file, "sectionParameters" .= sectionParameters,
    "signature" .= sig, "bodies" .= [A.object ["root" .= root,"context" .= ctx] | (root,ctx)<-bodies]]

-- Only retain definitions in the final graph; no hidden second scope or file.
readTypeTerms :: [String] -> IO (Maybe String)
readTypeTerms retained = do
  ExportState enabled defs (_,pool) <- readIORef exportRef
  if not enabled then pure Nothing else do
    let selected = M.elems (M.restrictKeys defs (M.keysSet $ M.fromList [(n,()) | n <- retained]))
        reindex :: Int -> ST.State (M.Map Int Int,Intern) Int
        reindex root = do
          (memo,_)<-ST.get
          case M.lookup root memo of
            Just index->pure index
            Nothing->do
              let (tag,name,info,binds,children)=pool M.! root
              ids<-mapM reindex children
              (known,interned)<-ST.get
              let (index,next)=ST.runState (internNode (tag,name,info,binds,ids)) interned
              ST.put (M.insert root index known,next)
              pure index
        (rebased, (_,(_,nodes))) = ST.runState (mapM (mapCapturedM reindex) selected) (M.empty,(M.empty,M.empty))
        entries=map encodeCaptured rebased
    -- Release the capture tables while the selected DAG is serialized.
    initializeTypeExport False
    pure $ Just $ T.unpack $ TE.decodeUtf8 $ BL.toStrict $ A.encode $ A.object
      ["v" .= (1 :: Int), "nodes" .= map internNodeValue (M.elems nodes), "definitions" .= entries]
