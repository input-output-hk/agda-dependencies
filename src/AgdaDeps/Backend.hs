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

import Control.Monad ( when, unless, forM )
import Control.Monad.IO.Class ( MonadIO(liftIO) )
import Control.DeepSeq ( force )

import Data.IORef ( IORef, newIORef, readIORef, writeIORef )
import Data.Word ( Word64 )
import Data.Map ( Map )
import qualified Data.Map as M
import qualified Data.Map.Strict as MS ( insertWith )
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.Maybe ( catMaybes, fromMaybe )
import Data.Set ( Set )
import qualified Data.Set as S

import qualified Data.Text as T
import qualified Data.Text.Lazy.IO as TL

import Data.Version ( showVersion )
import Paths_agda_deps ( version )

import Data.List ( foldl', isPrefixOf, sortOn )

import qualified System.Directory
import System.Directory ( createDirectoryIfMissing, getCurrentDirectory )
import System.Exit ( exitFailure )
import System.FilePath ( (</>), normalise )
import System.IO ( hPutStrLn, stderr )

import Agda.Utils.GetOpt ( OptDescr(Option), ArgDescr(ReqArg, NoArg) )

import Agda.Syntax.Abstract.Name ( QName )
import qualified Agda.Syntax.Abstract.Name as A
import Agda.Syntax.Internal ( qnameModule, qnameName )
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
  , iFilePragmaOptions
  )
-- 'pragmaStrings' + 'iFilePragmaOptions' live here on both 2.8 and 2.9
-- (module has no export list) — no CPP for the file-OPTIONS scan.
import Agda.Interaction.Library.Base ( pragmaStrings )
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
  ( ADDef(..), NodeRef(..), DefAccess(..)
  , compileDefAD, collectAllQNames, nodeKey, moduleKey, hashQName
  , mkRef, nodeKeyOfQ, moduleKeyOfQ, nrSrcLoc
  , optionEscapes
  , resetIgnoredEdges, contractIgnoredEdges
  , resetMethodProviders, addInstanceMethodEdges
  , IgnoredEdgeMap, readIgnoredEdges, mergeIgnoredEdges
  , MethodProviderMap, readMethodProviders, mergeMethodProviders )
import AgdaDeps.FragmentCache
  ( FragmentData(..)
  , optionsFingerprint, fragmentFileFor, readFragment, writeFragment
  , gcFragments )
import AgdaDeps.SerialiseCache
  ( Manifest, readManifest, writeManifest, manifestLookup, manifestFromList
  , Epoch, combineEpochs, hashEpoch )
