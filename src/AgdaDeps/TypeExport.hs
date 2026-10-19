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

import Agda.Syntax.Common (getArgInfo)
import Agda.Syntax.Internal (Term(..), Type''(..), Clause(..), domIsFinite, unDom, telToList)
import Agda.TypeChecking.Monad (TCM, Definition(..), pattern Function, funClauses)
import Agda.TypeChecking.Telescope (telView)
import Agda.TypeChecking.Substitute (TelV(..))
import AgdaDeps.Util (definitionSectionParameters)
import AgdaDeps.TermCodec
import AgdaDeps.NodeKey (nodeKeyOfQ, moduleKeyOfQ, bindingLineOfQ)

data Captured = Captured String String (Maybe Int) (Maybe FilePath) Int Tree
  [(Tree, [Tree])] deriving Show
data ExportState = ExportState Bool (M.Map String Captured)

{-# NOINLINE exportRef #-}
exportRef :: IORef ExportState
exportRef = unsafePerformIO (newIORef (ExportState False M.empty))

initializeTypeExport :: Bool -> IO ()
initializeTypeExport enabled = writeIORef exportRef (ExportState enabled M.empty)

captureTypeDefinition :: Maybe FilePath -> Definition -> TCM ()
captureTypeDefinition file definition@Defn{..} = do
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
    sectionParameters <- definitionSectionParameters definition
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
      ["v" .= (1 :: Int), "nodes" .= map internNodeValue (M.elems nodes), "definitions" .= entries]
