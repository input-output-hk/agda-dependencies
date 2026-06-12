{-# LANGUAGE RecordWildCards #-}
-- | Generic JSON graph artifact emitted with @--format=json@.
--
-- Shares the v2 graph.json schema with the HTML output via
-- 'AgdaDeps.Backend.GraphJson', so downstream tooling sees the same
-- shape as the in-browser viewer.
module AgdaDeps.Backend.Json
  ( renderJson
  ) where

import Data.Map ( Map )
import qualified Data.Map as M
import Data.Set ( Set )
import qualified Data.Set as S

import Agda.Syntax.Abstract.Name ( QName )

import AgdaDeps.Deps    ( ADDef(..) )
import AgdaDeps.Layout  ( Position )
import AgdaDeps.Options ( DefState, JsonMode(..) )

import AgdaDeps.Backend.GraphJson
  ( GraphInput(..), GraphJsonOutput(..), ExternalsSummary
  , buildGraphJson, buildExpandedJson )

renderJson
  :: JsonMode                -- ^ packed (default) or expanded
  -> Map QName DefState
  -> Set String              -- ^ external module names
  -> Set String              -- ^ failed module names (--keep-going)
  -> Maybe String            -- ^ entry-point module name
  -> [(String, String)]      -- ^ all direct module-level import edges
  -> [FilePath]              -- ^ source files (from precompute)
  -> Map String FilePath     -- ^ module name -> binding-site source file
  -> Map QName Position      -- ^ pre-computed (x, y) per definition
  -> [(String, String, [String])]
                             -- ^ (host, source, qualified-names) re-exports
  -> Maybe ExternalsSummary  -- ^ diagnostic summary under --no-externals
  -> [ADDef]
  -> String
renderJson mode stateMap externals failed entryModule importEdges sourceFiles moduleFile positions reexports externalsSummary defs =
  let gi = GraphInput
        { giDefs            = defs
        , giStateMap        = stateMap
        , giImportEdges     = importEdges
        , giSourceFiles     = sourceFiles
        , giModuleFile      = moduleFile
        , giEntryModule     = entryModule
        , giExternalModules = externals
        , giFailedModules   = failed
        , giPositions       = positions
        , giWithSource      = False
        , giSnippetModules  = []
        , giLazy            = False
        , giExtraModules    = S.empty
        , giReExports       = reexports
        , giExternalsSummary = externalsSummary
        }
  in case mode of
       JsonPacked   -> gjoGraphJson (buildGraphJson gi)
       JsonExpanded -> buildExpandedJson gi
