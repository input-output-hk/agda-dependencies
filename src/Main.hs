{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternGuards #-}
-- | Entry point for the @agda-deps@ executable: intercept the @doctor@
-- subcommand and @--help@ \/ @--version@ \/ @--emit-schema@, pre-process
-- @argv@ (canonicalise
-- path-bearing flags, @cd@ to the nearest @.agda-lib@ ancestor), then
-- hand off to 'runAgdaArgs', 'runAgdaArgsKeepGoing', or 'runSkipAgda'.
module Main where

import System.Directory
  ( canonicalizePath, getCurrentDirectory, setCurrentDirectory )
import System.Environment ( getArgs )
import System.Exit ( exitSuccess )
import System.FilePath ( (</>), isAbsolute, takeDirectory )

import Control.Monad ( forM_, when )
import Data.List ( isPrefixOf )

#if MIN_VERSION_Agda(2,9,0)
import Agda.Compiler.Backend ( Backend_boot(Backend) )
import Agda.Main ( runAgdaArgs )
#else
-- Agda 2.8 has no 'runAgdaArgs'; shim it below over 'runAgda''.
import Agda.Compiler.Backend ( Backend, Backend_boot(Backend) )
import Agda.Main ( runAgda' )
import System.Environment ( withArgs )
#endif

import Data.IORef ( writeIORef )

import AgdaDeps.Backend
  ( backendWithSeed, parseBackendFlags, precomputedGraphRef )
import AgdaDeps.Config
  ( applyConfig, defaultConfig, discoverConfigPath, loadConfig
  , extractConfigArg, inferFormatFromOutput, cfgResolveDeps
  , showDefaultsYaml )
import AgdaDeps.Doctor  ( isDoctorCommand, runDoctor )
import AgdaDeps.Driver  ( runAgdaArgsKeepGoing )
import AgdaDeps.Backend.Wire ( expandedSchemaJson )
import AgdaDeps.Help
  ( isHelpRequest, wantsAgdaHelp, rewriteAgdaHelp, printHelp
  , isVersionRequest, printVersion )
import AgdaDeps.LibResolve
  ( wantsResolveDeps, stripResolveDepsFlag, resolveProjectDepsArgs )
import AgdaDeps.Logging ( setQuiet, info )
import AgdaDeps.Options ( Options(..), defaultOptions )
import AgdaDeps.Precompute ( precomputeFromArgs )
import AgdaDeps.SkipAgda ( runSkipAgda )
import AgdaDeps.Util
  ( candidateDirs, looksLikeAgdaSource, nearestAgdaLibAncestor )

#if !MIN_VERSION_Agda(2,9,0)
-- | Agda 2.8 shim for 2.9's @runAgdaArgs@: run Agda with an explicit
-- argv and exactly the given backends. 'runAgda'' (not @runAgda@) skips
-- the builtin backends; 'withArgs' feeds the argv it reads via 'getArgs'.
runAgdaArgs :: [Backend] -> [String] -> IO ()
runAgdaArgs backends args = withArgs args (runAgda' backends)
#endif

main :: IO ()
main = do
  rawArgs <- getArgs
  -- `agda-deps doctor` checks the YAML config and exits. First, so that
  -- `doctor --help` gets the subcommand's own usage.
  when (isDoctorCommand rawArgs) $ runDoctor rawArgs
  -- Plain --help / -h / -? short-circuit to backend-only help; forms
  -- like --help=warning pass through to Agda.
  when (any isHelpRequest rawArgs && not (any wantsAgdaHelp rawArgs)) $
    printHelp >> exitSuccess
  -- --version / -V / --numeric-version report agda-deps's own version.
  case filter isVersionRequest rawArgs of
    (v:_) -> printVersion (v == "--numeric-version") >> exitSuccess
    []    -> return ()
  -- --emit-schema prints the generated JSON Schema for expanded JSON
  -- output and exits (no Agda run, no input file needed).
  when ("--emit-schema" `elem` rawArgs) $
    putStrLn expandedSchemaJson >> exitSuccess
  -- --show-defaults prints a sample .agda-deps.yml (every option with its
  -- default value, commented out) and exits, so the user can seed a config
  -- file: `agda-deps --show-defaults > Project/.agda-deps.yml`.
  when ("--show-defaults" `elem` rawArgs) $
    putStr showDefaultsYaml >> exitSuccess

  -- Lift out the optional --config=PATH token so Agda's GetOpt never
  -- sees it and the YAML loads before argv parsing.
  let (cliConfigArg, argsNoConfig) = extractConfigArg rawArgs

  let cliResolveDeps    = wantsResolveDeps argsNoConfig
      argsNoResolveDeps = stripResolveDepsFlag argsNoConfig
  args' <- canonicalizePathArgs (rewriteAgdaHelp argsNoResolveDeps)
  mRoot <- if userOptedOutOfLibDiscovery args'
             then return Nothing
             else discoverProjectRoot args'
  mapM_ setCurrentDirectory mRoot

  -- Discover + load YAML config (if any) once cwd has settled on the
  -- project root. Config layered onto 'defaultOptions' is the seed
  -- Agda's GetOpt walks argv on top of.
  mCfgPath <- discoverConfigPath cliConfigArg
  cfg <- maybe (pure defaultConfig) loadConfig mCfgPath
  let seedOptions = applyConfig cfg defaultOptions

  -- The full option set (defaults → config → CLI), resolved once so every
  -- decision taken before Agda runs reads the answer the backend will get.
  -- The backend itself stays seeded with 'seedOptions': Agda's parse layers
  -- the CLI on top again, and repeatable flags (--exclude) would otherwise
  -- count twice. A bad flag value is left for the chosen path to report,
  -- so routing falls back to the config alone.
  let resolved = either (const seedOptions) fst
                   (parseBackendFlags seedOptions args')
  setQuiet (optQuiet resolved)
  forM_ mRoot $ \root -> info $
    "agda-deps: changing directory to project root " ++ root
    ++ " so Agda picks up its .agda-lib"
  forM_ mCfgPath $ \p -> info $ "agda-deps: applied config from " ++ p

  -- --lenient-imports (CLI or config) is forwarded to Agda as
  -- --allow-unsolved-metas.
  let args = [ "--allow-unsolved-metas" | optLenientImports resolved ]
             ++ filter (/= "--lenient-imports") args'

  -- --resolve-deps (CLI or YAML): replace Agda's library resolver with an
  -- explicit @--no-libraries -i \<dir\> ...@ list from the project's
  -- @.agda-lib@ @depend:@ closure (see "AgdaDeps.LibResolve").
  let resolveDeps = cliResolveDeps
                 || cfgResolveDeps cfg == Just True
  resolveArgs <- if resolveDeps
    then do
      resolveRoot <- maybe getCurrentDirectory return mRoot
      resolveProjectDepsArgs info resolveRoot
    else return []
  let args'WithResolve = resolveArgs ++ args

  -- Infer --format from the -o extension when --format wasn't given
  -- explicitly. Explicit --format in argv wins over inference, which
  -- wins over the config-file value, which wins over the default.
  let userGaveFormat = any ("--format" `isFlagPrefix`) args'WithResolve
      args'' = case (userGaveFormat, inferFormatFromOutput args'WithResolve) of
        (False, Just fmt) ->
          ("--format=" ++ fmt) : args'WithResolve
        _ -> args'WithResolve

  -- Pre-compute the module-level graph from .agda sources so the output
  -- carries every module under the user's -i paths. Written to an IORef
  -- that postCompileAD unions into importEdges.
  precomputed <- precomputeFromArgs args''
  writeIORef precomputedGraphRef precomputed
  let runWith = Backend (backendWithSeed seedOptions)
  if optSkipAgda resolved
    then runSkipAgda seedOptions precomputed args''
    else if optKeepGoing resolved
      then runAgdaArgsKeepGoing [runWith] args''
      else runAgdaArgs           [runWith] args''

-- | Does @arg@ start with @\"flag\"@ in either short (@\"flag=val\"@)
-- or two-token form (just @\"flag\"@)?
isFlagPrefix :: String -> String -> Bool
isFlagPrefix flag arg =
     arg == flag
  || (flag ++ "=") `isPrefixOf` arg

-- | True when the user has already passed flags that govern library
-- handling (so our auto-discovery shouldn't second-guess them).
userOptedOutOfLibDiscovery :: [String] -> Bool
userOptedOutOfLibDiscovery = any isOptOut
  where
    isOptOut a =
         a == "--no-libraries"
      || a == "--library"      || "--library="      `isPrefixOf` a
      || a == "-l"
      || a == "--library-file" || "--library-file=" `isPrefixOf` a

-- | Canonicalize file/dir paths in argv (the @-o@ and @-i@ flag values,
-- plus positional @*.agda@ / @*.lagda*@ source files) to absolute paths.
-- Runs before any cwd change, so relative paths resolve against the
-- original cwd.
canonicalizePathArgs :: [String] -> IO [String]
canonicalizePathArgs = go
  where
    go [] = return []
    go (a:rest)
      -- Two-arg path flags: -o DIR, -i DIR, --out-dir DIR,
      -- --include-path DIR.
      | a `elem` pathFlagsTwo, v:rest' <- rest = do
          v' <- absify v
          (\xs -> a : v' : xs) <$> go rest'
      -- One-arg "--flag=VALUE" forms.
      | Just (flagPrefix, v) <- splitEq a, flagPrefix `elem` pathFlagsEq = do
          v' <- absify v
          ((flagPrefix ++ "=" ++ v') :) <$> go rest
      -- Positional source files.
      | looksLikeAgdaSource a = do
          a' <- absify a
          (a' :) <$> go rest
      | otherwise = (a :) <$> go rest

    pathFlagsTwo = ["-o", "--out-dir", "-i", "--include-path"]
    pathFlagsEq  = ["--out-dir", "--include-path"]

    splitEq s = case break (== '=') s of
      (k, '=':v) -> Just (k, v)
      _          -> Nothing

    absify :: FilePath -> IO FilePath
    absify p
      | isAbsolute p = return p
      | otherwise    = canonicalizePath p

-- | Walk up from the include-path and source-file directories until we
-- find an ancestor containing an @.agda-lib@. Return that ancestor.
discoverProjectRoot :: [String] -> IO (Maybe FilePath)
discoverProjectRoot args = do
  let candidates = candidateDirs args
  cwd <- getCurrentDirectory
  if any (sameDir cwd) candidates
    then return Nothing  -- cwd is already a candidate
    else firstJustM nearestAgdaLibAncestor candidates
  where
    sameDir a b = takeDirectory (a </> "x") == takeDirectory (b </> "x")

    firstJustM :: (a -> IO (Maybe b)) -> [a] -> IO (Maybe b)
    firstJustM _ []     = return Nothing
    firstJustM f (x:xs) = f x >>= \case
      Just y  -> return (Just y)
      Nothing -> firstJustM f xs
