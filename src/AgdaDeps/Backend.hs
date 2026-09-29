{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecordWildCards #-}
-- | The Agda 'Backend'' record + hooks, plus the post-compile
-- dispatcher that routes the collected 'ADDef's to the per-format
-- renderer.
module AgdaDeps.Backend
  ( -- * Backend wiring
    backend
  , backendWithSeed
  , parseBackendFlags
  , failedModulesRef
  , precomputedGraphRef

    -- * Output writing (shared with "AgdaDeps.SkipAgda")
  , checkOutputFlags
  , writeOutputs
  , noSerialiseCtx
  ) where

import Control.Monad ( foldM, when, unless, forM, forM_ )
import Control.Monad.IO.Class ( MonadIO(liftIO) )
import Control.DeepSeq ( force )

import Data.IORef ( IORef, newIORef, readIORef, writeIORef )
import Data.Word ( Word64 )
import Data.Map ( Map )
import qualified Data.Map as M
import qualified Data.Map.Strict as MS ( insertWith )
import Data.Maybe ( catMaybes, fromMaybe )
import Data.Set ( Set )
import qualified Data.Set as S

import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Data.Text.Lazy.IO as TL

import Data.Version ( showVersion )
import Paths_agda_deps ( version )

import Data.List ( foldl', sort, sortOn )

import qualified System.Directory
import System.Directory ( createDirectoryIfMissing, getCurrentDirectory )
import System.Exit ( exitFailure )
import System.FilePath ( (</>) )
import System.IO ( hPutStrLn, stderr )

import Agda.Interaction.Options ( runOptM )
import Agda.Utils.GetOpt
  ( OptDescr(Option), ArgDescr(ReqArg, NoArg), ArgOrder(Permute), getOpt' )

import qualified Agda.Syntax.Abstract.Name as A
#if MIN_VERSION_Agda(2,9,0)
import Agda.Syntax.Abstract.Name ( anameName )
#endif
import Agda.Syntax.Internal ( qnameModule, qnameName )
import Agda.Syntax.Common.Pretty ( prettyShow )
import Agda.Syntax.Scope.Base
  ( NameSpace(nsNames), NameSpaceId(ImportedNS, PublicNS), scopeNameSpace
#if !MIN_VERSION_Agda(2,9,0)
  -- 2.8 keeps 'anameName' here; 2.9 moved it to Agda.Syntax.Abstract.Name.
  , anameName
#endif
  )
import Agda.Syntax.TopLevelModuleName ( TopLevelModuleName )

import qualified Data.List.NonEmpty as List1

import Agda.TypeChecking.Monad ( TCM )
import Agda.TypeChecking.Monad.Base
  ( iImportedModules, miInterface, Interface
  , iScope, iModuleName, iTopLevelModuleName
  , sigDefinitions, iFullHash
  , iFilePragmaOptions, iOptionsUsed
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
  ( Backend', Backend'_boot(..), Recompile(..) )
import Agda.Syntax.Common ( IsMain(..) )

import System.IO.Unsafe ( unsafePerformIO )

import AgdaDeps.Deps
  ( ADDef(..), NodeRef(..), DefAccess(..)
  , compileDefAD, collectAllQNames, moduleKey, hashQName
  , withDependencyProvenance
  , mkRef, nodeKeyOfQ, moduleKeyOfQ, nrSrcLoc
  , optionEscapes
  , unsolvedInterfaceLines, liveSilentMetaLines
  , contractIgnoredEdges
  , addInstanceMethodEdges
  , SideChannels, readSideChannels, sideChannelDelta, mergeSideChannels
  , readUnsaturatedRefs, partiallyAppliedSet
  , resetSideChannels
  , ArgUsage(..), effectiveOptionFlags )
import AgdaDeps.FragmentCache
  ( FragmentData(..)
  , fragmentSideChannels, makeFragmentData
  , optionsFingerprint, fragmentFileFor, readFragment, writeFragment
  , gcFragments )
import AgdaDeps.SerialiseCache
  ( Manifest, readManifest, writeManifest, manifestLookup, manifestFromList
  , Epoch, combineEpochs, hashEpoch )
import AgdaDeps.Deps ( nodeKeyVersion )
import BuildInfo ( buildFingerprint )
import AgdaDeps.Layout ( Position, computePositions )
import AgdaDeps.Options
  ( Options(..), OutputFormat(..)
  , ColorPalette(..), defaultOptions, defaultPalette, formatSlug, lazyTreeOutput
  , outdirOpt, formatOpt
  , colorOpt, lazyOpt, excludeOpt
  , gzipOpt, keepGoingOpt, skipAgdaOpt
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
import AgdaDeps.Util ( underCwd )

import qualified Codec.Compression.GZip as GZip
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import AgdaDeps.Backend.Dot  ( renderDot )
import AgdaDeps.Backend.GraphJson
  ( GraphInput(..), GraphJsonOutput(..), ExternalsSummary
  , ModuleDetailJson(mdjFileName, mdjEpoch, mdjContent)
  , buildExternalsSummary, buildGraphJson, renderJson )

-- | Per-module state from 'moduleSetup', threaded to 'postModuleAD': a
-- pre-module snapshot of all side channels, so the fragment cache
-- attributes each module's contributions as a before/after delta. Must
-- be a delta, not a name-prefix slice: prefixes miss defs Agda homes in
-- anonymous modules (bare @_.…@ copies).
newtype ModuleEnv = ModuleEnv
  { envSideChannelsBefore :: SideChannels }

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
        "Write output files to DIR (deps.dot / deps.json).\nWithout it, output goes to stdout; --lazy requires it. A DIR\nending in .json / .dot also selects the format unless\n--format is given."
      , Option []    ["format"]  (ReqArg formatOpt "FORMAT")
        "Output format: dot (default) or json. HTML rendering moved to\n`agda-plotter`, which reads the JSON this emits."
      , Option []    ["theme"]   (ReqArg themeOpt "THEME")
        "Colour preset for DOT output: default (=light), dark, or\ncolorblind. Individual --color-* flags override the corresponding\nslot. `agda-plotter` takes the same flags for HTML."
      , Option []    ["config"]  (ReqArg configOpt "PATH")
        "Load a YAML config file (kebab-case keys mirror CLI flag\nnames). CLI flags override config values. The flag is also\nresolved from $AGDA_DEPS_CONFIG or a .agda-deps.yml next to\nthe nearest .agda-lib."
      , Option []    ["color-defined"]
          (ReqArg (colorOpt "color-defined"   (\p s -> p{ colorDefined   = s })) "#RRGGBB")
        ("Color for fully-defined definitions (default: "
           ++ colorDefined defaultPalette ++ ").")
      , Option []    ["color-postulate"]
          (ReqArg (colorOpt "color-postulate" (\p s -> p{ colorPostulate = s })) "#RRGGBB")
        ("Color for postulates (default: " ++ colorPostulate defaultPalette ++ ").")
      , Option []    ["color-hole"]
          (ReqArg (colorOpt "color-hole"      (\p s -> p{ colorHole      = s })) "#RRGGBB")
        ("Color for definitions containing unsolved holes (default: "
           ++ colorHole defaultPalette ++ ").")
      , Option []    ["lazy"] (NoArg lazyOpt)
        "JSON output only: split into a module-level graph.json plus\nper-module modules/<Module>.json detail files, instead of one\nmonolithic deps.json. `agda-plotter` renders a page shell that\nfetches them on demand; that needs HTTP serving. Requires -o."
      , Option []    ["exclude"] (ReqArg excludeOpt "PREFIX")
        "Drop every module whose name is PREFIX or starts with PREFIX.\nCan be repeated."
      , Option []    ["gzip"] (NoArg gzipOpt)
        "Lazy JSON output only: also write a .gz sibling next to every\nemitted JSON file."
      , Option []    ["color-failed"]
          (ReqArg (colorOpt "color-failed"    (\p s -> p{ colorFailed    = s })) "#RRGGBB")
        ("Color for modules whose type-check failed under --keep-going\n(default: "
           ++ colorFailed defaultPalette ++ ").")
      , Option []    ["keep-going"] (NoArg keepGoingOpt)
        "Continue past Agda type-check errors. Modules whose type-check\nfailed are tagged 'failed' in the output graph."
      , Option []    ["skip-agda"] (NoArg skipAgdaOpt)
        "Don't invoke Agda at all. Render a module-level graph straight\nfrom the source-file scan (line-parses 'module' / 'import')."
      , Option []    ["incremental"] (NoArg incrementalOpt)
        "Cache each module's compiled dependency fragment under\n<out-dir>/.agda-deps-cache, keyed on the module's interface hash,\nand skip the per-definition walk on later runs when the module is\nunchanged. Disabled under --keep-going."
      , Option []    ["cache-dir"] (ReqArg cacheDirOpt "DIR")
        "Override the --incremental cache location (fragments +\nserialise manifest). Default: <out-dir>/.agda-deps-cache. No\neffect without --incremental."
      , Option []    ["packed-analytical"] (NoArg packedAnalyticalOpt)
        "Augment --json-mode=packed's 'defs' with per-definition\nanalytical arrays (kind/line/access/unsafe/unsolvedMetas, plus\ntype under --with-signatures and subterm hashes under\n--with-term-hashes), so the compact form carries everything\nexpanded does. Off by default; no effect on expanded output."
      , Option []    ["quiet"] (NoArg quietOpt)
        "Suppress 'I am working' progress lines on stderr; only genuine\nwarnings and errors are printed."
      , Option []    ["no-externals"] (NoArg noExternalsOpt)
        "Drop external modules (anything outside the project root) from\nthe rendered graph entirely — modules, definitions, and edges."
      , Option []    ["json-mode"] (ReqArg jsonModeOpt "MODE")
        "JSON shape: packed (default; base64-encoded typed arrays + CSR\nadjacency, compact for huge graphs) or expanded (arrays of\nrecords keyed by qname, no base64 — friendlier for downstream\ntooling)."
      , Option []    ["lenient-imports"] (NoArg lenientImportsOpt)
        "Tolerate imports of modules with open holes; forwarded to Agda\nas --allow-unsolved-metas. Useful with --keep-going when commits\ndeliberately leave '?' holes.\nSilent unsolved metas (missing record fields, failed instance\nsearch, unsolved _) still surface: per-def 'unsolvedMetas' counts\nand a top-level 'unsolvedModules' rollup — failedModules: [] alone\ndoes not mean everything compiles.\nINCOMPATIBLE WITH --safe DEPENDENCIES: --allow-unsolved-metas is a\nglobal Agda flag and any --safe module in the dep closure (e.g. the\nstandard library) will reject it with [SafeFlagPragma]. For projects\nbuilt on a --safe stdlib, prefer --keep-going alone."
      , Option []    ["resolve-deps"] (NoArg resolveDepsOpt)
        "Constrain Agda's search path to the project's .agda-lib 'depend:'\nclosure. Expands into '--no-libraries -i <dir>...' before Agda's\nCLI parser runs. Useful when two libraries with the same module\nname are registered (e.g. multiple stdlib versions) and Agda's\nresolver picks the wrong one, producing [AmbiguousTopLevelModuleName].\nFalls back silently to default behaviour if the project has no\n.agda-lib or resolution fails."
      , Option []    ["with-term-hashes"] (NoArg withTermHashesOpt)
        "Emit a canonical-form hash for every subterm walked\nin each definition. Off by default. Surfaces as\n'definitionSubtermHashes' in --json-mode=expanded; intended for\ndownstream AST-level CSE / lemma-extraction clustering."
      , Option []    ["min-term-depth"] (ReqArg minTermDepthOpt "N")
        ("Only emit hashes for subterms with AST depth\n>= N (default "
           ++ show (optMinTermDepth defaultOptions)
           ++ "). 1 disables the filter. Ignored without\n--with-term-hashes.")
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

-- | Parse the backend's own flags out of argv, layered on top of @seed@
-- (the config-seeded 'Options'), and return them with the positional
-- arguments. Uses 'getOpt'' so Agda's flags (@-i@, @--include-path@, …)
-- pass through as unrecognised and are ignored. Folding the CLI actions
-- over @seed@ gives the defaults → config → CLI precedence — the same
-- answer Agda's own parse hands the backend, available before Agda runs.
parseBackendFlags :: Options -> [String] -> Either String (Options, [String])
parseBackendFlags seed argv =
  let (actions, positionals, _unrec, errs) =
        getOpt' Permute (commandLineFlags backend) argv
  in if not (null errs)
       then Left (concat errs)
       else fmap (\o -> (o, positionals))
                 (fst (runOptM (foldM (\o act -> act o) seed actions)))

-- | Pre-compile hook: clear every side channel for a fresh in-process run,
-- then report every flag combination that does not compose.
--
-- This is the earliest the backend sees a fully-resolved 'Options':
-- Agda's own @GetOpt@ walks argv on top of the seed, so 'Main' has only
-- the seed and the raw argv. Agda has already type-checked by the time
-- this hook runs — but the per-definition walk, the layout pass and
-- graph assembly have not, so failing here still saves the bulk of the
-- backend's work rather than reporting at the very end.
-- 'checkOutputFlags' is shared with the @--skip-agda@ path, which
-- bypasses this hook entirely and does resolve options up front.
preCompileAD :: Options -> TCM Options
preCompileAD opts = do
  resetSideChannels
  liftIO $ writeIORef recompiledRef False
  -- Compute the run's fragment fingerprint once (constant across modules).
  liftIO $ writeIORef optsFingerprintRef (optionsFingerprint opts)
  when (optIncremental opts && optKeepGoing opts) $
    info ("agda-deps: --incremental is disabled under --keep-going "
       ++ "(fragments are only cached from fully-checked runs).")
  liftIO $ checkOutputFlags opts
  return opts

-- | Report the output-flag combinations that do not compose: exit on the
-- fatal one, notice on the merely-inert one.
--
-- Called from 'preCompileAD' and from 'AgdaDeps.SkipAgda', each as early
-- as its path can resolve options. One function, so the two paths cannot
-- disagree about which combinations are accepted or which are merely
-- reported.
checkOutputFlags :: Options -> IO ()
checkOutputFlags opts = do
  when (optLazy opts && optFormat opts == FmtJson
        && optOutDir opts == Nothing) $ do
    hPutStrLn stderr "agda-deps: --lazy requires -o/--out-dir to be set."
    exitFailure
  -- CPP module: use '++', not a backslash string gap (CPP collapses '\'-newline).
  when (optLazy opts && optFormat opts == FmtJson
        && not (lazyTreeOutput opts)) $
    info ("agda-deps: --lazy only splits packed JSON and --json-mode=expanded "
       ++ "is set; writing a single deps.json.")
  when (optLazy opts && optFormat opts /= FmtJson) $
    info ("agda-deps: --lazy only affects --format=json; it has no effect on "
       ++ formatSlug (optFormat opts) ++ " output.")

-- | Whether the @--incremental@ caches (fragments and the serialise
-- manifest) are active this run. Disabled under @--keep-going@.
incrementalCacheEnabled :: Options -> Bool
incrementalCacheEnabled opts =
  optIncremental opts && not (optKeepGoing opts)

-- | Where fragments + the serialise manifest live: @--cache-dir@, else
-- @<out-dir>/.agda-deps-cache@ (or the cwd when output is stdout).
cacheDirFor :: Options -> FilePath
cacheDirFor opts = case optCacheDir opts of
  Just dir -> dir
  Nothing  -> fromMaybe "." (optOutDir opts) </> ".agda-deps-cache"

-- | Output-context token for the monolithic no-op skip: fingerprints
-- every emitter input other than per-def /content/ — the live module
-- set, output-affecting options, build identity and node-key convention,
-- plus the run inputs no fragment carries: the source scan (every module
-- and file under @-i@, imported or not), the project root (external
-- classification) and the entry module. With \"nothing recompiled\"
-- ('recompiledRef'), an unchanged token means the output is
-- byte-identical.
outputToken
  :: Options -> PrecomputedGraph -> FilePath -> Maybe String -> [String]
  -> Epoch
outputToken opts precomputed root entry modules = combineEpochs
  [ hashEpoch buildFingerprint
  , fromIntegral nodeKeyVersion
  , hashEpoch (unwords optStrings)
  , hashEpoch (unwords modules)
  , hashEpoch (show precomputed)
  , hashEpoch (show (root, entry))
  ]
  where
    -- One 'show' per output-affecting option (a single tuple exceeds
    -- GHC's 'Show' limit). Add every new output-affecting option here, or
    -- the no-op skip serves stale output.
    optStrings =
      [ show (optFormat opts), show (optJsonMode opts), show (optLazy opts)
      , show (optColors opts), show (optGzip opts)
      , show (optNoExternals opts), show (optExcludeModules opts)
      , show (optWithSignatures opts)
      , show (optNormaliseSignatures opts), show (optShowImplicit opts)
      , show (optWithTermHashes opts), show (optMinTermDepth opts)
      , show (optPackedAnalytical opts)
      ]

moduleSetup
  :: Options -> IsMain -> TopLevelModuleName -> Maybe FilePath
  -> TCM (Recompile ModuleEnv ModuleRes)
moduleSetup opts isMain tlmn _ = do
  mCached <-
    if incrementalCacheEnabled opts
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
      mergeSideChannels (fragmentSideChannels frag)
      captureCurrentMainModule isMain tlmn
      info $ "agda-deps: --incremental: fragment hit for '"
             ++ prettyShow tlmn ++ "' ("
             ++ show (length (fragDefs frag)) ++ " defs)"
      return $ Skip (map Just (fragDefs frag))
    Nothing -> do
      liftIO $ writeIORef recompiledRef True
      Recompile . ModuleEnv <$> readSideChannels

{-# NOINLINE mainModuleRef #-}
mainModuleRef :: IORef (Maybe (TopLevelModuleName, [TopLevelModuleName]))
mainModuleRef = unsafePerformIO $ newIORef Nothing

-- | Record the entry module and its imports when this hook is for the main
-- module. The caller supplies an interface it already has.
captureMainModule
  :: IsMain -> TopLevelModuleName -> Interface -> TCM ()
captureMainModule NotMain _ _ = pure ()
captureMainModule IsMain tlmn iface =
  let imports = map fst (iImportedModules iface)
  in liftIO $ writeIORef mainModuleRef (Just (tlmn, imports))

-- | Cache-hit variant: read the current interface only for the main module.
captureCurrentMainModule :: IsMain -> TopLevelModuleName -> TCM ()
captureCurrentMainModule NotMain _ = pure ()
captureCurrentMainModule isMain tlmn =
  curIF >>= captureMainModule isMain tlmn

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
  captureMainModule isMain tlmn iface

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
  when (incrementalCacheEnabled opts) $ do
    let cacheable = case isMain of
          NotMain -> True
          IsMain  -> not (null sigDefs) || null (catMaybes result)
    when cacheable $ do
      channelsAfter <- readSideChannels
      -- This module's contributions = the delta since 'moduleSetup'
      -- snapshotted the side-channels. Delta, not name-prefix slice (see
      -- 'ModuleEnv').
      let channelsFrag =
            sideChannelDelta (envSideChannelsBefore env) channelsAfter
          path = fragmentFileFor (cacheDirFor opts) (prettyShow tlmn)
      fp <- curOptsFingerprint
      writeFragment path fp (iFullHash iface)
        (makeFragmentData (catMaybes result) channelsFrag)

  return result

-- | After all modules are compiled, build the per-format output.
--
-- The @--incremental@ monolithic no-op skip is decided up front (before
-- the graph is built) from the options, live module set and on-disk
-- manifest — never the graph — so when it fires the whole 'emitFullGraph'
-- pipeline is skipped, not just the final write. Only non-lazy
-- @deps.json@ carries a single token; @--lazy@ and @dot@ fall through to
-- the full pipeline.
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
  precomputed <- liftIO $ readIORef precomputedGraphRef
  root        <- liftIO getCurrentDirectory
  mMain       <- liftIO $ readIORef mainModuleRef
  let monoToken = outputToken opts precomputed root
                    (fmap (prettyShow . fst) mMain) liveModules
  anyRecompiled <- liftIO $ readIORef recompiledRef
  let monoSkippable = incrementalCacheEnabled opts && not anyRecompiled
  earlySkip <- liftIO $ hoistedMonoSkip opts cacheDir monoToken monoSkippable
  case earlySkip of
    Just slot -> do
      info $ "agda-deps: --incremental: " ++ slot ++ " unchanged; skipped re-emit."
      gcStaleFragments opts cacheDir liveModules
    Nothing ->
      emitFullGraph opts defMap liveModules cacheDir monoToken monoSkippable

-- | Whether the up-front no-op skip fires, and for which output file
-- ('Nothing' = fall through). Only the monolithic @deps.json@: the
-- @--lazy@ tree is many files with their own epochs, checked
-- individually in 'writeLazyTree' so a missing one is still rewritten,
-- and @dot@ is never cached.
--
-- Keyed on 'lazyTreeOutput' rather than @optLazy@, so
-- @--lazy --json-mode=expanded@ — which does write one monolithic file —
-- gets the skip too instead of building the whole graph first.
hoistedMonoSkip :: Options -> FilePath -> Epoch -> Bool -> IO (Maybe String)
hoistedMonoSkip opts cacheDir monoToken monoSkippable =
  case (optOutDir opts, optFormat opts) of
    (Just dir, FmtJson)
      | not (lazyTreeOutput opts) -> check "deps.json" (dir </> "deps.json")
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

  -- Work only the JSON forms consume (access, layout positions, the
  -- unsolved rollup): DOT reads none of it, so it skips the source scans
  -- and the sfdp subprocess.
  let jsonOnly :: MonadIO m => a -> m a -> m a
      jsonOnly dflt act
        | optFormat opts == FmtJson = act
        | otherwise                 = pure dflt

  -- Back-fill '_access' by scanning each .agda file once for its
  -- @private@-block line ranges and matching each def's binding line
  -- against them (see 'backfillAccess' / 'findPrivateRanges'). Scan every
  -- distinct binding-site file.
  let filesToScan :: [FilePath]
      filesToScan = S.toAscList $ S.fromList
        [ fp | d <- defsWithInstances, Just (fp, _ln) <- [nrSrcLoc (_name d)] ]
  privRanges <- jsonOnly M.empty $ liftIO $
    fmap M.fromList $
      mapM (\fp -> (,) fp <$> findPrivateRanges fp) filesToScan
  -- Back-fill 'auPartiallyApplied', the one 'ArgUsage' field that is not a
  -- property of its own definition: "referenced somewhere with fewer
  -- arguments than it takes" is a fact about the rest of the corpus, so
  -- 'argUsageOf' cannot know it and leaves it 'False'. Done HERE, with the
  -- other whole-corpus rollups, rather than at the wire boundary — so every
  -- renderer and every invariant check sees an internally consistent record
  -- instead of one patched behind the emitter's back.
  partiallyApplied <- partiallyAppliedSet <$> readUnsaturatedRefs
  let markPartial d = case _argUsage d of
        Just au | S.member (_name d) partiallyApplied ->
          d { _argUsage = Just au { auPartiallyApplied = True } }
        _ -> d
      defs0 = map (markPartial . backfillAccess privRanges) defsWithInstances

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

      -- Only @--no-externals@ filters 'defs', so only it needs a fresh
      -- QName pass; the default path's 'defs' == 'defs0', so reuse
      -- 'allQNames0'.
      allQNames :: [NodeRef]
      allQNames | optNoExternals opts = collectAllQNames defs
                | otherwise           = allQNames0

  mMain <- liftIO $ readIORef mainModuleRef
  let entryModule = fmap (prettyShow . fst) mMain

  failed0 <- liftIO $ readIORef failedModulesRef
  let excludes = optExcludeModules opts
      -- Whether a module should appear in the module-level wire output:
      -- composes @--exclude@ with @--no-externals@.
      keep m =  not (isExcludedModule excludes m)
             && not (optNoExternals opts && S.member m externals0)

      -- A failed external is still external: under @--no-externals@ it is
      -- dropped with the rest (and listed in @externals_summary@).
      failedModules = S.filter keep failed0

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

      -- Every visited interface that survives the @--exclude@ /
      -- @--no-externals@ 'keep' filter, with its module name: the one
      -- traversal shape the per-module rollups below share.
      keptIfaces :: [(String, Interface)]
      keptIfaces =
        [ (m, iface)
        | mi <- M.elems visited
        , let iface = miInterface mi
              m     = prettyShow (iTopLevelModuleName iface)
        , keep m
        ]

      -- Per-module flag rollups. The ordering of the hash-keyed survivors
      -- and the drop-empty-rows rule are stated once, so a third such
      -- field cannot diverge from these two. Only the extractor differs —
      -- which puts the two deliberately different SOURCES side by side,
      -- one line each.
      moduleFlagsBy :: (Interface -> [String]) -> [(String, [String])]
      moduleFlagsBy extract = sortOn fst
        [ (m, flags)
        | (m, iface) <- keptIfaces
        , let flags = extract iface
        , not (null flags)
        ]

      -- File-level @{-# OPTIONS #-}@ soundness escapes per visited module.
      -- 'iFilePragmaOptions' (the file's OWN OPTIONS), NOT 'iOptionsUsed'
      -- (folds in CLI + library opts, would misattribute e.g.
      -- @--lenient-imports@ to every module). 'optionEscapes' keeps only
      -- safety-relevant flags. Per-block @NO_POSITIVITY_CHECK@ etc. are
      -- declaration pragmas, not OPTIONS, so never appear here.
      moduleOptionEscapes :: [(String, [String])]
      moduleOptionEscapes =
        moduleFlagsBy (optionEscapes . concatMap pragmaStrings
                                     . iFilePragmaOptions)

      -- The actionability-relevant options actually IN FORCE. 'iOptionsUsed',
      -- the opposite source to 'moduleOptionEscapes' and deliberately so:
      -- @--erasure@ is almost always set in the @.agda-lib@ @flags:@ or on
      -- the command line, and a consumer needs to know whether the @\@0@ its
      -- `erasable` verdicts suggest is even legal here.
      moduleEffectiveOptions :: [(String, [String])]
      moduleEffectiveOptions = moduleFlagsBy (effectiveOptionFlags . iOptionsUsed)

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

  -- Per-module silent-unsolved-meta / unsolved-constraint rollup
  -- (@--allow-unsolved-metas@ only; empty otherwise). Interface markers
  -- cover imported modules; the main module's metas are never postulated,
  -- so its live silent metas are read from TCM state and attributed to the
  -- entry module (under @--keep-going@'s re-drive there is no entry module
  -- and no live check state — the failed module is already in
  -- @failedModules@). Rows where both lists are empty are dropped, so
  -- unsolved-free corpora stay byte-identical.
  ifaceUnsolved <- jsonOnly [] $
    forM keptIfaces $ \(m, iface) -> (,) m <$> unsolvedInterfaceLines iface
  liveMetaLines <- jsonOnly [] liveSilentMetaLines
  let unsolvedModules =
        sortOn fst
          [ row | row@(_, (ms, cs)) <- withLive, not (null ms && null cs) ]
        where
          withLive = case entryModule of
            Just em | not (null liveMetaLines) && keep em ->
              let bump (m, (ms, cs))
                    | m == em   = (m, (sort (liveMetaLines ++ ms), cs))
                    | otherwise = (m, (ms, cs))
              in if any ((== em) . fst) ifaceUnsolved
                   then map bump ifaceUnsolved
                   else (em, (liveMetaLines, [])) : ifaceUnsolved
            _ -> ifaceUnsolved

  positions <- jsonOnly M.empty $ liftIO $ computeQNamePositions allQNames defs

  let gi = GraphInput
        { giDefs             = defs
        , giImportEdges      = importEdges
        , giSourceFiles      = sourceFiles
        , giModuleFile       = moduleFileMap
        , giEntryModule      = entryModule
        , giExternalModules  = externalModules
        , giFailedModules    = failedModules
        , giPositions        = positions
        , giLazy             = lazyTreeOutput opts
        , giExtraModules     = S.empty
        , giReExports        = reExportRows
        , giExternalsSummary = externalsSummary
        , giPackedAnalytical = optPackedAnalytical opts
        , giModuleOptionEscapes = moduleOptionEscapes
        , giModuleEffectiveOptions = moduleEffectiveOptions
        , giUnsolvedModules  = unsolvedModules
        }
      sc = SerialiseCtx (incrementalCacheEnabled opts) cacheDir monoSkippable monoToken

  info "agda-deps: writing output…"
  -- 'hoistedMonoSkip' already ran the deps.json no-op check before the
  -- graph was built; reaching here means it declined, so write.
  liftIO $ writeOutputs opts sc
    (renderDot (optColors opts) failedModules defs) gi

  -- '--incremental': prune fragment files for modules no longer in the
  -- graph. Live set = every module Agda processed this run.
  gcStaleFragments opts cacheDir liveModules

-- | Prune stale fragments after a successful output path. Call sites remain
-- explicit so exceptions do not cause GC as an extra side effect.
gcStaleFragments :: Options -> FilePath -> [String] -> TCM ()
gcStaleFragments opts cacheDir liveModules =
  when (incrementalCacheEnabled opts) $ do
    removed <- gcFragments cacheDir liveModules
    when (removed > 0) $
      info $ "agda-deps: --incremental: pruned " ++ show removed
           ++ " stale fragment(s)."

-- | Compute (x, y) positions per definition QName. Each node id is
-- paired with an integer module id so the grid fallback keeps a
-- module's definitions together. Uses 'hashQName' as the node id.
--
-- @allQNames@ is 'collectAllQNames' output: distinct by 'hashQName', and
-- it contains every def and every dependency, so each edge endpoint is a
-- node and each position pairs back with its QName by list position.
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
      edges =
        [ (hashQName (_name d), hashQName t)
        | d <- defs
        , t <- S.toList (_deps d)
        ]
  positions <- computePositions nodesByMod edges
  return $ M.fromList (zip allQNames positions)

-- | Write the run's output: DOT, the monolithic JSON file, or the
-- @--lazy@ tree, to @-o@ or stdout. The one scrutiny of the output plan,
-- shared with "AgdaDeps.SkipAgda". @--lazy@ without @-o@ already exited in
-- 'checkOutputFlags', so the lazy arm can take the directory as given.
-- @dotText@ is only forced for DOT output.
writeOutputs :: Options -> SerialiseCtx -> TL.Text -> GraphInput -> IO ()
writeOutputs opts sc dotText gi = do
  forM_ (optOutDir opts) (createDirectoryIfMissing True)
  case (optFormat opts, lazyTreeOutput opts, optOutDir opts) of
    (FmtDot, _, Just dir) -> TL.writeFile (dir </> "deps.dot") dotText
    (FmtDot, _, Nothing)  -> TL.putStrLn dotText

    -- '--lazy': a module-level graph.json plus one detail file per
    -- module. Built through 'buildGraphJson' directly so the detail
    -- files come out of the same pass as the skeleton.
    (FmtJson, True, Just dir) -> writeLazyTree dir opts sc (buildGraphJson gi)

    (FmtJson, _, Nothing) -> putStrLn (renderJson (optJsonMode opts) gi)

    -- Plain 'writeFile', not 'writeJsonMaybeGz': --gzip documents itself
    -- as affecting the lazy tree's files only.
    (FmtJson, _, Just dir) -> do
      writeFile (dir </> "deps.json") (renderJson (optJsonMode opts) gi)
      when (scEnabled sc) $
        writeManifest (scCacheDir sc) (optGzip opts)
          (manifestFromList [("deps.json", scMonoToken sc)])

-- | The @--incremental@ serialise-cache context threaded into the output
-- writers. When 'scEnabled' is 'False' the writers behave as the
-- non-incremental path (write everything, no manifest).
data SerialiseCtx = SerialiseCtx
  { scEnabled   :: Bool       -- ^ 'incrementalCacheEnabled'.
  , scCacheDir  :: FilePath   -- ^ where the serialise manifest lives.
  , scMonoSkip  :: Bool       -- ^ enabled && nothing recompiled this run.
  , scMonoToken :: Epoch      -- ^ output-context token ('outputToken').
  }

-- | The cache-disabled context: every file is written, nothing is read,
-- no manifest is kept. For callers with no incremental machinery — see
-- 'AgdaDeps.SkipAgda', which never type-checks and so has nothing to
-- cache against.
noSerialiseCtx :: SerialiseCtx
noSerialiseCtx = SerialiseCtx
  { scEnabled   = False
  , scCacheDir  = ""
  , scMonoSkip  = False
  , scMonoToken = 0
  }

-- | Whether a monolithic @deps.json@ re-emit can be skipped: @skippable@
-- (cache active + nothing recompiled), the file exists, and its manifest
-- slot matches the current @token@. Shared with the up-front
-- 'hoistedMonoSkip' so the two checks can't drift. Needs BOTH the
-- recompiled guard (in @skippable@) and a matching @token@.
monoOutputUnchanged
  :: Bool -> FilePath -> Bool -> String -> Epoch -> FilePath -> IO Bool
monoOutputUnchanged skippable cacheDir gz slot token path
  | not skippable = pure False
  | otherwise = do
      m  <- readManifest cacheDir gz
      ex <- System.Directory.doesFileExist path
      pure (manifestLookup slot m == Just token && ex)

-- | Write the @--lazy@ output tree: a module-level @graph.json@ plus one
-- @modules\/\<Module\>.json@ detail file per module.
--
-- Under @--incremental@ every file is rewritten only when it changed,
-- and a skipped file never forces its (lazy) content thunk — which is
-- the point of 'ModuleDetailJson' carrying a cheap 'mdjEpoch' beside
-- 'mdjContent'.
--
-- That includes the skeleton. @graph.json@ is not small: with 'giLazy'
-- only the @defs@ \/ @edges@ blobs move out, so it still carries the
-- per-module trees, the pod layout, the @moduleFiles@ manifest and —
-- unconditionally — @searchIndex@, i.e. every definition name in the
-- corpus plus its bigrams. Measured at ~630 bytes per module, which is
-- tens of megabytes of 'String' to re-materialise on a corpus large
-- enough to want @--lazy@ in the first place. So it takes the same
-- monolithic no-op check @deps.json@ gets, against its own manifest
-- slot; on an unchanged rebuild its thunk is never forced at all.
writeLazyTree
  :: FilePath -> Options -> SerialiseCtx
  -> GraphJsonOutput  -- ^ from 'buildGraphJson' with @giLazy = True@
  -> IO ()
writeLazyTree dir opts sc gjo = do
  let gz        = optGzip opts
      skeleton  = dir </> "graph.json"
      graphSlot = "graph.json"

  oldManifest <-
    if scEnabled sc then readManifest (scCacheDir sc) gz else pure mempty

  skeletonCurrent <-
    if scMonoSkip sc && manifestLookup graphSlot oldManifest == Just (scMonoToken sc)
      then fileCurrent gz skeleton
      else pure False
  if skeletonCurrent
    then info "agda-deps: --incremental: graph.json unchanged; skipped re-emit."
    else writeJsonMaybeGz gz skeleton (gjoGraphJson gjo)

  let details    = gjoModuleDetails gjo
      modulesDir = dir </> "modules"
  unless (null details) $ createDirectoryIfMissing True modulesDir

  -- Without the cache every file is written and no epoch is computed.
  if scEnabled sc
    then do
      detailEntries <- mapM (writeDetail gz oldManifest modulesDir) details
      writeManifest (scCacheDir sc) gz
        (manifestFromList ((graphSlot, scMonoToken sc) : detailEntries))
    else forM_ details $ \md ->
      writeJsonMaybeGz gz (modulesDir </> mdjFileName md) (mdjContent md)
  where
    -- Whether a file (and its .gz sibling, if gzip) is already on disk.
    fileCurrent :: Bool -> FilePath -> IO Bool
    fileCurrent gz full = do
      a <- System.Directory.doesFileExist full
      if not gz then pure a
                else (a &&) <$> System.Directory.doesFileExist (full ++ ".gz")

    -- The returned pair is forced before it is handed back: leaving it
    -- as thunks over @md@ would keep every 'ModuleDetailJson' — and so
    -- every rendered detail 'String' — reachable until the fold ends,
    -- which is the opposite of what @--lazy@ is for.
    writeDetail
      :: Bool -> Manifest -> FilePath -> ModuleDetailJson -> IO (String, Epoch)
    writeDetail gz oldM destDir md = do
      let !fname = mdjFileName md
          !epoch = mdjEpoch md
          !slot  = "modules/" ++ fname
          full   = destDir </> fname
      uptodate <- if manifestLookup slot oldM == Just epoch
                    then fileCurrent gz full else pure False
      unless uptodate $ writeJsonMaybeGz gz full (mdjContent md)
      pure $! (slot, epoch)

-- | Write a JSON file at @path@, and (when @gz@ is set) a gzip-compressed
-- @path.gz@ sibling. The text is UTF-8 encoded once and both files are
-- written from those bytes, so the @.gz@ decompresses to exactly the
-- @.json@ (names may be non-ASCII: 'jsString' passes them through).
writeJsonMaybeGz :: Bool -> FilePath -> String -> IO ()
writeJsonMaybeGz gz path content = do
  let bytes = TLE.encodeUtf8 (TL.pack content)
  BL.writeFile path bytes
  when gz $ BL.writeFile (path ++ ".gz") (GZip.compress bytes)

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
  isUnderRoot <- underCwd
  let -- Per-module flag: at least one signal lands at an in-root source
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
       in withDependencyProvenance prov' d
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

-- | Scan an Agda source file for @private@ blocks and return their
-- (inclusive) line ranges.
--
-- A line whose first word is @private@, at indentation @k@, begins a
-- block whose body is every following line indented deeper than @k@ —
-- Agda's layout rule — so it ends at the next sibling declaration (a
-- line at indentation @<= k@). Blank lines never end a block. This covers
-- @private@ inside sub-modules and @where@ blocks as well as top level.
-- (Agda's interfaces cannot answer this: it drops private names from the
-- serialised scope, so the source text is the only record left.)
--
-- Read as strict bytes: every test is on ASCII characters, and the whole
-- file is consumed (and its handle closed) before the next is opened. A
-- trailing @\\r@ is dropped per line, as text-mode reading does for CRLF
-- files on Windows.
findPrivateRanges :: FilePath -> IO [(Int, Int)]
findPrivateRanges fp = do
  exists <- System.Directory.doesFileExist fp
  if not exists
    then return []
    else do
      ls <- map (BSC.dropWhileEnd (== '\r')) . BSC.lines <$> BS.readFile fp
      let indexed = zip [1 :: Int ..] ls
      return $ go indexed []
  where
    -- Accumulates ranges in reverse; order doesn't matter for the
    -- membership test the caller does.
    go [] acc = acc
    go ((n, ln) : rest) acc
      | Just k <- privateHeaderIndent ln =
          let (body, after) = span (\(_, l) -> isBlank l || indent l > k) rest
              endLine = case body of
                ((_, _) : _) -> fst (last body)
                []           -> n
          in go after ((n, endLine) : acc)
      | otherwise = go rest acc

    -- The indentation of a line whose first word is the @private@ keyword.
    privateHeaderIndent s =
      let k = indent s
          w = BS.drop k s
      in if w == BSC.pack "private" || BSC.pack "private " `BS.isPrefixOf` w
           then Just k else Nothing

    isWhite c = c == ' ' || c == '\t'
    indent    = BS.length . BSC.takeWhile isWhite
    isBlank   = BSC.all isWhite

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
     , let qn = anameName an
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
