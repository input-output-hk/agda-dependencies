{-# LANGUAGE ScopedTypeVariables #-}
-- | Render the dependency graph from the source-file scan alone, the
-- @--skip-agda@ code path. 'AgdaDeps.Precompute' has already
-- line-parsed every @.agda@ source under the @-i@ paths for its
-- @module …@ \/ @import …@ statements; this module wires that data
-- into the v2 graph.json schema and emits DOT \/ JSON.
--
-- Output covers module-level edges and names only — no
-- definition-level data and no state classification.
-- \"External\" classification is best-effort: a module is external if
-- its scanned source file lives outside the working directory, or if
-- it appears only as an import target with no source file. A graph from
-- here drives @agda-plotter@'s module-level views normally; its
-- definition-level views render an empty canvas.
--
-- Key function: 'runSkipAgda'.
module AgdaDeps.SkipAgda
  ( runSkipAgda
  ) where

import Data.List ( find )
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text.Lazy as TL

import System.Exit ( exitFailure )
import System.IO ( hPutStrLn, stderr )

import AgdaDeps.Backend
  ( checkOutputFlags, noSerialiseCtx, parseBackendFlags, writeOutputs )
import AgdaDeps.Logging ( info )
import AgdaDeps.Backend.GraphJson ( GraphInput(..), emptyGraphInput )
import AgdaDeps.Options
  ( Options(..), lazyTreeOutput, isExcludedModule )
import AgdaDeps.Precompute ( PrecomputedGraph(..) )
import AgdaDeps.Util       ( looksLikeAgdaSource, underCwd )

-- | Entry point. Parses backend options out of argv (Agda-side flags
-- are tolerated and ignored), identifies the entry source file from
-- the positional arguments, and writes the output files through
-- 'AgdaDeps.Backend.writeOutputs', the full pipeline's writer.
--
-- @seed@ is the YAML-config-seeded 'Options' assembled in 'Main'; CLI
-- flags in @argv@ layer on top of it, preserving the
-- defaults → config → CLI merge order.
runSkipAgda :: Options -> PrecomputedGraph -> [String] -> IO ()
runSkipAgda seed precomputed argv = do
  (opts, positionals) <- case parseBackendFlags seed argv of
    Left err -> do
      hPutStrLn stderr $ "agda-deps: --skip-agda: " ++ err
      exitFailure
    Right v -> return v

  -- Options resolved, no work done. This path never reaches
  -- 'preCompileAD', so it runs the shared check itself; a local copy
  -- would be free to accept a combination the Agda path rejects.
  checkOutputFlags opts

  let entrySource  = find looksLikeAgdaSource positionals
      excludes     = optExcludeModules opts
      keep m       = not (isExcludedModule excludes m)

      mods         = filter keep (precomputedModules precomputed)
      modSet       = S.fromList mods
      imports      = [ (s, t) | (s, t) <- precomputedImports precomputed
                              , keep s, keep t ]

      modFilePairs = [ (m, p) | (m, p) <- precomputedModuleFiles precomputed, keep m ]
      moduleFileMap :: M.Map String FilePath
      moduleFileMap = M.fromList modFilePairs

      fileToModule :: M.Map FilePath String
      fileToModule = M.fromList [ (p, m) | (m, p) <- modFilePairs ]

      entryModule = entrySource >>= (`M.lookup` fileToModule)

  isUnderRoot <- underCwd
  let -- External classification, best-effort without Agda:
      --   (1) modules whose binding-site file lives outside cwd, and
      --   (2) modules that appear only as import targets, with no
      --       source file under the '-i' paths.
      externalsFromFiles = S.fromList
        [ m | (m, p) <- modFilePairs, not (isUnderRoot p) ]

      importOnlyMods = S.fromList
        [ m | (s, t) <- imports, m <- [s, t], not (S.member m modSet) ]

      externals0 = S.union externalsFromFiles importOnlyMods

      -- '--no-externals': drop external modules from the rendered
      -- graph entirely.
      isExt m = S.member m externals0
      (mods', imports', externals)
        | optNoExternals opts =
            ( filter (not . isExt) mods
            , [ (s, t) | (s, t) <- imports
                       , not (isExt s), not (isExt t) ]
            , S.empty
            )
        | otherwise = (mods, imports, externals0)

  info $
    "agda-deps: --skip-agda: " ++ show (length mods')
    ++ " module(s), " ++ show (length imports') ++ " import edge(s); "
    ++ show (S.size externals) ++ " external."

  emit opts moduleFileMap entryModule externals imports'
       (precomputedSourceFiles precomputed)
       (S.fromList mods')

-- | Build the module-only graph and write it through the full pipeline's
-- writer, with the cache disabled: nothing is type-checked here, so there
-- is nothing to cache against and every file is written. Sharing it keeps
-- the output plan, the gz convention and the modules/ layout single-owner.
emit
  :: Options
  -> M.Map String FilePath
  -> Maybe String
  -> S.Set String
  -> [(String, String)]
  -> [FilePath]
  -> S.Set String          -- ^ all in-project modules (for 'giExtraModules')
  -> IO ()
emit opts moduleFileMap entryModule externals imports sourceFiles allModules =
  writeOutputs opts noSerialiseCtx
    (renderModuleDot allModules externals imports entryModule)
    -- No defs, states, positions or metas without Agda. The module-level
    -- option rollups stay empty too: the source scanner doesn't extract
    -- file-level @{-# OPTIONS #-}@ tokens ('Precompute.stripBlockComments'
    -- strips them as block comments), and the effective option set is
    -- Agda's answer, not the scanner's.
    emptyGraphInput
      { giImportEdges     = imports
      , giSourceFiles     = sourceFiles
      , giModuleFile      = moduleFileMap
      , giEntryModule     = entryModule
      , giExternalModules = externals
      , giLazy            = lazyTreeOutput opts
      , giExtraModules    = allModules
      }

-- | DOT renderer for the module-only graph: one node per module, one
-- edge per import. The entry module gets a red border, externals
-- dashed grey.
renderModuleDot
  :: S.Set String         -- in-project modules
  -> S.Set String         -- externals
  -> [(String, String)]   -- import edges
  -> Maybe String         -- entry
  -> TL.Text
renderModuleDot mods externals edges entry =
  TL.pack . concat $
       [ "digraph G {\n"
       , "  rankdir=TB;\n"
       , "  node [shape=box, style=\"rounded\", fontname=\"sans-serif\"];\n"
       ]
    ++ map nodeLine (S.toAscList (S.union mods externals))
    ++ map edgeLine edges
    ++ [ "}\n" ]
  where
    nodeLine m =
      "  " ++ dotQuote m ++ " [label=" ++ dotQuote m ++ attrs m ++ "];\n"

    attrs m
      | Just m == entry        = ", color=\"#e94560\", penwidth=2"
      | S.member m externals   = ", color=\"#8090a8\", style=\"rounded,dashed\""
      | otherwise              = ", color=\"#3a6090\""

    edgeLine (s, t) =
      "  " ++ dotQuote s ++ " -> " ++ dotQuote t ++ ";\n"

-- | Quote a string as a DOT ID. Only @\"@ and @\\@ are special inside a
-- quoted DOT string; every other character, non-ASCII included, goes
-- through as is (JSON's @\\u@ escapes would render literally).
dotQuote :: String -> String
dotQuote s = '"' : concatMap esc s ++ "\""
  where
    esc '"'  = "\\\""
    esc '\\' = "\\\\"
    esc c    = [c]
