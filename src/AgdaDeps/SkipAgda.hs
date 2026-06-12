{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Render the dependency graph from the source-file scan alone, the
-- @--skip-agda@ code path. 'AgdaDeps.Precompute' has already
-- line-parsed every @.agda@ source under the @-i@ paths for its
-- @module …@ \/ @import …@ statements; this module wires that data
-- into the v2 graph.json schema and emits DOT \/ HTML \/ JSON.
--
-- Output covers module-level edges and names only — no
-- definition-level data, no state classification, no snippets.
-- \"External\" classification is best-effort: a module is external if
-- its scanned source file lives outside the working directory, or if
-- it appears only as an import target with no source file. Module-DAG
-- views render normally; definition-level views render an empty canvas.
--
-- Key functions: 'wantsSkipAgda', 'runSkipAgda'.
module AgdaDeps.SkipAgda
  ( wantsSkipAgda
  , runSkipAgda
  ) where

import Control.Monad ( foldM )
import Data.List ( find, isPrefixOf )
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.IO as TL

import System.Directory ( createDirectoryIfMissing, getCurrentDirectory )
import System.Exit ( exitFailure )
import System.FilePath ( (</>), normalise )
import System.IO ( hPutStrLn, stderr )

import qualified Codec.Compression.GZip as GZip
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC

import Agda.Compiler.Backend ( commandLineFlags )
import Agda.Interaction.Options ( runOptM )
import Agda.Utils.GetOpt ( ArgOrder(Permute), getOpt' )

import AgdaDeps.Backend ( backend )
import AgdaDeps.Logging ( info )
import AgdaDeps.Backend.GraphJson
  ( GraphInput(..), GraphJsonOutput(..)
  , buildGraphJson, buildExpandedJson )
import AgdaDeps.Backend.Html ( renderHtmlFromInput )
import AgdaDeps.Options
  ( Options(..), OutputFormat(..), JsonMode(..)
  , isExcludedModule )
import AgdaDeps.Precompute ( PrecomputedGraph(..) )
import AgdaDeps.Util       ( jsString, looksLikeAgdaSource )

-- | True when argv contains the @--skip-agda@ flag.
wantsSkipAgda :: [String] -> Bool
wantsSkipAgda = elem "--skip-agda"

-- | Entry point. Parses backend options out of argv (Agda-side flags
-- are tolerated and ignored), identifies the entry source file from
-- the positional arguments, and writes the output files. Mirrors the
-- @--format@ dispatch in 'AgdaDeps.Backend.postCompileAD'.
--
-- @seed@ is the YAML-config-seeded 'Options' assembled in 'Main'; CLI
-- flags in @argv@ layer on top of it, preserving the
-- defaults → config → CLI merge order.
runSkipAgda :: Options -> PrecomputedGraph -> [String] -> IO ()
runSkipAgda seed precomputed argv = do
  (opts, positionals) <- case parseBackendOnlyOptions seed argv of
    Left err -> do
      hPutStrLn stderr $ "agda-deps: --skip-agda: " ++ err
      exitFailure
    Right v -> return v

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

  cwd <- getCurrentDirectory
  let root          = normalise cwd
      isUnderRoot p = root `isPrefixOf` normalise p

      -- External classification, best-effort without Agda:
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

-- | Format-dispatch + file write. HTML is rendered inline only; lazy
-- mode is rejected.
emit
  :: Options
  -> M.Map String FilePath
  -> Maybe String
  -> S.Set String
  -> [(String, String)]
  -> [FilePath]
  -> S.Set String          -- ^ all in-project modules (for 'giExtraModules')
  -> IO ()
emit opts moduleFileMap entryModule externals imports sourceFiles allModules = do
  -- Create the output dir if needed.
  case optOutDir opts of
    Just dir -> createDirectoryIfMissing True dir
    Nothing  -> return ()
  let gi = GraphInput
        { giDefs            = []
        , giStateMap        = M.empty
        , giImportEdges     = imports
        , giSourceFiles     = sourceFiles
        , giModuleFile      = moduleFileMap
        , giEntryModule     = entryModule
        , giExternalModules = externals
        , giFailedModules   = S.empty
        , giPositions       = M.empty
        , giWithSource      = False
        , giSnippetModules  = []
        , giLazy            = False
        , giExtraModules    = allModules
        , giReExports       = []
        , giExternalsSummary = Nothing
        }
      gjo = buildGraphJson gi

  case optFormat opts of
    FmtDot ->
      let dotText = renderModuleDot allModules externals imports entryModule
      in case optOutDir opts of
           Just dir -> TL.writeFile (dir </> "deps.dot") dotText
           Nothing  -> TL.putStrLn dotText

    FmtJson ->
      let jsonText = case optJsonMode opts of
            JsonPacked   -> gjoGraphJson gjo
            JsonExpanded -> buildExpandedJson gi
      in case optOutDir opts of
           Just dir -> writeFile (dir </> "deps.json") jsonText
           Nothing  -> putStrLn   jsonText

    FmtHtml -> case optOutDir opts of
      Nothing -> do
        hPutStrLn stderr "agda-deps: --skip-agda --format=html requires -o/--out-dir."
        exitFailure
      Just dir -> do
        createDirectoryIfMissing True dir
        -- Reuse the full pipeline's view templates. Def-level views
        -- render empty pods; module-DAG views render normally.
        let html = renderHtmlFromInput (optView opts) (optColors opts)
                                       (optGzip opts) (optAgdaHtmlDir opts) gi
        writeFile (dir </> "deps.html") html
        if optGzip opts
          then BL.writeFile (dir </> "deps.html.gz")
                 (GZip.compress (BLC.pack html))
          else return ()

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
      "  " ++ jsString m ++ " [label=" ++ jsString m ++ attrs m ++ "];\n"

    attrs m
      | Just m == entry        = ", color=\"#e94560\", penwidth=2"
      | S.member m externals   = ", color=\"#8090a8\", style=\"rounded,dashed\""
      | otherwise              = ", color=\"#3a6090\""

    edgeLine (s, t) =
      "  " ++ jsString s ++ " -> " ++ jsString t ++ ";\n"

-- | Parse backend-only options from argv, layered on top of @seed@
-- (the YAML-config-seeded 'Options'). Uses 'getOpt'' so Agda's own
-- flags (@-i@, @--include-path@, etc.) pass through as
-- \"unrecognised\" and are discarded. Folding the CLI actions over
-- @seed@ gives the defaults → config → CLI precedence.
parseBackendOnlyOptions :: Options -> [String] -> Either String (Options, [String])
parseBackendOnlyOptions seed argv =
  let descs                            = commandLineFlags backend
      (actions, positionals, _unrec, errs) = getOpt' Permute descs argv
  in if not (null errs)
       then Left (concat errs)
       else
         let (result, _warns) = runOptM (foldM (\o act -> act o) seed actions)
         in case result of
              Left  e -> Left e
              Right o -> Right (o, positionals)