import AgdaDeps.Deps ( nodeKeyVersion )
import BuildInfo ( buildFingerprint )
import AgdaDeps.Layout ( Position, computePositions )
import AgdaDeps.Options
  ( Options(..), OutputFormat(..), DefState
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
import AgdaDeps.Source ( Snippet, collectHighlightedSnippets )
import AgdaDeps.Backend.Dot  ( renderDot )
import AgdaDeps.Backend.GraphJson ( GraphInput(..), ExternalsSummary, buildExternalsSummary )
import AgdaDeps.Backend.Html ( renderHtml, renderLazyHtml, LazyOutput(..) )
import AgdaDeps.Backend.Json ( renderJson )

-- | Per-module state from 'moduleSetup', threaded to 'postModuleAD':
-- in-scope names plus pre-module snapshots of the two side-channels, so
-- the fragment cache attributes each module's contributions as a
-- before/after delta. Must be a delta, not a name-prefix slice: prefixes
-- miss defs Agda homes in anonymous modules (bare @_.…@ copies).
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

-- | @--config=PATH@ parser. No-op: 'Main' loads the config (seeding
-- 'Options') and strips the flag from argv before GetOpt sees it.
configOpt :: Monad m => String -> Options -> m Options
configOpt _ opts = return opts

-- | The list of 'ADDef's a single module produces.
type ModuleRes = [Maybe ADDef]

-- | The exported backend, seeded with 'defaultOptions'.
backend :: Backend' Options Options ModuleEnv ModuleRes (Maybe ADDef)
backend = backendWithSeed defaultOptions

-- | Like 'backend' but with a caller-seeded 'options' field ('Main'
-- overlays a discovered @.agda-deps.yml@ before CLI parsing).
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
        "HTML view variant: module-dag-pods (default), cytoscape,\nide-three-pane, source-centric, notion-doc, wiki-backlinks,\nsigma, big-module-dag-pods, critical-path-holes,\nprogress-dashboard, cartographic-atlas, sunburst-hierarchy,\nreading-order-narrative, pixel-grid-overview."
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
        "Path to the pages written by `agda --html`, RELATIVE to the\ngenerated HTML (e.g. --agda-html-dir=html). The sunburst-hierarchy view\nthen shows an \"Open source\" link opening DIR/<Module.Name>.html. Off by\ndefault; when unset the output is unchanged. Best served over HTTP."
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
        "Cache each module's compiled dependency fragment under\n<out-dir>/.agda-deps-cache, keyed on the module's interface hash,\nand skip the per-definition walk on later runs when the module is\nunchanged. Requires Agda >= 2.8; disabled under --keep-going."
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

-- | Pre-compile hook: clear the side-channels (ignored-edge +
-- instance-method) for a fresh in-process run; warn once on
-- @--incremental@ + @--keep-going@.
preCompileAD :: Options -> TCM Options
preCompileAD opts = do
  resetIgnoredEdges
  resetMethodProviders
  liftIO $ writeIORef recompiledRef False
  -- Compute the run's fragment fingerprint once (constant across modules).
  liftIO $ writeIORef optsFingerprintRef (optionsFingerprint opts)
  when (optIncremental opts && optKeepGoing opts) $
    info ("agda-deps: --incremental is disabled under --keep-going "
       ++ "(fragments are only cached from fully-checked runs).")
  return opts

-- | Whether the fragment cache is active this run.
useFragmentCache :: Options -> Bool
useFragmentCache opts =
  optIncremental opts && not (optKeepGoing opts)

-- | Where fragments + the serialise manifest live: @--cache-dir@, else
-- @<out-dir>/.agda-deps-cache@ (or the cwd when output is stdout).
cacheDirFor :: Options -> FilePath
cacheDirFor opts = case optCacheDir opts of
  Just dir -> dir
  Nothing  -> fromMaybe "." (optOutDir opts) </> ".agda-deps-cache"

-- | Whether the @--incremental@ serialise cache is active. Disabled
-- under @--keep-going@.
useSerialiseCache :: Options -> Bool
useSerialiseCache opts = optIncremental opts && not (optKeepGoing opts)

-- | Output-context token for the monolithic no-op skip: fingerprints
-- everything other than per-def /content/ (live module set,
-- output-affecting options, build identity, node-key convention). With
-- \"nothing recompiled\" ('recompiledRef'), an unchanged token means the
-- output is byte-identical.
outputToken :: Options -> [String] -> Epoch
outputToken opts modules = combineEpochs
  [ hashEpoch buildFingerprint
  , fromIntegral nodeKeyVersion
  , hashEpoch (unwords optStrings)
  , hashEpoch (unwords modules)
  ]
  where
    -- One 'show' per output-affecting option (a single tuple exceeds
    -- GHC's 'Show' limit). Add every new output-affecting option here, or
    -- the no-op skip serves stale output.
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
        fp <- curOptsFingerprint
        let path = fragmentFileFor (cacheDirFor opts) (prettyShow tlmn)
        readFragment path fp (iFullHash iface)
      else return Nothing
  case mCached of
    Just frag -> do
      -- Skip bypasses compileDef + postModule: re-inject the module's
      -- side-channel slices (else contraction drops edges through its
      -- ignored helpers) and the entry-module capture postModuleAD would do.
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
-- served from the fragment cache. An all-cache-hit run (stays 'False')
-- with an unchanged output context can skip the serialise. Reset in
-- 'preCompileAD'.
{-# NOINLINE recompiledRef #-}
recompiledRef :: IORef Bool
recompiledRef = unsafePerformIO $ newIORef False

-- | The run's fragment-cache options fingerprint ('optionsFingerprint'),
-- computed once in 'preCompileAD': constant for the run, so memoised here
-- rather than re-derived (a 'show' + hash) per module.
{-# NOINLINE optsFingerprintRef #-}
optsFingerprintRef :: IORef Word64
optsFingerprintRef = unsafePerformIO $ newIORef 0

-- | The memoised run fingerprint (see 'optsFingerprintRef').
curOptsFingerprint :: TCM Word64
curOptsFingerprint = liftIO (readIORef optsFingerprintRef)


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

  -- Recover dead-end private defs Agda's compileDef hook skips:
  -- 'eliminateDeadCode' prunes private defs no live code calls from
  -- 'iSignature'. 'getSignature' is the pre-prune source of truth; filter
  -- to this module and run the missed defs through 'compileDefAD' so they
  -- pass the same filters. (Access is back-filled later in 'postCompileAD'.)
  fullSig <- getSignature
  let thisModule  = iModuleName iface
      sigDefs     = [ (qn, def)
                    | (qn, def) <- HMap.toList (fullSig ^. sigDefinitions)
                    , A.qnameModule qn == thisModule ]
      -- Membership by 'NodeRef' ('Ord' is hash-then-key): a signature def
      -- is 'missing' iff its 'mkRef' isn't among the visited defs'
      -- 'NodeRef's. 'mkRef' is a cache hit for every visited def
      -- (compileDef already built it).
      visitedRefs = S.fromList [ _name d | Just d <- defs ]
  missing <- fmap catMaybes . forM sigDefs $ \ (qn, def) -> do
               r <- mkRef qn
               pure $! if r `S.member` visitedRefs then Nothing else Just def
  extras <- mapM (compileDefAD opts env isMain) missing
  let result = defs ++ extras

  -- '--incremental' write path. An IMPORTED module's fragment is a pure
  -- function of its pruned interface — cache unconditionally. The MAIN
  -- module is enriched by the dead-private recovery above (only on a fresh
  -- check, 'sigDefs' non-empty); caching a warm-loaded main module would
  -- freeze the degraded variant, so cache it only fresh.
  when (useFragmentCache opts) $ do
    let cacheable = case isMain of
          NotMain -> True
          IsMain  -> not (null sigDefs) || null (catMaybes result)
    when cacheable $ do
      ignoredAll   <- readIgnoredEdges
      providersAll <- readMethodProviders
      -- This module's contributions = the delta since 'moduleSetup'
      -- snapshotted the side-channels. Delta, not name-prefix slice (see
      -- 'ModuleEnv').
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
      fp <- curOptsFingerprint
      writeFragment path fp (iFullHash iface)
        (FragmentData (catMaybes result) ignoredFrag providersFrag)

  return result

-- | After all modules are compiled, build the per-format output.
--
-- The @--incremental@ monolithic no-op skip is decided up front (before
-- the graph is built) from the options, live module set and on-disk
-- manifest — never the graph — so when it fires the whole 'emitFullGraph'
-- pipeline is skipped, not just the final write. Same inputs as the
-- per-format 'monoOutputUnchanged' check, taken earlier. Only @deps.json@
-- and non-lazy @deps.html@ carry a single token; @--lazy@ and @dot@ fall
-- through to the full pipeline.
postCompileAD
  :: Options -> IsMain -> Map TopLevelModuleName [Maybe ADDef] -> TCM ()
postCompileAD opts _ defMap = do
  -- Forced to full NF under --incremental only (the token + GC need it,
  -- and forcing here stops the thunk pinning @defMap@ through the render).
  -- Non-incremental never consumes it, so the bang forces only WHNF.
  let !liveModules
        | optIncremental opts = force (map prettyShow (M.keys defMap))
        | otherwise           = map prettyShow (M.keys defMap)
      cacheDir  = cacheDirFor opts
      monoToken = outputToken opts liveModules
  anyRecompiled <- liftIO $ readIORef recompiledRef
  let monoSkippable = useSerialiseCache opts && not anyRecompiled
  earlySkip <- liftIO $ hoistedMonoSkip opts cacheDir monoToken monoSkippable
  case earlySkip of
    Just slot -> do
      info $ "agda-deps: --incremental: " ++ slot ++ " unchanged; skipped re-emit."
      when (useFragmentCache opts) $ do
        removed <- gcFragments cacheDir liveModules
        when (removed > 0) $
          info $ "agda-deps: --incremental: pruned " ++ show removed
               ++ " stale fragment(s)."
    Nothing ->
      emitFullGraph opts defMap liveModules cacheDir monoToken monoSkippable

-- | Whether the up-front no-op skip fires, and for which output file
-- ('Nothing' = fall through). Reuses 'monoOutputUnchanged' so it can't
-- drift from the per-format check. Only @deps.json@ / non-lazy @deps.html@.
hoistedMonoSkip :: Options -> FilePath -> Epoch -> Bool -> IO (Maybe String)
hoistedMonoSkip opts cacheDir monoToken monoSkippable =
  case (optOutDir opts, optFormat opts) of
    (Just dir, FmtJson) -> check "deps.json" (dir </> "deps.json")
    (Just dir, FmtHtml)
      | not (optLazy opts) -> check "deps.html" (dir </> "deps.html")
    _ -> pure Nothing
  where
    check slot path = do
      ok <- monoOutputUnchanged monoSkippable cacheDir (optGzip opts) slot monoToken path
      pure (if ok then Just slot else Nothing)

-- | Build the per-format output — the full graph pipeline. Called by
-- 'postCompileAD' when the up-front skip didn't fire; the skip inputs it
-- already computed are threaded in rather than recomputed.
emitFullGraph
  :: Options
  -> Map TopLevelModuleName [Maybe ADDef]
  -> [String] -> FilePath -> Epoch -> Bool
  -> TCM ()
emitFullGraph opts defMap liveModules cacheDir monoToken monoSkippable = do
  let rawDefs0 :: [ADDef]
      rawDefs0 = concatMap catMaybes (M.elems defMap)

  -- Contract dep edges through ignored helpers (with-functions, inlined
  -- module-instantiation copies, etc.). Runs in 'postCompile' so the
  -- side-channel populated during 'compileDefAD' is complete.
  defsContracted <- contractIgnoredEdges rawDefs0

  -- Append edges from each kept def's deps to any registered instance
  -- binders. After contraction, so the providers chased are still real.
  defsWithInstances <- addInstanceMethodEdges defsContracted

  -- Back-fill '_access' by scanning each .agda file once for top-level
  -- @private@-block line ranges and matching each def's binding line
  -- against them (see 'backfillAccess' / 'findPrivateRanges'). Scan every
  -- distinct binding-site file.
  let filesToScan :: [FilePath]
      filesToScan = S.toAscList $ S.fromList
        [ fp | d <- defsWithInstances, Just (fp, _ln) <- [nrSrcLoc (_name d)] ]
  privRanges <- liftIO $
    fmap M.fromList $
      mapM (\fp -> (,) fp <$> findPrivateRanges fp) filesToScan
  let defs0 = map (backfillAccess privRanges) defsWithInstances

  let allQNames0 :: [NodeRef]
      allQNames0 = collectAllQNames defs0

  -- Pool every module-name signal before classification so modules
  -- visible only as import-edge endpoints (no surviving QName, no
  -- source under root) are still classified as external.
  precomputed <- liftIO $ readIORef precomputedGraphRef
  visited <- getVisitedModules
  let -- (source, target) module pairs for every import edge across all
      -- visited interfaces; shared by the endpoint pool and
      -- 'visitedImportEdges'.
      importPairs :: [(String, String)]
      importPairs =
        [ (srcS, prettyShow tgt)
        | (src, mi) <- M.toList visited
        , let !srcS = prettyShow src   -- once per source module, not per target
        , (tgt, _hash) <- iImportedModules (miInterface mi)
        ]
      visitedImportEndpoints :: [String]
      visitedImportEndpoints = concat [ [s, t] | (s, t) <- importPairs ]
      precomputeImportEndpoints :: [String]
      precomputeImportEndpoints =
        concat [ [s, t] | (s, t) <- precomputedImports precomputed ]
      -- (host, source, qname, alias) re-export tuples across all visited
      -- interfaces, computed once and shared with 'reExportRows' below.
      reExportRaw :: [(String, String, String, Maybe String)]
      reExportRaw = concatMap (collectReExports . miInterface) (M.elems visited)
      -- Re-export hubs: a module that only @open … public@s names
      -- contributes no QName of its own to 'allQNames0', so it would
      -- survive @--no-externals@. Pool host + re-exported source so an
      -- out-of-root hub (e.g. @Data.List@) is classified external.
      reExportEndpoints :: [String]
      reExportEndpoints = concat [ [h, t] | (h, t, _n, _a) <- reExportRaw ]
      allEndpointModules :: [String]
      allEndpointModules =
        visitedImportEndpoints ++ precomputeImportEndpoints ++ reExportEndpoints

  externals0 <- liftIO $
    classifyExternalModules
      allQNames0
      (precomputedModuleFiles precomputed)
      allEndpointModules

  -- '--no-externals': drop every external module (no nodes, no edges).
  -- The 'keep' predicate carries the same filter to module-level wire
  -- outputs; a diagnostic summary of the stripped externals is attached.
  let externalsSummary :: Maybe ExternalsSummary
      !externalsSummary
        | optNoExternals opts = Just $! buildExternalsSummary externals0 defs0
        | otherwise           = Nothing

      (defs, externalModules) =
        if optNoExternals opts
          then (dropExternalDefs externals0 defs0, S.empty)
          else (defs0, externals0)

      stateMap :: Map NodeRef DefState
      stateMap = M.fromList [ (_name d, _state d) | d <- defs ]

      -- Only @--no-externals@ filters 'defs', so only it needs a fresh
      -- QName pass; the default path's 'defs' == 'defs0', so reuse
      -- 'allQNames0'.
      allQNames :: [NodeRef]
      allQNames | optNoExternals opts = collectAllQNames defs
                | otherwise           = allQNames0

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

      -- (host, source, [qnames], [(alias, canonical)]) rows aggregated
      -- across visited interfaces. 'collectReExports' yields one tuple per
      -- (host, source, qname, alias); grouped by (host, source),
      -- dedup-sorted. The renames map collects only 'Just'-alias tuples;
      -- empty when nothing was renamed (Wire omits the field then —
      -- byte-identical output).
      reExportRows :: [(String, String, [String], [(String, String)])]
      reExportRows =
        let raw = [ (h, t, n, a) | (h, t, n, a) <- reExportRaw, keep h, keep t ]
            grouped :: M.Map (String, String) (S.Set String)
            grouped = M.fromListWith S.union
              [ ((h, t), S.singleton n) | (h, t, n, _) <- raw ]
            renamesM :: M.Map (String, String) (S.Set (String, String))
            renamesM = M.fromListWith S.union
              [ ((h, t), S.singleton (al, n)) | (h, t, n, Just al) <- raw ]
        in [ (h, t, S.toAscList ns, maybe [] S.toAscList (M.lookup (h, t) renamesM))
           | ((h, t), ns) <- M.toAscList grouped
           ]

      -- File-level @{-# OPTIONS #-}@ soundness escapes per visited module.
      -- Read 'iFilePragmaOptions' (the file's OWN OPTIONS), NOT
      -- 'iOptionsUsed' (folds in CLI + library opts, would misattribute
      -- e.g. @--lenient-imports@ to every module). 'optionEscapes' keeps
      -- only safety-relevant flags; 'keep' applies the
      -- @--exclude@/@--no-externals@ filter; 'sortOn fst' orders the
      -- hash-keyed survivors; 'not (null esc)' drops escape-free modules.
      -- Per-block @NO_POSITIVITY_CHECK@ etc. are declaration pragmas, not
      -- OPTIONS, so never appear here.
      moduleOptionEscapes :: [(String, [String])]
      moduleOptionEscapes = sortOn fst
        [ (m, esc)
        | mi <- M.elems visited
        , let iface = miInterface mi
              m     = prettyShow (iTopLevelModuleName iface)
        , keep m
        , let esc = optionEscapes
                      (concatMap pragmaStrings (iFilePragmaOptions iface))
        , not (null esc)
        ]

  let precomputedImportEdges =
        [ (s, t)
        | (s, t) <- precomputedImports precomputed
        , s /= t, keep s, keep t
        ]
      importEdges =
        S.toList (S.fromList (visitedImportEdges ++ precomputedImportEdges))

      -- Module -> source-file path, from the binding site of any QName
      -- homed there. Feeds v2 graph.json moduleToFile / fileToModules.
      -- 'keep' so excluded modules surface no path.
      moduleFileMap :: Map String FilePath
      moduleFileMap = M.fromListWith (\_old new -> new)
        [ (modName, p)
        | qn <- allQNames
        , let modName = moduleKey qn
        , keep modName
        , Just (p, _line) <- [nrSrcLoc qn]
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

  let -- Shared graph-data bundle for the JSON / HTML emitters; each render
      -- path overrides only its format-specific fields via record update.
      baseGraphInput = GraphInput
        { giDefs             = defs
        , giStateMap         = stateMap
        , giImportEdges      = importEdges
        , giSourceFiles      = sourceFiles
        , giModuleFile       = moduleFileMap
        , giEntryModule      = entryModule
        , giExternalModules  = externalModules
        , giFailedModules    = failedModules
        , giPositions        = positions
        , giWithSource       = False
        , giSnippetModules   = []
        , giLazy             = False
        , giExtraModules     = S.empty
        , giReExports        = []
        , giExternalsSummary = externalsSummary
        , giPackedAnalytical = False
        , giModuleOptionEscapes = moduleOptionEscapes
        }

  info "agda-deps: writing output…"
  case optFormat opts of
    FmtDot ->
      let dotText = renderDot (optColors opts) stateMap failedModules defs
      in case optOutDir opts of
           Just dir -> liftIO $ TL.writeFile (dir </> "deps.dot") dotText
           Nothing  -> liftIO $ TL.putStrLn dotText
    FmtJson ->
      let jsonText = renderJson (optJsonMode opts)
                       (baseGraphInput { giReExports = reExportRows
                                       , giPackedAnalytical = optPackedAnalytical opts })
      in case optOutDir opts of
        Nothing -> liftIO $ putStrLn jsonText
        Just dir -> liftIO $ do
          let path = dir </> "deps.json"
          skip <- monoOutputUnchanged monoSkippable cacheDir (optGzip opts)
                    "deps.json" monoToken path
          if skip
            then info "agda-deps: --incremental: deps.json unchanged; skipped re-emit."
            else do
              writeFile path jsonText
              when (useSerialiseCache opts) $
                writeManifest cacheDir (optGzip opts)
                  (manifestFromList [("deps.json", monoToken)])
    FmtHtml ->
      case optOutDir opts of
        Nothing -> liftIO $ do
          hPutStrLn stderr "agda-deps: --format=html requires -o/--out-dir to be set."
          exitFailure
        Just dir -> do
          -- Snippet embedding only exists in the --lazy path. Without
          -- --lazy, skip collecting snippets and emit a notice.
          snippetMap <-
            if optWithSource opts && optLazy opts
              then collectHighlightedSnippets (optNoSourceFor opts) dir allQNames
              else do
                when (optWithSource opts) $
                  -- CPP module: use '++', not a backslash string gap (CPP collapses '\'-newline).
                  info ("agda-deps: --with-source has no effect without --lazy "
                     ++ "(self-contained inline source was removed); rendering "
                     ++ "without embedded snippets. Use --with-source --lazy, or "
                     ++ "--agda-html-dir=DIR to link out to `agda --html` pages.")
                return M.empty
          liftIO $ writeHtmlOutput dir opts (SerialiseCtx (useSerialiseCache opts) cacheDir monoSkippable monoToken) snippetMap baseGraphInput

  -- '--incremental': prune fragment files for modules no longer in the
  -- graph. Live set = every module Agda processed this run.
  when (useFragmentCache opts) $ do
    removed <- gcFragments cacheDir liveModules
    when (removed > 0) $
      info $ "agda-deps: --incremental: pruned " ++ show removed
           ++ " stale fragment(s)."

-- | Compute (x, y) positions per definition QName. Each node id is
-- paired with an integer module id so the grid fallback keeps a
-- module's definitions together. Uses 'hashQName' as the node id.
computeQNamePositions :: [NodeRef] -> [ADDef] -> IO (Map NodeRef Position)
computeQNamePositions allQNames defs = do
  let moduleNamesSet :: S.Set String
      moduleNamesSet =
        S.fromList [ moduleKey qn | qn <- allQNames ]
      -- Ascending module order keeps the grid layout deterministic.
      moduleIx :: M.Map String Int
      moduleIx = M.fromList (zip (S.toAscList moduleNamesSet) [(0 :: Int)..])
      moduleIdOf qn = M.findWithDefault 0 (moduleKey qn) moduleIx
      nodesByMod = [ (hashQName qn, moduleIdOf qn) | qn <- allQNames ]
      qnameById :: IM.IntMap NodeRef
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

-- | The @--incremental@ serialise-cache context threaded into the output
-- writers. When 'scEnabled' is 'False' the writers behave as the
-- non-incremental path (write everything, no manifest).
data SerialiseCtx = SerialiseCtx
  { scEnabled   :: Bool       -- ^ 'useSerialiseCache'.
  , scCacheDir  :: FilePath   -- ^ where the serialise manifest lives.
  , scMonoSkip  :: Bool       -- ^ enabled && nothing recompiled this run.
  , scMonoToken :: Epoch      -- ^ output-context token ('outputToken').
  }

-- | Whether a monolithic output (@deps.json@ / @deps.html@) re-emit can
-- be skipped: @skippable@ (cache active + nothing recompiled), the file
-- exists, and its manifest slot matches the current @token@. Shared by
-- the JSON and HTML paths so the two checks can't drift. Needs BOTH the
-- recompiled guard (in @skippable@) and a matching @token@.
monoOutputUnchanged
  :: Bool -> FilePath -> Bool -> String -> Epoch -> FilePath -> IO Bool
monoOutputUnchanged skippable cacheDir gz slot token path
  | not skippable = pure False
  | otherwise = do
      m  <- readManifest cacheDir gz
      ex <- System.Directory.doesFileExist path
      pure (manifestLookup slot m == Just token && ex)

-- | Write the HTML output: a self-contained @deps.html@, or (with
-- @--lazy@) a shell plus @graph.json@, per-module detail files, and
-- snippet files.
--
-- Under @--incremental@ the lazy per-module + snippet files are rewritten
-- only when their content epoch changed (skipped files never force their
-- thunk); the non-lazy @deps.html@ uses the monolithic no-op skip.
writeHtmlOutput
  :: FilePath -> Options -> SerialiseCtx
  -> Map NodeRef Snippet -- ^ per-definition source snippets (@--with-source@)
  -> GraphInput          -- ^ shared graph data (from 'postCompileAD')
  -> IO ()
writeHtmlOutput dir opts sc snippetMap gi
  | optLazy opts = do
      let gz = optGzip opts
          lo = renderLazyHtml (optView opts) (optColors opts) gz (optAgdaHtmlDir opts) snippetMap gi
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
      skip <- monoOutputUnchanged (scMonoSkip sc) (scCacheDir sc) (optGzip opts)
                "deps.html" (scMonoToken sc) path
      if skip
        then info "agda-deps: --incremental: deps.html unchanged; skipped re-emit."
        else do
          writeFile path $
            renderHtml (optView opts) (optColors opts) (optGzip opts) (optAgdaHtmlDir opts) snippetMap gi
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

    -- A module-detail file. Returns the manifest entry (always 'Just' —
    -- on disk afterwards), forcing the content thunk only on an actual write.
    writeDetail
      :: Bool -> Manifest -> FilePath -> (FilePath, Epoch, String)
      -> IO (Maybe (String, Epoch))
    writeDetail gz oldM destDir (fname, epoch, content) = do
      let slot = "modules/" ++ fname
          full = destDir </> fname
      uptodate <- if scEnabled sc && manifestLookup slot oldM == Just epoch
                    then fileCurrent gz full else pure False
      unless uptodate $ writeJsonMaybeGz gz full content
      pure (Just (slot, epoch))

    -- A snippet bundle. The byte cap is checked only when a (re)write is
    -- needed, so an unchanged bundle is skipped without forcing its content.
    -- A cap change is folded into the epoch. Cap-skipped bundles write no
    -- file and record no manifest entry ('Nothing').
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
  when gz $ BL.writeFile (path ++ ".gz") (GZip.compress (BLC.pack content))

-- | Classify modules whose source lives outside the project root (the
-- cwd after 'Main''s .agda-lib discovery). A module is external when no
-- signal places its source under root. Three signals pooled:
--
--   * 'nrSrcLoc' for every known QName (builtins with no range give none).
--   * The pre-compute @module → file@ map ('precomputedModuleFiles').
--   * Import-edge endpoints, so endpoint-only modules (no surviving
--     QName) are still classified.
--
-- Returns the complement: every seen module with no in-root path.
classifyExternalModules
  :: [NodeRef]                -- ^ every node referenced in the graph
  -> [(String, FilePath)]     -- ^ module → file map from precompute
  -> [String]                 -- ^ all module names seen as endpoints
  -> IO (Set String)
classifyExternalModules qns precomputedMF endpointModules = do
  cwd <- getCurrentDirectory
  let root = normalise cwd
      isUnderRoot p = root `isPrefixOf` normalise p
      -- Per-module flag: at least one signal lands at an in-root source
      -- path. 'isUnderRoot' (normalise + isPrefixOf) is memoised per
      -- distinct FilePath in @pc@, so it runs once per file, not once per
      -- node (10k-100k nodes vs a few hundred files). Strict inserts keep
      -- the @||@ accumulator a WHNF Bool.
      seedFromQNames :: Map String Bool
      seedFromQNames = snd (foldl' bumpQ (M.empty, M.empty) qns)
        where
          bumpQ (!pc, !acc) qn =
            let !modName = moduleKey qn
            in case nrSrcLoc qn of
                 Nothing     -> (pc, MS.insertWith (||) modName False acc)
                 Just (p, _) -> case M.lookup p pc of
                   Just ir -> (pc, MS.insertWith (||) modName ir acc)
                   Nothing -> let !ir = isUnderRoot p
                              in ( M.insert p ir pc
                                 , MS.insertWith (||) modName ir acc )
      seedFromPrecompute :: Map String Bool
      seedFromPrecompute = foldl' bumpP seedFromQNames precomputedMF
        where bumpP !acc (m, p) = MS.insertWith (||) m (isUnderRoot p) acc
      -- Endpoints with no other evidence default to "not in-root".
      inRootByModule :: Map String Bool
      inRootByModule = foldl' bumpE seedFromPrecompute endpointModules
        where bumpE !acc m = MS.insertWith (||) m False acc
  return $ S.fromList
    [ m | (m, inRoot) <- M.toList inRootByModule, not inRoot ]

-- | '--no-externals': drop every definition homed in an external
-- module and strip dependency edges into one. Module names matched via
-- 'moduleKey'. Filters both '_deps' and '_depsProv' to keep the
-- @M.keysSet _depsProv == _deps@ invariant.
dropExternalDefs :: Set String -> [ADDef] -> [ADDef]
dropExternalDefs externals defs =
  let isExt qn = S.member (moduleKey qn) externals
  -- Filter the provenance map once and derive '_deps' from its keys
  -- ('M.keysSet', no re-check), not by running 'isExt' over both — the
  -- @M.keysSet _depsProv == _deps@ invariant makes them identical.
  in [ let !prov' = M.filterWithKey (\qn _ -> not (isExt qn)) (_depsProv d)
       in d { _deps = M.keysSet prov', _depsProv = prov' }
     | d <- defs, not (isExt (_name d))
     ]

-- | Replace each def's 'Nothing' '_access' with a 'DefAccess': private
-- when '_line' falls within a @private@-block range in its source file,
-- else public (synthetic names with no usable '_line' fall back to public).
backfillAccess :: Map FilePath [(Int, Int)] -> ADDef -> ADDef
backfillAccess privRanges d =
  -- 'nrFile' straight off the NodeRef. 'isPriv' fires only when '_line'
  -- is 'Just'; a line-less case falls through to public.
  let mFile = nrFile (_name d)
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

-- | Walk every (sub-)scope in an 'Interface' and extract public
-- re-exports: names in 'ImportedNS' (@open public@ from another module)
-- and 'PublicNS' (@open … public@ of a child module). Both, because
-- 'openModule' uses 'PublicNS' for child-module opens, 'ImportedNS'
-- otherwise.
--
-- Returns @(host, source, qname, alias)@ tuples (caller aggregates).
-- Host = the interface's top-level module; source = the 'QName''s
-- 'qnameModule' (chained re-exports collapse to the definition site);
-- self-edges filtered via 'iModuleName'.
--
-- @alias@ is the post-@renaming@ in-scope spelling ('nsNames' key) when
-- it differs from the canonical unqualified name ('qnameName', NOT the
-- last 'nodeKey' segment, which can carry an @\@line@ suffix); 'Nothing'
-- when un-renamed. Lets a consumer resolve @Host.combine@ back to
-- @M.merge@ under @renaming (merge to combine)@.
collectReExports :: Interface -> [(String, String, String, Maybe String)]
collectReExports i =
  let hostMod  = prettyShow (iTopLevelModuleName i)
      thisModN = iModuleName i
  in [ (hostMod, srcMod, nodeKeyOfQ qn, alias)
     | scope <- M.elems (iScope i)
     , ns <- [ ImportedNS, PublicNS ]
     , let nsBag = scopeNameSpace ns scope
     , (concrete, anames) <- M.toList (nsNames nsBag)
     , an <- List1.toList anames
       -- 2.9: 'anameName' from Agda.Syntax.Abstract.Name; 2.8: from Agda.Syntax.Scope.Base.
#if MIN_VERSION_Agda(2,9,0)
     , let qn = A.anameName an
#else
     , let qn = anameName an
#endif
     , qnameModule qn /= thisModN  -- skip own definitions
       -- 'moduleKeyOfQ' lifts anonymous (where/section) sub-modules to the
       -- named owner, so the re-export points at the definition site.
     , let srcMod = moduleKeyOfQ qn
       -- Lifting can collapse a host-owned section onto the host; that's
       -- not a re-export from elsewhere, so drop it.
     , srcMod /= hostMod
       -- The 'nsNames' key is the post-@renaming@ in-scope spelling; a
       -- 'Just' only when it differs from the canonical unqualified name.
     , let alias = let a = prettyShow concrete
                       canon = prettyShow (qnameName qn)
                   in if a == canon then Nothing else Just a
     ]
