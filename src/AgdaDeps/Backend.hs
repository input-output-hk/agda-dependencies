{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
-- | The Agda 'Backend'' record + hooks, plus the post-compile
-- dispatcher that routes the collected 'ADDef's to the per-format
-- renderer.
module AgdaDeps.Backend
  ( -- * Backend wiring
    backend
  , backendWithSeed
  , mainModuleRef
  , failedModulesRef
  , precomputedGraphRef
  , postCompileAD
  , compileDefAD

    -- * Per-module state passed between hooks
  , ModuleEnv(..)
  , ModuleRes
  ) where

import Control.Monad ( when )
import Control.Monad.IO.Class ( MonadIO(liftIO) )

import Data.IORef ( IORef, newIORef, readIORef, writeIORef )
import Data.Map ( Map )
import qualified Data.Map as M
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.Maybe ( catMaybes, fromMaybe )
import Data.Set ( Set )
import qualified Data.Set as S

import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.IO as TL

import Data.Version ( showVersion )
import Paths_agda_deps ( version )

import Data.List ( foldl', isPrefixOf )

import qualified System.Directory
import System.Directory ( createDirectoryIfMissing, getCurrentDirectory )
import System.Exit ( exitFailure )
import System.FilePath ( (</>), normalise )
import System.IO ( hPutStrLn, stderr )

import Agda.Utils.GetOpt ( OptDescr(Option), ArgDescr(ReqArg, NoArg) )

import Agda.Syntax.Abstract.Name ( QName )
import qualified Agda.Syntax.Abstract.Name as A
import Agda.Syntax.Internal ( qnameModule )
import Agda.Syntax.Common.Pretty ( prettyShow )
import Agda.Syntax.Scope.Base
  ( allThingsInScope, NameSpace(nsInScope, nsNames)
  , NameSpaceId(ImportedNS, PublicNS), scopeNameSpace
#if !MIN_VERSION_Agda(2,9,0)
  -- 2.8 keeps 'anameName' here; 2.9 re-exports it via Agda.Syntax.Abstract.Name.
  , anameName
#endif
  )
import Agda.Syntax.Scope.Monad ( getCurrentScope )
import Agda.Syntax.TopLevelModuleName ( TopLevelModuleName )

import qualified Data.List.NonEmpty as List1

import Agda.TypeChecking.Monad ( TCM, liftTCM )
import Agda.TypeChecking.Monad.Base
  ( iImportedModules, miInterface, Interface
  , iScope, iModuleName, iTopLevelModuleName
  , iSignature, sigDefinitions, iFullHash
  )
import Agda.TypeChecking.Monad.Imports ( getVisitedModules )
import Agda.TypeChecking.Monad.State ( getSignature )
import Agda.Compiler.Common ( curIF )
import Agda.Utils.Lens ( (^.) )
import qualified Data.HashMap.Strict as HMap

import Agda.Compiler.Backend
  ( Backend'(..), Backend'_boot(..), Recompile(..) )
import Agda.Syntax.Common ( IsMain(..) )

import System.IO.Unsafe ( unsafePerformIO )

import AgdaDeps.Deps
  ( ADDef(..), DefAccess(..)
  , compileDefAD, collectAllQNames, nodeKey, hashQName
  , resetIgnoredEdges, contractIgnoredEdges
  , resetMethodProviders, addInstanceMethodEdges
  , IgnoredEdgeMap, readIgnoredEdges, mergeIgnoredEdges
  , MethodProviderMap, readMethodProviders, mergeMethodProviders )
import AgdaDeps.FragmentCache
  ( FragmentData(..), fragmentCacheSupported
  , optionsFingerprint, fragmentFileFor, readFragment, writeFragment
  , gcFragments )
import AgdaDeps.SerialiseCache
  ( Manifest, readManifest, writeManifest, manifestLookup, manifestFromList
  , Epoch, combineEpochs, hashEpoch )
import AgdaDeps.Deps ( nodeKeyVersion )
import BuildInfo ( buildFingerprint )
import AgdaDeps.Layout ( Position, computePositions )
import AgdaDeps.Options
  ( Options(..), OutputFormat(..), View(..), DefState
  , ColorPalette(..), defaultOptions
  , outdirOpt, formatOpt, viewOpt
  , colorOpt, withSourceOpt, agdaHtmlDirOpt, lazyOpt, excludeOpt
  , noSourceForOpt, maxSnippetBytesOpt, gzipOpt, keepGoingOpt, skipAgdaOpt
  , incrementalOpt, cacheDirOpt, packedAnalyticalOpt
  , quietOpt, noExternalsOpt, jsonModeOpt, lenientImportsOpt
  , resolveDepsOpt
  , withTermHashesOpt, minTermDepthOpt, withSignaturesOpt
  , normaliseSignaturesOpt, showImplicitOpt
  , isExcludedModule
  )
import AgdaDeps.Config ( parseTheme, applyTheme )
import Control.Monad.Except ( MonadError(throwError) )
import AgdaDeps.Logging ( info )
import AgdaDeps.Precompute ( PrecomputedGraph(..), emptyGraph )

import qualified Codec.Compression.GZip as GZip
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import AgdaDeps.Source ( Snippet, collectHighlightedSnippets, srcLocOf )
import AgdaDeps.Backend.Dot  ( renderDot )
import AgdaDeps.Backend.GraphJson ( ExternalsSummary, buildExternalsSummary )
import AgdaDeps.Backend.Html ( renderHtml, renderLazyHtml, LazyOutput(..) )
import AgdaDeps.Backend.Json ( renderJson )

-- | Per-module state captured during 'moduleSetup', threaded to
-- 'postModuleAD': the in-scope names, plus pre-module snapshots of the
-- two compile-time side-channels so the fragment cache can attribute
-- each module's contributions exactly (as a before/after delta —
-- name-based slicing fails for defs Agda homes in anonymous modules,
-- e.g. @_.IsMajority@ copies from a @module _ ⦃ asm ⦄@ block).
data ModuleEnv = ModuleEnv
  { namesInScope       :: Set QName
  , envIgnoredBefore   :: IgnoredEdgeMap
  , envProvidersBefore :: MethodProviderMap
  }

-- | @--theme=NAME@ parser. Sets the four 'optColor*' slots; individual
-- @--color-*@ flags appearing later in argv override their slot.
themeOpt :: MonadError String m => String -> Options -> m Options
themeOpt s opts = case parseTheme s of
  Right th -> return (applyTheme th opts)
  Left err -> throwError err

-- | @--config=PATH@ parser. A no-op: the config-file load happens in
-- 'Main' (seeding 'Options' before argv parsing), and the flag is
-- already stripped from argv by the time GetOpt sees it.
configOpt :: Monad m => String -> Options -> m Options
configOpt _ opts = return opts

-- | The list of 'ADDef's a single module produces.
type ModuleRes = [Maybe ADDef]

-- | The exported backend, seeded with 'defaultOptions'.
backend :: Backend' Options Options ModuleEnv ModuleRes (Maybe ADDef)
backend = backendWithSeed defaultOptions

-- | Like 'backend' but lets the caller pre-populate the 'options' field
-- (used by 'Main' to overlay a discovered @.agda-deps.yml@ before CLI
-- parsing).
backendWithSeed
  :: Options -> Backend' Options Options ModuleEnv ModuleRes (Maybe ADDef)
backendWithSeed seed = Backend'
  { backendName           = "agda-deps"
  , backendVersion        = Just . T.pack . showVersion $ version
  , options               = seed
  , commandLineFlags      =
      [ Option ['o'] ["out-dir"] (ReqArg outdirOpt "DIR")
        "Write output files to DIR. (default: project root)"
      , Option []    ["format"]  (ReqArg formatOpt "FORMAT")
        "Output format: dot (default), html, or json."
      , Option []    ["view"]    (ReqArg viewOpt "VIEW")
        "HTML view variant: module-dag-pods (default), cytoscape,\nide-three-pane, source-centric, notion-doc, wiki-backlinks,\nsigma, big-module-dag-pods."
      , Option []    ["theme"]   (ReqArg themeOpt "THEME")
        "Colour preset: default (=light), dark, or colorblind.\nIndividual --color-* flags override the corresponding slot."
      , Option []    ["config"]  (ReqArg configOpt "PATH")
        "Load a YAML config file (kebab-case keys mirror CLI flag\nnames). CLI flags override config values. The flag is also\nresolved from $AGDA_DEPS_CONFIG or a .agda-deps.yml next to\nthe nearest .agda-lib."
      , Option []    ["color-defined"]
          (ReqArg (colorOpt "color-defined"   (\p s -> p{ colorDefined   = s })) "#RRGGBB")
        "Color for fully-defined definitions (default: #4caf50)."
      , Option []    ["color-postulate"]
          (ReqArg (colorOpt "color-postulate" (\p s -> p{ colorPostulate = s })) "#RRGGBB")
        "Color for postulates (default: #f44336)."
      , Option []    ["color-hole"]
          (ReqArg (colorOpt "color-hole"      (\p s -> p{ colorHole      = s })) "#RRGGBB")
        "Color for definitions containing unsolved holes (default: #9c27b0)."
      , Option []    ["with-source"] (NoArg withSourceOpt)
        "Embed each definition's source snippet (signature + body) into the\nHTML output, fetched on demand. Requires --lazy (the self-contained\ninline variant was removed); without it, has no effect. Clicking a leaf\nopens its definition in a side drawer. To link out to whole `agda --html`\npages instead, see --agda-html-dir."
      , Option []    ["agda-html-dir"] (ReqArg agdaHtmlDirOpt "DIR")
        "Path to the pages written by `agda --html`, RELATIVE to the\ngenerated HTML (e.g. --agda-html-dir=html). HTML views then show an\n\"Open source\" link that opens DIR/<Module.Name>.html. Off by default;\nwhen unset the output is unchanged. Best served over HTTP."
      , Option []    ["lazy"] (NoArg lazyOpt)
        "HTML output only: split into a small deps.html shell plus\ngraph.json and per-module modules/<Module>.json,\nsnippets/<Module>.json files, loaded lazily via fetch().\nRequires HTTP serving (e.g. python -m http.server)."
      , Option []    ["exclude"] (ReqArg excludeOpt "PREFIX")
        "Drop every module whose name is PREFIX or starts with PREFIX.\nCan be repeated."
      , Option []    ["no-source-for"] (ReqArg noSourceForOpt "PREFIX")
        "Skip source-snippet extraction for modules whose name is\nPREFIX or starts with PREFIX. Can be repeated."
      , Option []    ["max-snippet-bytes"] (ReqArg maxSnippetBytesOpt "N")
        "Soft per-module size cap on snippet bundles (default: 1000000).\n--max-snippet-bytes=0 disables the cap."
      , Option []    ["gzip"] (NoArg gzipOpt)
        "HTML/lazy output: also write a .gz sibling next to every JSON file."
      , Option []    ["color-failed"]
          (ReqArg (colorOpt "color-failed"    (\p s -> p{ colorFailed    = s })) "#RRGGBB")
        "Color for modules whose type-check failed under --keep-going\n(default: #ff9800)."
      , Option []    ["keep-going"] (NoArg keepGoingOpt)
        "Continue past Agda type-check errors. Modules whose type-check\nfailed are tagged 'failed' in the output graph."
      , Option []    ["skip-agda"] (NoArg skipAgdaOpt)
        "Don't invoke Agda at all. Render a module-level graph straight\nfrom the source-file scan (line-parses 'module' / 'import')."
      , Option []    ["incremental"] (NoArg incrementalOpt)
        "Cache each module's compiled dependency fragment under\n<out-dir>/.agda-deps-cache, keyed on the module's interface hash,\nand skip the per-definition walk on later runs when the module is\nunchanged. Requires Agda >= 2.9; disabled under --keep-going."
      , Option []    ["cache-dir"] (ReqArg cacheDirOpt "DIR")
        "Override the --incremental cache location (fragments +\nserialise manifest). Default: <out-dir>/.agda-deps-cache. No\neffect without --incremental."
      , Option []    ["packed-analytical"] (NoArg packedAnalyticalOpt)
        "Augment --json-mode=packed's 'defs' with per-definition\nanalytical arrays (kind/line/access, plus type under\n--with-signatures and subterm hashes under --with-term-hashes),\nso the compact form carries everything expanded does. Off by\ndefault; no effect on expanded output."
      , Option []    ["quiet"] (NoArg quietOpt)
        "Suppress 'I am working' progress lines on stderr; only genuine\nwarnings and errors are printed."
      , Option []    ["no-externals"] (NoArg noExternalsOpt)
        "Drop external modules (anything outside the project root) from\nthe rendered graph entirely — modules, definitions, and edges."
      , Option []    ["json-mode"] (ReqArg jsonModeOpt "MODE")
        "JSON shape: packed (default; base64-encoded typed arrays + CSR\nadjacency, compact for huge graphs) or expanded (arrays of\nrecords keyed by qname, no base64 — friendlier for downstream\ntooling)."
      , Option []    ["lenient-imports"] (NoArg lenientImportsOpt)
        "Tolerate imports of modules with open holes; forwarded to Agda\nas --allow-unsolved-metas. Useful with --keep-going when commits\ndeliberately leave '?' holes.\nINCOMPATIBLE WITH --safe DEPENDENCIES: --allow-unsolved-metas is a\nglobal Agda flag and any --safe module in the dep closure (e.g. the\nstandard library) will reject it with [SafeFlagPragma]. For projects\nbuilt on a --safe stdlib, prefer --keep-going alone."
      , Option []    ["resolve-deps"] (NoArg resolveDepsOpt)
        "Constrain Agda's search path to the project's .agda-lib 'depend:'\nclosure. Expands into '--no-libraries -i <dir>...' before Agda's\nCLI parser runs. Useful when two libraries with the same module\nname are registered (e.g. multiple stdlib versions) and Agda's\nresolver picks the wrong one, producing [AmbiguousTopLevelModuleName].\nFalls back silently to default behaviour if the project has no\n.agda-lib or resolution fails."
      , Option []    ["with-term-hashes"] (NoArg withTermHashesOpt)
        "Emit a canonical-form hash for every subterm walked\nin each definition. Off by default. Surfaces as\n'definitionSubtermHashes' in --json-mode=expanded; intended for\ndownstream AST-level CSE / lemma-extraction clustering."
      , Option []    ["min-term-depth"] (ReqArg minTermDepthOpt "N")
        "Only emit hashes for subterms with AST depth\n>= N (default 3). 1 disables the filter. Ignored without\n--with-term-hashes."
      , Option []    ["with-signatures"] (NoArg withSignaturesOpt)
        "Render each definition's type signature (reify of its type) and\nemit it as the per-def 'type' field in --json-mode=expanded. Shown\nas-written: not normalised, Agda's default printing (no\n--show-implicit). Off by default. For downstream type-aware\ntooling."
      , Option []    ["normalise-signatures"] (NoArg normaliseSignaturesOpt)
        "Normalise each type signature before rendering (semantic form\nrather than as-written). Off by default. No effect without\n--with-signatures."
      , Option []    ["signature-implicits"] (NoArg showImplicitOpt)
        "Render type signatures with implicit (and irrelevant) arguments\nshown. Off by default. No effect without --with-signatures.\n(Named to avoid clashing with Agda's own --show-implicit.)"
      ]
  , backendInteractTop    = Nothing
  , backendInteractHole   = Nothing
  , isEnabled             = \ _ -> True
  , preCompile            = preCompileAD
  , postCompile           = postCompileAD
  , preModule             = moduleSetup
  , postModule            = postModuleAD
  , compileDef            = compileDefAD
  , scopeCheckingSuffices = False
  , mayEraseType          = \ _ -> return True
  }

-- | Pre-compile hook. Clears the side-channels (edges through ignored
-- definitions; instance-method providers) so repeated runs in the same
-- process start fresh, and surfaces the @--incremental@ availability
-- caveats once per run.
preCompileAD :: Options -> TCM Options
preCompileAD opts = do
  resetIgnoredEdges
  resetMethodProviders
  liftIO $ writeIORef recompiledRef False
  when (optIncremental opts && not fragmentCacheSupported) $
    liftIO $ hPutStrLn stderr $
      "agda-deps: --incremental requires Agda >= 2.9 (this build cannot "
      ++ "serialise fragments); running without the cache."
  when (optIncremental opts && optKeepGoing opts) $
    info ("agda-deps: --incremental is disabled under --keep-going "
       ++ "(fragments are only cached from fully-checked runs).")
  return opts

-- | Whether the fragment cache is active this run.
useFragmentCache :: Options -> Bool
useFragmentCache opts =
  optIncremental opts && not (optKeepGoing opts) && fragmentCacheSupported

-- | Where fragments + the serialise manifest live. @--cache-dir@
-- overrides; otherwise under the output dir (or the working directory —
-- the project root after 'Main''s @.agda-lib@ discovery — when output
-- goes to stdout).
cacheDirFor :: Options -> FilePath
cacheDirFor opts = case optCacheDir opts of
  Just dir -> dir
  Nothing  -> fromMaybe "." (optOutDir opts) </> ".agda-deps-cache"

-- | Whether the @--incremental@ serialise cache is active. Independent
-- of 'fragmentCacheSupported' (the manifest is plain text + a
-- version-stable hash, so it works on 2.8 too) — but the monolithic
-- no-op skip additionally needs the fragment cache to detect \"nothing
-- recompiled\", so on 2.8 (no fragments) every module recompiles and
-- that skip never fires. Disabled under @--keep-going@.
useSerialiseCache :: Options -> Bool
useSerialiseCache opts = optIncremental opts && not (optKeepGoing opts)

-- | Output-context token for the monolithic no-op skip: a fingerprint
-- of everything other than per-definition /content/ that the output
-- depends on — the live module set, the output-affecting options, the
-- build identity, and the node-key convention. Combined with \"nothing
-- recompiled this run\" (per 'recompiledRef', which guards the def
-- content), an unchanged token means the on-disk output is byte-identical.
outputToken :: Options -> [String] -> Epoch
outputToken opts modules = combineEpochs
  [ hashEpoch buildFingerprint
  , fromIntegral nodeKeyVersion
  , hashEpoch (unwords optStrings)
  , hashEpoch (unwords modules)
  ]
  where
    -- One 'show' per output-affecting option (a single 16-tuple would
    -- exceed GHC's tuple 'Show' limit). Add any new output-affecting
    -- option here, or the no-op skip could serve stale output.
    optStrings =
      [ show (optFormat opts), show (optJsonMode opts), show (optView opts)
      , show (optColors opts), show (optGzip opts), show (optAgdaHtmlDir opts)
      , show (optNoExternals opts), show (optExcludeModules opts)
      , show (optWithSource opts), show (optNoSourceFor opts)
      , show (optMaxSnippetBytes opts), show (optWithSignatures opts)
      , show (optNormaliseSignatures opts), show (optShowImplicit opts)
      , show (optWithTermHashes opts), show (optMinTermDepth opts)
      , show (optPackedAnalytical opts)
      ]

moduleSetup
  :: Options -> IsMain -> TopLevelModuleName -> Maybe FilePath
  -> TCM (Recompile ModuleEnv ModuleRes)
moduleSetup opts isMain tlmn _ = do
  mCached <-
    if useFragmentCache opts
      then do
        iface <- curIF
        let path = fragmentFileFor (cacheDirFor opts) (prettyShow tlmn)
        readFragment path (optionsFingerprint opts) (iFullHash iface)
      else return Nothing
  case mCached of
    Just frag -> do
      -- The Skip path bypasses compileDef + postModule entirely:
      -- re-inject the module's side-channel slices (otherwise
      -- contraction loses every edge routed through this module's
      -- ignored helpers) and the entry-module capture postModuleAD
      -- would have done.
      mergeIgnoredEdges (fragIgnored frag)
      mergeMethodProviders (fragProviders frag)
      case isMain of
        IsMain -> do
          iface <- curIF
          let imports = map fst (iImportedModules iface)
          liftIO $ writeIORef mainModuleRef (Just (tlmn, imports))
        NotMain -> return ()
      info $ "agda-deps: --incremental: fragment hit for '"
             ++ prettyShow tlmn ++ "' ("
             ++ show (length (fragDefs frag)) ++ " defs)"
      return $ Skip (map Just (fragDefs frag))
    Nothing -> do
      liftIO $ writeIORef recompiledRef True
      allNamesInScope <- nsInScope . allThingsInScope <$> liftTCM getCurrentScope
      ignoredBefore   <- readIgnoredEdges
      providersBefore <- readMethodProviders
      return $ Recompile (ModuleEnv allNamesInScope ignoredBefore providersBefore)

