{-# LANGUAGE CPP #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Partial-compilation support: walks Agda's loaded-module table on
-- behalf of a backend to emit a partial graph rather than no output.
--
-- 'partialBackendInteraction' replaces 'backendInteraction': it checks the
-- entry and discovered roots independently, reports failures via
-- @reportFailed@, and captures accepted interfaces before resetting per-file
-- state. Each backend then extracts one graph from all successfully loaded
-- modules.
--
-- 'partialCompilerMain' re-seeds @stVisitedModules@ from
-- @stDecodedModules@, re-merges each decoded interface's import state
-- ('mergeIfaceState'), then runs @preModule@ \/ @compileDef@ \/
-- @postModule@ per module and hands the results to @postCompile@.
--
-- Every stage is guarded ('catchAllTCM'): a broken definition/module/
-- interface-merge is dropped and @postCompile@ runs regardless, so a
-- graph is always emitted. Unskippable stages print a diagnostic before
-- re-throwing, so an abort is never a bare exit code.
--
-- The module's only side effect is the @reportFailed@ callback.
module AgdaDeps.ModuleExplorer
  ( -- * Driver entry point
    runPartial

    -- * Lower-level pieces
  , partialBackendInteraction
  , partialCompilerMain

    -- * Diagnostics
  , failingModuleName
  ) where

import qualified Control.Exception as E
import Control.Monad ( foldM, forM_, when )
import Control.Monad.Except ( catchError, runExceptT, ExceptT(..) )
import Control.Monad.IO.Class ( liftIO )

import Data.Either ( partitionEithers )
import qualified Data.Map.Strict as Map
import Data.Maybe ( catMaybes, fromMaybe )
import qualified Agda.Utils.Maybe.Strict as SM
#if MIN_VERSION_Agda(2,9,0)
-- Strict-pair (':!:') to destructure @stCurrentModule@; 2.8 uses a lazy @Maybe@.
import Agda.Utils.Tuple.Strict ( Pair(..) )
#endif

import System.Environment ( getArgs, getProgName )
import System.Exit ( ExitCode )
import System.IO ( hPutStrLn, stderr )

import Agda.Compiler.Backend
  ( Backend, Backend_boot(Backend)
  , Backend'
  , Recompile(..)
  , parseBackendOptions
  , preCompile, postCompile, preModule, postModule, compileDef
  , backendName, options
  )
import qualified Agda.Compiler.Backend as ACB
import Agda.Compiler.Common ( setInterface, curDefs, sortDefs )
import Agda.Interaction.Imports ( crModuleInfo )

import Agda.Interaction.Options
  ( defaultOptions, runOptM, optInputFile, optCompileNoMain, pragmaOptions )

import Agda.Main
  ( runAgdaWithOptions, optionError, runTCMPrettyErrors
  , runAgda )

import Agda.Syntax.Builtin ( someBuiltin )
import Agda.Syntax.Common ( IsMain(..) )
import Agda.Syntax.Common.Pretty ( prettyShow )
import Agda.Syntax.Position ( getRange, rangeFile, RangeFile(..) )
import Agda.Syntax.TopLevelModuleName ( TopLevelModuleName )

import Agda.Utils.FileName ( AbsolutePath, absolute, filePath )

import Agda.TypeChecking.Errors ( prettyError )
import Agda.TypeChecking.Monad
  ( TCM, TCErr, useTC, locallyTC
#if MIN_VERSION_Agda(2,9,0)
  , setSession, lensBackends
#else
  , stBackends
#endif
  , setCurrentRange, defName
  , modifyTCLens', setTCLens'
  )
import Agda.TypeChecking.Monad.Base
  ( stCurrentModule, eActiveBackendName
  , Interface, iTopLevelModuleName, iModuleName, iSignature
  , ModuleInfo(..), ModuleCheckMode(..)
  , stImports, stSignature, emptySignature
  -- Import-state lenses + interface fields for 'mergeIfaceState'.
  , stImportedBuiltins, stImportedMetaStore
  , stPatternSynImports, stImportedDisplayForms
  , iBuiltin, iMetaBindings, iPatternSyns, iDisplayForms
  , Builtin(..), PrimitiveImpl(..), primFunName
  -- TCM newtype access for 'catchAllTCM'.
#if MIN_VERSION_Agda(2,9,0)
  , pattern TCM, unTCM
#else
  , TCMT(TCM, unTCM)
#endif
  )
#if MIN_VERSION_Agda(2,9,0)
import Agda.TypeChecking.Monad.Base ( Signature(Sig) )
#else
import Agda.TypeChecking.Monad.Signature ( unionSignature )
#endif
import Agda.TypeChecking.Primitive.Base ( lookupPrimitiveFunction )
import qualified Data.HashMap.Strict as HMap
import Agda.TypeChecking.Monad.Imports
  ( getDecodedModules, setDecodedModules, visitModule )
import Agda.TypeChecking.Monad.State ( resetState, getSignature )
import Agda.TypeChecking.Monad.Env ( withCurrentModule )
import Agda.TypeChecking.MetaVars ( openMetasToPostulates )
import Agda.TypeChecking.Reduce ( instantiateFull )

import AgdaDeps.Logging ( info )

-- ** Driver entry point

-- | Independently check the entry and supplied sources before running the
-- backend once. Optional scanned names are diagnostic fallbacks. With no
-- source file in argv (e.g. @--help@), the standard 'runAgda' path takes over.
-- @reportFailed@ records failed roots and imports for @postCompile@.
runPartial
  :: [(Maybe String, FilePath)]
  -> (String -> IO ())  -- ^ @reportFailed modName@
  -> [Backend]
  -> IO ()
runPartial sources reportFailed backends = do
  progName <- getProgName
  argv     <- getArgs
  let (parsed, _warns) = runOptM $ parseBackendOptions backends argv defaultOptions
  conf <- runExceptT $ do
    (bs, opts) <- ExceptT $ pure parsed
    inputFile  <- liftIO $ mapM absolute $ optInputFile opts
    pure (bs, opts, inputFile)
  case conf of
    Left err -> optionError err
    Right (_, _, Nothing) ->
      runAgda backends
    Right (bs, opts, Just file) ->
      runTCMPrettyErrors $ do
#if MIN_VERSION_Agda(2,9,0)
        setSession lensBackends bs
#else
        -- Agda 2.8 has no @setSession@; set the session lens directly.
        setTCLens' stBackends bs
#endif
        targets <- liftIO $ mapM (\(m, p) -> (,) m <$> absolute p) sources
        runAgdaWithOptions
          (partialBackendInteraction reportFailed file targets bs)
          progName
          opts

-- | Reset per-file scopes, options and metas between checks, preserving
-- Agda's persistent interface cache. A failure can still have loaded healthy
-- imports, which are kept. Successfully checked roots are retained separately:
-- Agda does not cache every main interface (notably roots with warnings), and
-- their live state must be captured before the next reset.
partialBackendInteraction
  :: (String -> IO ()) -> AbsolutePath -> [(Maybe String, AbsolutePath)]
  -> [Backend] -> TCM () -> (AbsolutePath -> TCM ACB.CheckResult) -> TCM ()
partialBackendInteraction reportFailed mainFile targets backends setup check = do
  initial <- guardCheck reportFailed setup
  case initial of
    Left () -> sequence_ [ partialCompilerMain Nothing b NotMain | Backend b <- backends ]
    Right () -> do
      let mainName = lookup mainFile [ (p, m) | (m, p) <- targets ]
          files = (fromMaybe Nothing mainName, mainFile)
                : [ t | t@(_, p) <- targets, p /= mainFile ]
      (roots, entry) <- foldM checkOne (Map.empty, Nothing) files
      decoded <- getDecodedModules
      -- Enriched root interfaces take precedence over their pruned cached
      -- copies. They are used for extraction only, after checking has ended.
      resetState
      orDiagnose "setup before extraction" setup
      setDecodedModules $ Map.filter ((== ModuleTypeChecked) . miMode)
                        $ Map.union roots decoded
      sequence_ [ partialCompilerMain entry b IsMain | Backend b <- backends ]
  where
    namesByPath = Map.fromList [ (filePath p, m) | (Just m, p) <- targets ]
    checkOne (roots, entry) (name, path) = do
      info $ "agda-deps: --keep-going: checking " ++ filePath path
      let report m = do
            -- The requested root also failed to check when an import failed.
            -- Record it even when Agda has no current-module error range.
            forM_ name reportFailed
            when (m /= "<unknown>" || name == Nothing) $
              reportFailed $ Map.findWithDefault m m namesByPath
      -- Reset outside catchError: its rollback must not restore the previous
      -- successful root as the "current module" when diagnosing this file.
      resetState
      checked <- guardCheck report $ do
        setup
        result <- check path
        noMain <- optCompileNoMain <$> pragmaOptions
        mi <- captureCheckedRoot (crModuleInfo result)
        return (mi, noMain)
      case checked of
        Left () -> return (roots, entry)
        Right (mi, noMain) -> do
          let m = iTopLevelModuleName (miInterface mi)
              entry' | path == mainFile && not noMain = Just m
                     | otherwise = entry
          return (Map.insert m mi roots, entry')

-- | Make accepted root data independent of its live TCM state. Freezing
-- remaining metas is the same representation Agda uses for imported hole
-- modules; it does not enable permissive checking or change --safe. Keep the
-- full local signature so cold root checks do not lose dead private defs.
captureCheckedRoot :: ModuleInfo -> TCM ModuleInfo
captureCheckedRoot mi = do
  let iface = miInterface mi
  withCurrentModule (iModuleName iface) openMetasToPostulates
  fullSig <- getSignature
  let sig = unionSignature fullSig (iSignature iface)
  iface' <- instantiateFull iface{ iSignature = sig }
  return mi{ miInterface = iface' }

guardCheck :: (String -> IO ()) -> TCM a -> TCM (Either () a)
guardCheck reportFailed act =
  ((Right <$> act)
     `catchError` \ err -> Left <$> handleCheckError reportFailed err)
    `catchAllTCM` \ ex -> Left <$> handleCheckException reportFailed ex

-- ** Exception plumbing

-- | Catch-everything guard for the best-effort partial pass. Needed over
-- 'catchError', which catches only 'TCErr': Agda internals also throw GHC
-- exceptions (@__IMPOSSIBLE__@, exit 120). Catches both, re-throwing only
-- 'ExitCode' + async. State is NOT rolled back (unlike 'catchError'), so
-- the handler continues from the failure point — the next 'setInterface'
-- re-establishes per-module state.
catchAllTCM :: TCM a -> (E.SomeException -> TCM a) -> TCM a
catchAllTCM m h = TCM $ \ r e ->
  unTCM m r e `E.catches`
    [ E.Handler $ \ (ex :: ExitCode)         -> E.throwIO ex
    , E.Handler $ \ (ex :: E.AsyncException) -> E.throwIO ex
    , E.Handler $ \ (ex :: E.SomeException)  -> unTCM (h ex) r e
    ]

-- | First line of an exception's rendering, for one-line breadcrumbs.
exceptionLine :: E.SomeException -> String
exceptionLine = takeWhile (/= '\n') . E.displayException

-- | Run @act@; on any synchronous exception print a one-line
-- diagnostic naming @stage@ and return @fallback@.
bestEffort :: String -> a -> TCM a -> TCM a
bestEffort stage fallback act = act `catchAllTCM` \ ex -> do
  liftIO $ hPutStrLn stderr $
    "agda-deps: --keep-going: " ++ stage ++ " failed ("
    ++ exceptionLine ex ++ "); continuing best-effort."
  return fallback

-- | Run @act@; on failure print a diagnostic naming @stage@ and
-- re-throw. For the stages that cannot be skipped (preCompile /
-- postCompile), so an abort is never a silent exit code.
orDiagnose :: String -> TCM a -> TCM a
orDiagnose stage act = act `catchAllTCM` \ ex -> do
  liftIO $ hPutStrLn stderr $
    "agda-deps: --keep-going: FATAL: " ++ stage ++ " failed: "
    ++ exceptionLine ex
  liftIO $ E.throwIO ex

handleCheckError :: (String -> IO ()) -> TCErr -> TCM ()
handleCheckError reportFailed err = do
  modName <- failingModuleName err
  msg <- (prettyShow <$> prettyError err)
           `catchError` \_ -> return (show err)
  reportCheckFailure reportFailed modName msg

-- | Like 'handleCheckError' for non-'TCErr' exceptions: there is no
-- source range to fall back to, so the failing module is whatever
-- @stCurrentModule@ holds.
handleCheckException :: (String -> IO ()) -> E.SomeException -> TCM ()
handleCheckException reportFailed ex = do
  modName <- fromMaybe "<unknown>" <$> currentModuleName
  reportCheckFailure reportFailed modName
    ("(non-TCErr exception) " ++ E.displayException ex)

reportCheckFailure :: (String -> IO ()) -> String -> String -> TCM ()
reportCheckFailure reportFailed modName msg = do
  liftIO $ do
    reportFailed modName
    hPutStrLn stderr $
      "agda-deps: --keep-going: tagging '" ++ modName ++ "' as Failed:"
    mapM_ (hPutStrLn stderr . ("  " ++)) (lines msg)
  decoded <- getDecodedModules
  info $
    "agda-deps: --keep-going: " ++ show (Map.size decoded)
    ++ " module(s) loaded successfully before the failure."

-- | The module Agda was busy with, per @stCurrentModule@ — 'Nothing'
-- when no module was in progress.
currentModuleName :: TCM (Maybe String)
currentModuleName = do
  mCur <- useTC stCurrentModule
  case mCur of
#if MIN_VERSION_Agda(2,9,0)
    SM.Just (_ :!: tlmn) -> return (Just (prettyShow tlmn))
    SM.Nothing           -> return Nothing
#else
    -- Agda 2.8: @stCurrentModule@ is a lazy @Maybe (ModuleName, _)@.
    Just (_, tlmn)       -> return (Just (prettyShow tlmn))
    Nothing              -> return Nothing
#endif

-- | Pick the best identifier for the module that failed:
-- @stCurrentModule@ when set (Agda's \"current module\" at the time of
-- the error), otherwise the error's source range, otherwise
-- @\<unknown\>@.
failingModuleName :: TCErr -> TCM String
failingModuleName err =
  fromMaybe (moduleFromRange err) <$> currentModuleName

moduleFromRange :: TCErr -> String
moduleFromRange err =
  case rangeFile (getRange err) of
    SM.Just rf -> case rangeFileName rf of
      Just tlm -> prettyShow tlm
      Nothing  -> filePath (rangeFilePath rf)
    SM.Nothing -> "<unknown>"

-- | Like 'ACB.compilerMain' but doesn't require a 'CheckResult'.
--
-- Walks every loaded interface and runs the backend's per-module hooks
-- ('preModule' → 'compileDef' → 'postModule'). Each definition, module,
-- and interface merge is 'catchAllTCM'-guarded, so a broken piece is
-- skipped rather than aborting the pass — 'postCompile' always runs.
partialCompilerMain
  :: Maybe TopLevelModuleName -> Backend' opts env menv mod def -> IsMain -> TCM ()
partialCompilerMain entry backend isMain =
  locallyTC eActiveBackendName (const $ Just $ backendName backend) $ do
    decoded <- getDecodedModules
    let mis    = Map.elems decoded
        ifaces = map miInterface mis
    -- Seed stVisitedModules from stDecodedModules; 'postCompile' reads it
    -- to derive module-level import edges.
    bestEffort "re-seeding visited modules" () $
      mapM_ visitModule mis
    -- Rebuild the rollback-wiped import state, and clear 'stSignature' so
    -- a qname present in both the stale current signature and the merged
    -- imports doesn't trip Agda's ambiguous-name check.
    setTCLens' stSignature emptySignature
    forM_ ifaces $ \ iface ->
      bestEffort
        ("merging interface '" ++ prettyShow (iTopLevelModuleName iface) ++ "'")
        ()
        (mergeIfaceState iface)
    env <- orDiagnose "preCompile" $ preCompile backend (options backend)
    modResults <- foldM (perModule env) Map.empty ifaces
    liftIO $ info $
      "agda-deps: --keep-going: emitted def-level data for "
      ++ show (Map.size modResults) ++ "/" ++ show (Map.size decoded)
      ++ " loaded module(s)."
    orDiagnose "postCompile (no output written)" $
      postCompile backend env isMain modResults
  where
    perModule env acc iface = do
      let tlmn = iTopLevelModuleName iface
      -- The entry is known only when checking the command-line root succeeded.
      let moduleIsMain | entry == Just tlmn = isMain
                       | otherwise = NotMain
      mRes <- (Just <$> compileOneModule backend env moduleIsMain iface)
                `catchAllTCM` \ ex -> do
                  reportSkippedModule tlmn (exceptionLine ex)
                  return Nothing
      return $ case mRes of
        Just r  -> Map.insert tlmn r acc
        Nothing -> acc

-- | Re-create what importing a module normally adds to the TCM state.
-- 'catchError' rolls the whole 'TCState' back (only @stDecodedModules@
-- survives), so rebuild the import state from the decoded interfaces.
-- The signature alone is NOT enough: builtins (else @infallibleSortKit@
-- dies under @--with-signatures@), display forms + pattern synonyms (for
-- @prettyTCM@), and the remote meta store (for hole classification) all
-- matter. Mirrors @mergeInterface@\/@addImportedThings@ minus the
-- duplicate-builtin and confluence checks.
mergeIfaceState :: Interface -> TCM ()
mergeIfaceState iface = do
  mergeIfaceSig iface
  -- 'iBuiltin' stores 'Prim' as (PrimitiveId, QName); 'stImportedBuiltins'
  -- wants the looked-up 'PrimFun' with the name rebound to the interface's
  -- QName, as 'mergeInterface' does.
  let (prims, plain) = partitionEithers
        [ case b of
            Prim x                     -> Left x
            Builtin t                  -> Right (k, Builtin t)
            BuiltinRewriteRelations xs -> Right (k, BuiltinRewriteRelations xs)
        | (k, b) <- Map.toAscList (iBuiltin iface) ]
  modifyTCLens' stImportedBuiltins
    (`Map.union` Map.fromDistinctAscList plain)
  modifyTCLens' stImportedMetaStore   (`HMap.union` iMetaBindings iface)
  modifyTCLens' stPatternSynImports   (`Map.union` iPatternSyns iface)
  modifyTCLens' stImportedDisplayForms $ \ imp ->
    HMap.unionWith (<>) imp (iDisplayForms iface)
  -- Each rebind guarded: 'lookupPrimitiveFunction' can throw for prims
  -- gated behind a language option inactive outside the defining module's
  -- pragmas (e.g. NeedOptionCubical). Routine, so breadcrumb to info.
  forM_ prims $ \ (x, q) ->
    ( do PrimImpl _ pf <- lookupPrimitiveFunction x
         modifyTCLens' stImportedBuiltins $
           Map.insert (someBuiltin x) (Prim pf{ primFunName = q })
    ) `catchAllTCM` \ ex ->
      info $
        "agda-deps: --keep-going: skipping primitive rebind for '"
        ++ prettyShow q ++ "' (" ++ exceptionLine ex ++ ")"

-- | Merge a single interface's 'Signature' into the persistent 'stImports'
-- one, so downstream lookups across the partial graph succeed.
--
-- Delegate to 'unionSignature' — what 'addImportedThings' uses, the function
-- this pass mirrors (2.8 exports it; on 2.9 it is mirrored locally just below)
-- — rather than merging chosen fields. All four must
-- arrive, and two need accumulating semantics a plain union cannot express
-- (rewrite rules @unionWith mappend@, instances @(<>)@). Dropping one is
-- silent rather than fatal: 'lookupSection' returns 'EmptyTel' for an
-- unknown module, so a missing 'sigSections' turns every section-telescope
-- measurement into a wrong number with no error — see
-- 'AgdaDeps.Deps.argUsageOf'. Pinned by @test-keepgoing/Good.agda@'s
-- @withHelper@\/@helper@ pair.
mergeIfaceSig :: Interface -> TCM ()
mergeIfaceSig iface =
  modifyTCLens' stImports $ \ imp -> unionSignature imp (iSignature iface)

#if MIN_VERSION_Agda(2,9,0)
-- | 2.9 has no exported signature union: @unionSignature@ is gone from
-- @Monad.Signature@ and its successor @importSignature@ is private to
-- @Interaction.Imports@. So mirror 2.8's, field for field, with the same
-- per-field semantics.
--
-- The pattern is exhaustive on purpose: a fifth 'Sig' field must break this
-- build rather than be silently dropped, which is the exact failure mode
-- 'mergeIfaceSig' exists to prevent. Not mirrored: 2.9's @importSignature@
-- additionally replays rewrite-rule adjustments over the merged definitions
-- (its @fixupDefs@). 2.8's @unionSignature@ does not either, and this pass
-- reads sections/definitions rather than reducing with rewrite rules.
unionSignature :: Signature -> Signature -> Signature
unionSignature (Sig a b c d) (Sig a' b' c' d') =
  Sig (Map.union a a')
      (HMap.union b b')             -- definitions are unique to one module
      (HMap.unionWith mappend c c') -- rewrite rules are accumulated
      (d <> d')                     -- instances are accumulated
#endif

reportSkippedModule :: TopLevelModuleName -> String -> TCM ()
reportSkippedModule tlmn reason =
  liftIO $ hPutStrLn stderr $
    "agda-deps: --keep-going: skipping def-level recovery for '"
    ++ prettyShow tlmn ++ "': " ++ reason

-- | Per-module driver: replicates 'Agda.Compiler.Backend.compileModule'
-- without the 'inCompilerEnv' wrapper (its output-dir \/ scope setup is
-- unneeded for a backend emitting no artifacts). 'setInterface'
-- establishes 'stCurrentModule', merges pragma options, and re-seeds
-- 'stImportedModules' so 'preModule' hooks reading 'curIF' see the right
-- interface. Each definition is individually guarded, so one that throws
-- is dropped with a breadcrumb instead of losing the whole module.
compileOneModule
  :: Backend' opts env menv mod def
  -> env -> IsMain -> Interface -> TCM mod
compileOneModule backend env isMain iface = do
  setInterface iface
  let tlmn = iTopLevelModuleName iface
  r <- preModule backend env isMain tlmn Nothing
  case r of
    Skip m         -> return m
    Recompile menv -> do
      defs <- map snd . sortDefs <$> curDefs
      res  <- catMaybes <$> mapM (compileOne menv) defs
      postModule backend env menv isMain tlmn res
  where
    compileOne menv d =
      (Just <$> (setCurrentRange (defName d) $
                   compileDef backend env menv isMain d))
        `catchAllTCM` \ ex -> do
          liftIO $ hPutStrLn stderr $
            "agda-deps: --keep-going: skipping definition '"
            ++ prettyShow (defName d) ++ "' (" ++ exceptionLine ex ++ ")"
          return Nothing
