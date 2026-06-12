{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Partial-compilation support: walks Agda's loaded-module table on
-- behalf of a backend.
--
-- 'partialBackendInteraction' replaces Agda's standard
-- 'Agda.Compiler.Backend.backendInteraction': it catches a 'TCErr'
-- from @check mainFile@, reports the failing module's name via the
-- @reportFailed@ callback, and drives each backend's hooks manually
-- over whatever modules Agda did load. The result is a partial
-- dependency graph rather than no output.
--
-- 'partialCompilerMain' re-seeds @stVisitedModules@ from the
-- persistent @stDecodedModules@ and merges each decoded interface's
-- signature into @stImports@, then runs @preModule@ \/ @compileDef@ \/
-- @postModule@ per module and hands the results to @postCompile@.
--
-- The module knows nothing about argv, options, or @agda-deps@ itself;
-- its only side effect is the @reportFailed@ callback.
module AgdaDeps.ModuleExplorer
  ( -- * Driver entry point
    runPartial

    -- * Lower-level pieces
  , partialBackendInteraction
  , partialCompilerMain

    -- * Diagnostics
  , failingModuleName
  ) where

import Control.Monad ( foldM )
import Control.Monad.Except ( catchError, runExceptT, ExceptT(..) )
import Control.Monad.IO.Class ( liftIO )

import qualified Data.Map.Strict as Map
import qualified Agda.Utils.Maybe.Strict as SM
#if MIN_VERSION_Agda(2,9,0)
-- Brings the strict-pair constructor (':!:') used to destructure
-- @stCurrentModule@; Agda 2.8 stores a lazy @Maybe (_, _)@ instead.
import Agda.Utils.Tuple.Strict ( Pair(..) )
#endif

import System.Environment ( getArgs, getProgName )
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

import Agda.Interaction.Options
  ( defaultOptions, runOptM, optInputFile, optCompileNoMain, pragmaOptions )

import Agda.Main
  ( runAgdaWithOptions, optionError, runTCMPrettyErrors
  , runAgda )

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
  , modifyTCLens, setTCLens'
  )
import Agda.TypeChecking.Monad.Base
  ( stCurrentModule, eActiveBackendName
  , Interface, iTopLevelModuleName, iSignature, miInterface
  , stImports, stSignature, emptySignature
  , sigDefinitions
  )
import qualified Data.HashMap.Strict as HMap
import Agda.Utils.Lens ( over, (^.) )
import Agda.TypeChecking.Monad.Imports ( getDecodedModules, visitModule )

import AgdaDeps.Logging ( info )

-- ** Driver entry point

-- | Drop-in for @Agda.Main.runAgdaArgs@ that uses the partial-compile
-- interactor. When argv carries no source file (e.g. @--help@,
-- @--version@) the standard 'runAgda' path takes over via the
-- 'Nothing' branch.
--
-- @reportFailed@ is invoked once per @check mainFile@ failure with the
-- name of the module Agda was busy checking when the error fired. The
-- callback should record the name somewhere the backend can read in its
-- @postCompile@ hook.
runPartial
  :: (String -> IO ())  -- ^ @reportFailed modName@
  -> [Backend]
  -> IO ()
runPartial reportFailed backends = do
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
        runAgdaWithOptions
          (partialBackendInteraction reportFailed file bs)
          progName
          opts

-- ** Backend interaction

-- | Variant of 'Agda.Compiler.Backend.backendInteraction' that catches
-- type-check errors. On success it dispatches to the standard
-- 'ACB.compilerMain' for every backend; on failure it tags the module
-- that was in progress via @reportFailed@ and runs each backend's hooks
-- manually over whatever modules Agda DID load before the error.
partialBackendInteraction
  :: (String -> IO ())
  -> AbsolutePath -> [Backend]
  -> TCM () -> (AbsolutePath -> TCM ACB.CheckResult) -> TCM ()
partialBackendInteraction reportFailed mainFile backends setup check = do
  -- Wrap both 'setup' and 'check mainFile' in catchError so that
  -- library / pragma / option errors firing before 'check mainFile'
  -- starts are caught too.
  setupResult <- (Right <$> setup)
                   `catchError` \err -> Left <$> handleCheckError reportFailed err
  result <- case setupResult of
    Left err -> return (Left err)
    Right () -> (Right <$> check mainFile)
                  `catchError` \err -> Left <$> handleCheckError reportFailed err
  noMain <- optCompileNoMain <$> pragmaOptions
  let isMain | noMain    = NotMain
             | otherwise = IsMain
  case result of
    Right checkResult ->
      -- Agda's own dispatcher: looks the backend up in stBackends and
      -- runs the private 'compilerMain'.
      sequence_ [ ACB.callBackend (backendName b) isMain checkResult
                | Backend b <- backends ]
    Left _err ->
      sequence_ [ partialCompilerMain b isMain
                | Backend b <- backends ]