{-# NOINLINE mainModuleRef #-}
mainModuleRef :: IORef (Maybe (TopLevelModuleName, [TopLevelModuleName]))
mainModuleRef = unsafePerformIO $ newIORef Nothing

{-# NOINLINE failedModulesRef #-}
failedModulesRef :: IORef (Set String)
failedModulesRef = unsafePerformIO $ newIORef S.empty

{-# NOINLINE precomputedGraphRef #-}
precomputedGraphRef :: IORef PrecomputedGraph
precomputedGraphRef = unsafePerformIO $ newIORef emptyGraph

-- | Set 'True' whenever a module is (re)compiled this run rather than
-- served from the fragment cache. 'postCompileAD' reads it: an
-- all-cache-hit run (this stays 'False') with an unchanged output
-- context means the on-disk monolithic output is already byte-identical
-- and the serialise can be skipped. Reset in 'preCompileAD'.
{-# NOINLINE recompiledRef #-}
recompiledRef :: IORef Bool
recompiledRef = unsafePerformIO $ newIORef False


postModuleAD
  :: Options -> ModuleEnv -> IsMain -> TopLevelModuleName -> [Maybe ADDef]
  -> TCM [Maybe ADDef]
postModuleAD opts env isMain tlmn defs = do
  iface <- curIF
  case isMain of
    IsMain -> do
      let imports = map fst (iImportedModules iface)
      liftIO $ writeIORef mainModuleRef (Just (tlmn, imports))
    NotMain -> return ()

  -- Private-namespace QNames are not captured from the scope here;
  -- access is classified at 'postCompileAD' time via a source-level
  -- pre-scan of each .agda file (see 'findPrivateRanges').

  -- Recover dead-end private definitions that Agda's compileDef hook
  -- skips. 'buildInterface' runs 'eliminateDeadCode' before producing
  -- the interface, so private definitions no live code transitively
  -- calls never appear in 'iSignature' (and never reach 'compileDef').
  -- The TCM state signature ('getSignature') is the pre-prune source of
  -- truth (every checked definition, this module's + every import's):
  -- filter by the current module's name to recover its missed top-level
  -- private defs and run them through 'compileDefAD' so they pass the
  -- same ignore/exclude filters as visited defs.
  fullSig <- getSignature
  let thisModule  = iModuleName iface
      sigDefs     = [ (qn, def)
                    | (qn, def) <- HMap.toList (fullSig ^. sigDefinitions)
                    , A.qnameModule qn == thisModule ]
      visitedQNames = S.fromList [ _name d | Just d <- defs ]
      missing       = [ def | (qn, def) <- sigDefs
                            , not (qn `S.member` visitedQNames) ]
  extras <- mapM (compileDefAD opts env isMain) missing
  let result = defs ++ extras

  -- '--incremental' write path.
  --
  -- For an IMPORTED module the emitted fragment is a pure function of
  -- its (always dead-code-pruned) interface — identical whether the
  -- module was fresh-checked or warm-loaded — so it is cached
  -- unconditionally. Only the MAIN module's output is enriched by the
  -- 'getSignature' dead-private recovery above, and 'stSignature'
  -- holds its defs only when it was actually type-checked this run
  -- ('sigDefs' non-empty): caching a warm-loaded main module would
  -- freeze the degraded warm variant (the "warm-.agdai edge loss",
  -- see TODO.md) into the cache, so the main module is cached only
  -- from a fresh check.
  when (useFragmentCache opts) $ do
    let cacheable = case isMain of
          NotMain -> True
          IsMain  -> not (null sigDefs) || null (catMaybes result)
    when cacheable $ do
      ignoredAll   <- readIgnoredEdges
      providersAll <- readMethodProviders
      -- This module's contributions = what was added to the
      -- side-channels since 'moduleSetup' snapshotted them. Exact by
      -- construction: a name-prefix slice misses defs Agda homes in
      -- anonymous modules (bare '_.…' / prefixless copies), whose
      -- chains then silently lose their contracted edges on an
      -- all-cache-hit run.
      let ignoredFrag = M.difference ignoredAll (envIgnoredBefore env)
          -- Providers grow by *prepending* binders per method key, so
          -- the delta on a shared key is the new list's prefix.
          providersFrag = M.differenceWith
            (\ new old -> case take (length new - length old) new of
                            [] -> Nothing
                            xs -> Just xs)
            providersAll
            (envProvidersBefore env)
          path = fragmentFileFor (cacheDirFor opts) (prettyShow tlmn)
      writeFragment path (optionsFingerprint opts) (iFullHash iface)
        (FragmentData (catMaybes result) ignoredFrag providersFrag)

  return result

-- | After all modules are compiled, build the per-format output.
postCompileAD
  :: Options -> IsMain -> Map TopLevelModuleName [Maybe ADDef] -> TCM ()
postCompileAD opts _ defMap = do
  let rawDefs0 :: [ADDef]
      rawDefs0 = concat . M.elems $ fmap catMaybes defMap

  -- Contract dep edges through ignored helpers (with-functions, inlined
  -- module-instantiation copies, etc.) using the side-channel populated
  -- during 'compileDefAD'. Running in 'postCompile' guarantees the
  -- side-channel is complete.
  defsContracted <- contractIgnoredEdges rawDefs0

  -- Append edges from each kept def's deps to any registered instance
  -- binders. After contraction, so the providers chased are still real.
  defsWithInstances <- addInstanceMethodEdges defsContracted

  -- Back-fill '_access' on each def by scanning each .agda source file
  -- once for top-level @private@-block line ranges, then matching each
  -- def's binding-site line against those ranges (see 'backfillAccess'
  -- and 'findPrivateRanges').
  let defFile :: Map QName FilePath
      defFile = M.fromList
        [ (_name d, fp)
        | d <- defsWithInstances
        , Just (fp, _ln) <- [srcLocOf (_name d)]
        ]
      filesToScan :: [FilePath]
      filesToScan = S.toAscList (S.fromList (M.elems defFile))
  privRanges <- liftIO $
    fmap M.fromList $
      mapM (\fp -> (,) fp <$> findPrivateRanges fp) filesToScan
  let defs0 = map (backfillAccess privRanges defFile) defsWithInstances

  let allQNames0 :: [QName]
      allQNames0 = collectAllQNames defs0

  -- Pool every module-name signal before classification so modules
  -- visible only as import-edge endpoints (e.g. stdlib reached via
  -- transitive imports, with no surviving QName and no source under
  -- root) are still classified as external.
  precomputed <- liftIO $ readIORef precomputedGraphRef
  visited <- getVisitedModules
  let -- Raw (source-module, target-module) pairs for every import edge
      -- across all visited interfaces, computed once. The endpoint pool
      -- below and 'visitedImportEdges' (which layers the '--no-externals'
      -- 'keep' filter) both consume this, so each 'iImportedModules' walk
      -- and 'prettyShow' happens once rather than twice.
      importPairs :: [(String, String)]
      importPairs =
        [ (prettyShow src, prettyShow tgt)
        | (src, mi) <- M.toList visited
        , (tgt, _hash) <- iImportedModules (miInterface mi)
        ]
      visitedImportEndpoints :: [String]
      visitedImportEndpoints = concat [ [s, t] | (s, t) <- importPairs ]
      precomputeImportEndpoints :: [String]
      precomputeImportEndpoints =
        concat [ [s, t] | (s, t) <- precomputedImports precomputed ]
      -- (host, source, qname) re-export triples across all visited
      -- interfaces, computed once and shared with 'reExportRows' below so
      -- 'collectReExports' walks each interface once.
      reExportRaw :: [(String, String, String)]
      reExportRaw = concatMap (collectReExports . miInterface) (M.elems visited)
      -- Re-export hubs: a module that only @open … public@s names from
      -- elsewhere contributes no QName of its own to 'allQNames0', so
      -- without this it slips past classification entirely and survives
      -- @--no-externals@. Pool both the re-export host and the source it
      -- re-exports from, so a stdlib hub like @Data.List@ gets seen and
      -- (being out-of-root) classified external. In-root hubs already
      -- carry True via the QName / precompute signals, and 'M.insertWith
      -- (||)' keeps it.
      reExportEndpoints :: [String]
      reExportEndpoints = concat [ [h, t] | (h, t, _n) <- reExportRaw ]
      allEndpointModules :: [String]
      allEndpointModules =
        visitedImportEndpoints ++ precomputeImportEndpoints ++ reExportEndpoints

  externals0 <- liftIO $
    classifyExternalModules
      allQNames0
      (precomputedModuleFiles precomputed)
      allEndpointModules

  -- '--no-externals': drop every external module from the rendered
  -- graph (no nodes, no edges into them). The 'keep' predicate below
  -- carries the same filter through to the module-level wire outputs
  -- (import edges, re-exports). A diagnostic summary of the stripped
  -- externals is attached to the wire output only under
  -- @--no-externals@.
  let externalsSummary :: Maybe ExternalsSummary
      !externalsSummary
        | optNoExternals opts = Just $! buildExternalsSummary externals0 defs0
        | otherwise           = Nothing

      (defs, externalModules) =
        if optNoExternals opts
          then (dropExternalDefs externals0 defs0, S.empty)
          else (defs0, externals0)

      stateMap :: Map QName DefState
      stateMap = M.fromList [ (_name d, _state d) | d <- defs ]

      allQNames :: [QName]
      allQNames = collectAllQNames defs

  mMain <- liftIO $ readIORef mainModuleRef
  let entryModule = fmap (prettyShow . fst) mMain

  failed0 <- liftIO $ readIORef failedModulesRef
  let failedModules =
        S.filter (not . isExcludedModule (optExcludeModules opts)) failed0

  let excludes = optExcludeModules opts
      -- Whether a module should appear in the module-level wire output:
      -- composes @--exclude@ with @--no-externals@.
      keep m =  not (isExcludedModule excludes m)
             && not (optNoExternals opts && S.member m externals0)
      visitedImportEdges :: [(String, String)]
      visitedImportEdges =
        [ (s, t) | (s, t) <- importPairs, s /= t, keep s, keep t ]

      -- (host-module, source-module, [qualified-names]) rows aggregated
      -- across every visited interface. 'collectReExports' returns one
      -- row per (host, source, qname) triple, grouped here by
      -- (host, source) and dedup-sorted.
      reExportRows :: [(String, String, [String])]
      reExportRows =
        let raw = [ (h, t, n) | (h, t, n) <- reExportRaw, keep h, keep t ]
            grouped :: M.Map (String, String) (S.Set String)
            grouped = M.fromListWith S.union
              [ ((h, t), S.singleton n) | (h, t, n) <- raw ]
        in [ (h, t, S.toAscList ns) | ((h, t), ns) <- M.toAscList grouped ]

  let precomputedImportEdges =
        [ (s, t)
        | (s, t) <- precomputedImports precomputed
        , s /= t, keep s, keep t
        ]
      importEdges =
        S.toList (S.fromList (visitedImportEdges ++ precomputedImportEdges))

      -- Module -> source-file path, lifted from the binding site of any
      -- QName homed in that module. Used by the v2 graph.json for
      -- moduleToFile / fileToModules. 'keep' is applied so @--exclude@
      -- and @--no-externals@ never surface a path for a module excluded
      -- from the wire output.
      moduleFileMap :: Map String FilePath
      moduleFileMap = M.fromListWith (\_old new -> new)
        [ (modName, p)
        | qn <- allQNames
        , let modName = prettyShow (qnameModule qn)
        , keep modName
        , Just (p, _line) <- [srcLocOf qn]
        ]

      sourceFiles :: [FilePath]
      sourceFiles = precomputedSourceFiles precomputed

  info $
    "agda-deps: postCompile: " ++ show (length defs) ++ " definitions, "
    ++ show (length allQNames) ++ " unique QNames, "
    ++ show (length importEdges) ++ " module-import edges."

  positions <- liftIO $ computeQNamePositions allQNames defs

  -- Create the output dir before any file write.
  case optOutDir opts of
    Just dir -> liftIO $ createDirectoryIfMissing True dir
    Nothing  -> return ()

  -- '--incremental' serialise skip: an all-cache-hit run (nothing
  -- recompiled) whose output context (module set + options + build) is
  -- unchanged produces byte-identical monolithic output, so the
  -- re-emit can be skipped. 'anyRecompiled' guards the def /content/;
  -- 'monoToken' guards everything else.
  let liveModules = map prettyShow (M.keys defMap)
      cacheDir    = cacheDirFor opts
      monoToken   = outputToken opts liveModules
  anyRecompiled <- liftIO $ readIORef recompiledRef
  let monoSkippable = useSerialiseCache opts && not anyRecompiled

  info "agda-deps: writing output…"
  case optFormat opts of
    FmtDot ->
      let dotText = renderDot (optColors opts) stateMap failedModules defs
      in case optOutDir opts of
           Just dir -> liftIO $ TL.writeFile (dir </> "deps.dot") dotText
           Nothing  -> liftIO $ TL.putStrLn dotText
    FmtJson ->
      case optOutDir opts of
        Nothing -> liftIO $ putStrLn $
          renderJson (optJsonMode opts) (optPackedAnalytical opts) stateMap externalModules failedModules entryModule importEdges sourceFiles moduleFileMap positions reExportRows externalsSummary defs
        Just dir -> liftIO $ do
          let path = dir </> "deps.json"
          skip <- if monoSkippable
                    then do
                      m <- readManifest cacheDir (optGzip opts)
                      ex <- System.Directory.doesFileExist path
                      pure (manifestLookup "deps.json" m == Just monoToken && ex)
                    else pure False
          if skip
            then info "agda-deps: --incremental: deps.json unchanged; skipped re-emit."
            else do
              writeFile path $
                renderJson (optJsonMode opts) (optPackedAnalytical opts) stateMap externalModules failedModules entryModule importEdges sourceFiles moduleFileMap positions reExportRows externalsSummary defs
              when (useSerialiseCache opts) $
                writeManifest cacheDir (optGzip opts)
                  (manifestFromList [("deps.json", monoToken)])
    FmtHtml ->
      case optOutDir opts of
        Nothing -> liftIO $ do
          hPutStrLn stderr "agda-deps: --format=html requires -o/--out-dir to be set."
          exitFailure
        Just dir -> do
          -- Snippet embedding only exists in the --lazy path
          -- (snippets/<module>.json, fetched on demand). Without --lazy,
          -- skip collecting snippets and emit a notice.
          snippetMap <-
            if optWithSource opts && optLazy opts
              then collectHighlightedSnippets (optNoSourceFor opts) dir allQNames
              else do
                when (optWithSource opts) $
                  -- NB: plain '++' concatenation, not a backslash string gap —
                  -- this module enables CPP, which collapses '\'-newline.
                  info ("agda-deps: --with-source has no effect without --lazy "
                     ++ "(self-contained inline source was removed); rendering "
                     ++ "without embedded snippets. Use --with-source --lazy, or "
                     ++ "--agda-html-dir=DIR to link out to `agda --html` pages.")
                return M.empty
          liftIO $ writeHtmlOutput dir opts (SerialiseCtx (useSerialiseCache opts) cacheDir monoSkippable monoToken) snippetMap stateMap externalModules failedModules entryModule importEdges sourceFiles moduleFileMap positions externalsSummary defs

  -- '--incremental': prune fragment files for modules no longer in the
  -- graph (deleted / renamed source) so the cache doesn't grow without
  -- bound. Live set = every module Agda processed this run (the keys of
  -- the def map, hit or recompiled).
  when (useFragmentCache opts) $ do
    removed <- gcFragments cacheDir liveModules
    when (removed > 0) $
      info $ "agda-deps: --incremental: pruned " ++ show removed
           ++ " stale fragment(s)."

-- | Compute (x, y) positions per definition QName. Each node id is
-- paired with an integer module id so the grid fallback keeps a
-- module's definitions together. Uses 'hashQName' as the node id.
computeQNamePositions :: [QName] -> [ADDef] -> IO (Map QName Position)
computeQNamePositions allQNames defs = do
  let moduleNamesSet :: S.Set String
      moduleNamesSet =
        S.fromList [ prettyShow (qnameModule qn) | qn <- allQNames ]
      -- Ascending module order keeps the grid layout deterministic.
      moduleIx :: M.Map String Int
      moduleIx = M.fromList (zip (S.toAscList moduleNamesSet) [(0 :: Int)..])
      moduleIdOf qn = M.findWithDefault 0 (prettyShow (qnameModule qn)) moduleIx
      nodesByMod = [ (hashQName qn, moduleIdOf qn) | qn <- allQNames ]
      qnameById :: IM.IntMap QName
      qnameById = IM.fromList (zip (map fst nodesByMod) allQNames)
      idSet :: IS.IntSet
      idSet = IS.fromList (map fst nodesByMod)
      edges =
        [ (sH, tH)
        | d <- defs
        , let sH = hashQName (_name d)
        , IS.member sH idSet
        , t <- S.toList (_deps d)
        , let tH = hashQName t
        , IS.member tH idSet
        ]
  positions <- computePositions nodesByMod edges
  return $ M.fromList
    [ (qn, p)
    | ((nid, _), p) <- zip nodesByMod positions
    , Just qn <- [IM.lookup nid qnameById]
    ]

-- | The @--incremental@ serialise-cache context threaded into the
-- output writers. When 'scEnabled' is 'False' the writers behave
-- exactly as the non-incremental path (write everything, no manifest).
data SerialiseCtx = SerialiseCtx
  { scEnabled   :: Bool       -- ^ 'useSerialiseCache'.
  , scCacheDir  :: FilePath   -- ^ where the serialise manifest lives.
  , scMonoSkip  :: Bool       -- ^ enabled && nothing recompiled this run.
  , scMonoToken :: Epoch      -- ^ output-context token ('outputToken').
  }

-- | Write the HTML output: a single self-contained @deps.html@, or
-- (with @--lazy@) a small shell plus @graph.json@, per-module detail
-- files, and per-module snippet files.
--
-- Under @--incremental@ the lazy per-module + snippet files are
-- rewritten only when their content epoch changed since the last run
-- (skipped files never even force their content thunk); the non-lazy
-- single @deps.html@ uses the monolithic no-op skip.
writeHtmlOutput
  :: FilePath -> Options -> SerialiseCtx
  -> Map QName Snippet -> Map QName DefState
  -> Set String         -- ^ external module names
  -> Set String         -- ^ failed module names
  -> Maybe String       -- ^ entry-point module name
  -> [(String, String)] -- ^ import edges
  -> [FilePath]         -- ^ source files (from precompute)
  -> Map String FilePath -- ^ module name -> binding-site source file
  -> Map QName Position  -- ^ positions per QName
  -> Maybe ExternalsSummary -- ^ diagnostic summary under --no-externals
  -> [ADDef] -> IO ()
writeHtmlOutput dir opts sc snippetMap stateMap externals failed entryModule importEdges sourceFiles moduleFileMap positions externalsSummary defs
  | optLazy opts = do
      let gz = optGzip opts
          lo = renderLazyHtml (optView opts) (optColors opts) gz (optAgdaHtmlDir opts) snippetMap stateMap externals failed entryModule importEdges sourceFiles moduleFileMap positions externalsSummary defs
      -- Shell + module-level skeleton are small: always (re)write.
      writeFile (dir </> "deps.html")  (lazyShellHtml lo)
      writeJsonMaybeGz gz (dir </> "graph.json") (lazyGraphJson lo)

      oldManifest <-
        if scEnabled sc then readManifest (scCacheDir sc) gz else pure mempty

      detailEntries <-
        case lazyModuleDetails lo of
          []      -> return []
          details -> do
            let modulesDir = dir </> "modules"
            createDirectoryIfMissing True modulesDir
            mapM (writeDetail gz oldManifest modulesDir) details

      snippetEntries <-
        case lazySnippetBundles lo of
          []      -> return []
          bundles -> do
            let snippetDir = dir </> "snippets"
            createDirectoryIfMissing True snippetDir
            mapM (writeBundle gz oldManifest snippetDir (optMaxSnippetBytes opts)) bundles

      when (scEnabled sc) $
        writeManifest (scCacheDir sc) gz
          (manifestFromList (catMaybes (detailEntries ++ snippetEntries)))
  | otherwise = do
      let path = dir </> "deps.html"
      skip <- if scMonoSkip sc
                then do
                  m  <- readManifest (scCacheDir sc) (optGzip opts)
                  ex <- System.Directory.doesFileExist path
                  pure (manifestLookup "deps.html" m == Just (scMonoToken sc) && ex)
                else pure False
      if skip
        then info "agda-deps: --incremental: deps.html unchanged; skipped re-emit."
        else do
          writeFile path $
            renderHtml (optView opts) (optColors opts) (optGzip opts) (optAgdaHtmlDir opts) snippetMap stateMap externals failed entryModule importEdges sourceFiles moduleFileMap positions externalsSummary defs
          when (scEnabled sc) $
            writeManifest (scCacheDir sc) (optGzip opts)
              (manifestFromList [("deps.html", scMonoToken sc)])
  where
    -- Whether a file (and its .gz sibling, if gzip) is already on disk.
    fileCurrent :: Bool -> FilePath -> IO Bool
    fileCurrent gz full = do
      a <- System.Directory.doesFileExist full
      if not gz then pure a
                else (a &&) <$> System.Directory.doesFileExist (full ++ ".gz")

    -- A module-detail file. Returns the manifest entry to record (always
    -- 'Just' — the file is on disk afterwards), forcing the content
    -- thunk only when an actual write is needed.
    writeDetail
      :: Bool -> Manifest -> FilePath -> (FilePath, Epoch, String)
      -> IO (Maybe (String, Epoch))
    writeDetail gz oldM destDir (fname, epoch, content) = do
      let slot = "modules/" ++ fname
          full = destDir </> fname
      uptodate <- if scEnabled sc && manifestLookup slot oldM == Just epoch
                    then fileCurrent gz full else pure False
      when (not uptodate) $ writeJsonMaybeGz gz full content
      pure (Just (slot, epoch))

    -- A snippet bundle. The byte cap is checked only when a (re)write is
    -- actually needed, so an unchanged bundle is skipped without forcing
    -- its content. A cap change is folded into the epoch so it forces a
    -- re-evaluation. Cap-skipped bundles write no file and record no
    -- manifest entry ('Nothing').
    writeBundle
      :: Bool -> Manifest -> FilePath -> Maybe Int -> (FilePath, Epoch, String)
      -> IO (Maybe (String, Epoch))
    writeBundle gz oldM destDir mCap (fname, epoch0, content) = do
      let slot  = "snippets/" ++ fname
          full  = destDir </> fname
          epoch = combineEpochs [epoch0, hashEpoch (show mCap)]
      uptodate <- if scEnabled sc && manifestLookup slot oldM == Just epoch
                    then fileCurrent gz full else pure False
      if uptodate
        then pure (Just (slot, epoch))
        else case mCap of
          Just n | length content > n -> do
            hPutStrLn stderr $
              "agda-deps: skipping snippet bundle "
                ++ fname ++ " (" ++ show (length content)
                ++ " bytes > " ++ show n ++ " byte cap; set --max-snippet-bytes=0 to disable)"
            pure Nothing
          _ -> do
            writeJsonMaybeGz gz full content
            pure (Just (slot, epoch))

-- | Write a JSON file at @path@, and (when @gz@ is set) a gzip-compressed
-- @path.gz@ sibling.
writeJsonMaybeGz :: Bool -> FilePath -> String -> IO ()
writeJsonMaybeGz gz path content = do
  writeFile path content
  if gz
    then BL.writeFile (path ++ ".gz") (GZip.compress (BLC.pack content))
    else return ()

-- | Classify modules whose source files live outside the project root
-- (the working directory after the .agda-lib discovery in 'Main').
--
-- A module is "external" when no signal places its source under the
-- project root. Three signals are pooled:
--
--   * 'srcLocOf' for every QName known (def names + dep targets). A
--     QName with @rangeFile = Nothing@ (compiler builtins:
--     @Agda.Primitive@, @Agda.Builtin.*@) gives no in-root evidence.
--   * The pre-compute scan's @module → file@ map
--     ('precomputedModuleFiles'), covering every @.agda@ / @.lagda*@
--     file under the @-i@ paths.
--   * Module names appearing as import-edge endpoints (visited
--     interfaces + pre-compute scan), so endpoint-only modules with no
--     surviving QName are still classified.
--
-- Returns the complement: every seen module name with no known in-root
-- path.
classifyExternalModules
  :: [QName]                  -- ^ every QName referenced in the graph
  -> [(String, FilePath)]     -- ^ module → file map from precompute
  -> [String]                 -- ^ all module names seen as endpoints
  -> IO (Set String)
classifyExternalModules qns precomputedMF endpointModules = do
  cwd <- getCurrentDirectory
  let root = normalise cwd
      isUnderRoot p = root `isPrefixOf` normalise p
      -- Per-module flag: at least one signal lands at an in-root
      -- source path.
      seedFromQNames :: Map String Bool
      seedFromQNames = foldl' bumpQ M.empty qns
        where
          bumpQ !acc qn =
            let !modName = prettyShow (qnameModule qn) :: String
                !inRoot  = case srcLocOf qn of
                  Just (p, _) -> isUnderRoot p
                  Nothing     -> False
            in M.insertWith (||) modName inRoot acc
      seedFromPrecompute :: Map String Bool
      seedFromPrecompute = foldl' bumpP seedFromQNames precomputedMF
        where bumpP !acc (m, p) = M.insertWith (||) m (isUnderRoot p) acc
      -- Endpoints with no other evidence default to "not in-root".
      inRootByModule :: Map String Bool
      inRootByModule = foldl' bumpE seedFromPrecompute endpointModules
        where bumpE !acc m = M.insertWith (||) m False acc
  return $ S.fromList
    [ m | (m, inRoot) <- M.toList inRootByModule, not inRoot ]

-- | '--no-externals': drop every definition homed in an external
-- module and strip dependency edges into one. Module names are matched
-- against @externals@ as 'prettyShow' of 'qnameModule'. Filters both
-- '_deps' and '_depsProv' to keep the @M.keysSet _depsProv == _deps@
-- invariant.
dropExternalDefs :: Set String -> [ADDef] -> [ADDef]
dropExternalDefs externals defs =
  let isExt qn = S.member (prettyShow (qnameModule qn)) externals
  in [ d { _deps = S.filter (not . isExt) (_deps d)
         , _depsProv = M.filterWithKey (\qn _ -> not (isExt qn)) (_depsProv d)
         }
     | d <- defs, not (isExt (_name d))
     ]

-- | Replace each def's lazy 'Nothing' '_access' with the right
-- 'DefAccess'. We classify a def as private when its '_line' falls
-- within a @private@-block range in its source file. Defs without a
-- usable '_line' (synthetic names) keep 'Nothing' / fall back to
-- public.
backfillAccess :: Map FilePath [(Int, Int)] -> Map QName FilePath -> ADDef -> ADDef
backfillAccess privRanges defFile d =
  let mFile = M.lookup (_name d) defFile
      mLine = _line d
      isPriv = case (mFile, mLine) of
        (Just fp, Just ln) -> case M.lookup fp privRanges of
          Just rs -> any (\(a, b) -> ln >= a && ln <= b) rs
          Nothing -> False
        _ -> False
      !acc = if isPriv then AccPrivate else AccPublic
  in d { _access = Just acc }

-- | Scan an Agda source file for top-level @private@ blocks and return
-- their (inclusive) line ranges.
--
-- A @private@ keyword at column 0 begins a block whose body extends
-- until the next line whose first non-whitespace character is at
-- column 0 (a sibling top-level declaration). @private@ at deeper
-- indentation is not handled.
findPrivateRanges :: FilePath -> IO [(Int, Int)]
findPrivateRanges fp = do
  exists <- System.Directory.doesFileExist fp
  if not exists
    then return []
    else do
      ls <- lines <$> readFile fp
      let indexed = zip [1 :: Int ..] ls
      return $ go indexed []
  where
    -- Accumulates ranges in reverse; order doesn't matter for the
    -- membership test the caller does.
    go [] acc = acc
    go ((n, ln) : rest) acc
      | isPrivateHeader ln =
          let (body, after) = span (\(_, l) -> not (startsAtCol0 l)) rest
              endLine = case body of
                ((_, _) : _) -> fst (last body)
                []           -> n
          in go after ((n, endLine) : acc)
      | otherwise = go rest acc

    -- "private" keyword at the start of a line.
    isPrivateHeader s = stripSp s == "private" || startsWith s "private "
    stripSp = dropWhile (== ' ')

    -- A line "starts at column 0" when its first character is
    -- non-whitespace. Blank lines never terminate a block.
    startsAtCol0 s = case s of
      []      -> False
      (c : _) -> c /= ' ' && c /= '\t'

    startsWith xs prefix = take (length prefix) xs == prefix

-- | Walk every (sub-)scope in an 'Interface' and extract the public
-- re-exports: names in 'ImportedNS' (@open public@ from another module)
-- and 'PublicNS' (@open … public@ of a child module). Both namespaces
-- are checked because Agda's 'openModule' uses 'PublicNS' for opens of
-- a child module and 'ImportedNS' otherwise.
--
-- Returns @(host, source, qname)@ triples (caller aggregates and
-- dedups). The host is the interface's top-level module name; the
-- source is the original @QName@'s @qnameModule@, so chained
-- re-exports collapse to the definition site. Self-edges (the host's
-- own definitions via PublicNS) are filtered by comparing @qnameModule@
-- to @iModuleName@.
collectReExports :: Interface -> [(String, String, String)]
collectReExports i =
  let hostMod  = prettyShow (iTopLevelModuleName i)
      thisModN = iModuleName i
  in [ (hostMod, prettyShow (qnameModule qn), nodeKey qn)
     | scope <- M.elems (iScope i)
     , ns <- [ ImportedNS, PublicNS ]
     , let nsBag = scopeNameSpace ns scope
     , (_concrete, anames) <- M.toList (nsNames nsBag)
     , an <- List1.toList anames
       -- 2.9 moved 'AbstractName' to Agda.Syntax.Abstract.Name; 2.8 keeps
       -- it (and 'anameName') in Agda.Syntax.Scope.Base (imported above).
#if MIN_VERSION_Agda(2,9,0)
     , let qn = A.anameName an
#else
     , let qn = anameName an
#endif
     , qnameModule qn /= thisModN  -- skip own definitions
     ]