handleCheckError :: (String -> IO ()) -> TCErr -> TCM TCErr
handleCheckError reportFailed err = do
  modName <- failingModuleName err
  msg <- (prettyShow <$> prettyError err)
           `catchError` \_ -> return (show err)
  liftIO $ do
    reportFailed modName
    hPutStrLn stderr $
      "agda-deps: --keep-going: tagging '" ++ modName ++ "' as Failed:"
    mapM_ (hPutStrLn stderr . ("  " ++)) (lines msg)
  decoded <- getDecodedModules
  info $
    "agda-deps: --keep-going: " ++ show (Map.size decoded)
    ++ " module(s) loaded successfully before the failure."
  return err

-- | Pick the best identifier for the module that failed:
-- @stCurrentModule@ when set (Agda's \"current module\" at the time of
-- the error), otherwise the error's source range, otherwise
-- @\<unknown\>@.
failingModuleName :: TCErr -> TCM String
failingModuleName err = do
  mCur <- useTC stCurrentModule
  case mCur of
#if MIN_VERSION_Agda(2,9,0)
    SM.Just (_ :!: tlmn) -> return (prettyShow tlmn)
    SM.Nothing           -> return (moduleFromRange err)
#else
    -- Agda 2.8: @stCurrentModule@ is a lazy @Maybe (ModuleName, _)@.
    Just (_, tlmn)       -> return (prettyShow tlmn)
    Nothing              -> return (moduleFromRange err)
#endif

moduleFromRange :: TCErr -> String
moduleFromRange err =
  case rangeFile (getRange err) of
    SM.Just rf -> case rangeFileName rf of
      Just tlm -> prettyShow tlm
      Nothing  -> filePath (rangeFilePath rf)
    SM.Nothing -> "<unknown>"

-- | Like 'ACB.compilerMain' but doesn't require a 'CheckResult'.
--
-- Walks every loaded interface and calls the backend's per-module
-- hooks ('preModule' → 'compileDef' → 'postModule') in turn. Each
-- module is wrapped in 'catchError' so a single broken module is
-- skipped (with a stderr breadcrumb) rather than aborting the rest of
-- the partial pass. The accumulated per-module results are handed to
-- 'postCompile'.
partialCompilerMain
  :: Backend' opts env menv mod def -> IsMain -> TCM ()
partialCompilerMain backend isMain =
  locallyTC eActiveBackendName (const $ Just $ backendName backend) $ do
    -- Seed stVisitedModules from the persistent stDecodedModules, which
    -- the backend's 'postCompile' hook reads to derive module-level
    -- import edges.
    decoded <- getDecodedModules
    mapM_ visitModule (Map.elems decoded)
    -- Merge every decoded interface's signature into 'stImports' (the
    -- normal pipeline does this incrementally per import), and clear
    -- 'stSignature' so a qname present in both the stale current
    -- signature and the merged imports does not trip Agda's
    -- ambiguous-name check.
    let ifaces = map miInterface (Map.elems decoded)
        nMods  = length ifaces
    setTCLens' stSignature emptySignature
    mapM_ mergeIfaceSig ifaces
    env <- preCompile backend (options backend)
    modResults <- foldM (perModule env) Map.empty ifaces
    liftIO $ info $
      "agda-deps: --keep-going: emitted def-level data for "
      ++ show (Map.size modResults) ++ "/" ++ show nMods
      ++ " loaded module(s)."
    postCompile backend env isMain modResults
  where
    perModule env acc iface = do
      let tlmn = iTopLevelModuleName iface
      mRes <- (Just <$> compileOneModule backend env isMain iface)
                `catchError` \err -> do
                  reportSkippedModule tlmn err
                  return Nothing
      return $ case mRes of
        Just r  -> Map.insert tlmn r acc
        Nothing -> acc

-- | Merge a single interface's 'Definitions' into the persistent
-- 'stImports' signature so that downstream 'getConstInfo' lookups
-- across the partial graph succeed.
mergeIfaceSig :: Interface -> TCM ()
mergeIfaceSig iface = do
  let sig = iSignature iface
      defs = sig ^. sigDefinitions
  modifyTCLens stImports $ over sigDefinitions (HMap.union defs)

reportSkippedModule :: TopLevelModuleName -> TCErr -> TCM ()
reportSkippedModule tlmn err = do
  msg <- (prettyShow <$> prettyError err)
           `catchError` \_ -> return (show err)
  let firstLine = takeWhile (/= '\n') msg
  liftIO $ hPutStrLn stderr $
    "agda-deps: --keep-going: skipping def-level recovery for '"
    ++ prettyShow tlmn ++ "': " ++ firstLine

-- | Per-module driver: replicates 'Agda.Compiler.Backend.compileModule'
-- without the 'inCompilerEnv' wrapper (its output-dir \/ scope setup is
-- unneeded for a backend that emits no compiled artifacts).
-- 'setInterface' establishes 'stCurrentModule', merges the module's
-- pragma options, and re-seeds 'stImportedModules' so 'preModule' hooks
-- reading 'curIF' see the right interface.
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
      res  <- mapM (\d -> setCurrentRange (defName d) $
                            compileDef backend env menv isMain d) defs
      postModule backend env menv isMain tlmn res
