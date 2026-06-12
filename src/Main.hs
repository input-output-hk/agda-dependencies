{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternGuards #-}
-- | Entry point for the @agda-deps@ executable.
--
-- Responsibilities:
--
-- 1. Intercept @--help@ \/ @-h@ \/ @-?@ before Agda sees them and print
--    only this backend's options (see "AgdaDeps.Help"); rewrite
--    @--agda-help@ back to @--help@ for Agda's upstream help.
-- 2. Pre-process @argv@: canonicalise path-bearing flags and @cd@ to
--    the nearest @.agda-lib@ ancestor.
-- 3. Pre-compute the module-level graph and hand off to 'runAgdaArgs',
--    'runAgdaArgsKeepGoing', or 'runSkipAgda'.
--
-- Key functions: 'main', 'canonicalizePathArgs', 'discoverProjectRoot',
-- 'rewriteLenientImports'.
module Main where

import System.Directory
  ( canonicalizePath, doesDirectoryExist, getCurrentDirectory
  , listDirectory, setCurrentDirectory )
import System.Environment ( getArgs )
import System.Exit ( exitSuccess )
import System.FilePath ( (</>), isAbsolute, takeDirectory, takeExtension )

import Agda.Compiler.Backend ( Backend_boot(Backend) )
#if MIN_VERSION_Agda(2,9,0)
import Agda.Main ( runAgdaArgs )
#else
-- Agda 2.8 has no 'runAgdaArgs'; 'runAgda'' is the no-builtin-backends
-- entrypoint that reads argv via 'getArgs'. See the local shim below.
import Agda.Main ( runAgda' )
import System.Environment ( withArgs )
#endif

import Data.IORef ( writeIORef )

import AgdaDeps.Backend ( backendWithSeed, precomputedGraphRef )
import AgdaDeps.Config
  ( applyConfig, defaultConfig, discoverConfigPath, loadConfig
  , extractConfigArg, inferFormatFromOutput, cfgResolveDeps )
import AgdaDeps.Driver  ( runAgdaArgsKeepGoing, wantsKeepGoing )
import AgdaDeps.Help
  ( isHelpRequest, wantsAgdaHelp, rewriteAgdaHelp, printHelp
  , isVersionRequest, printVersion )
import AgdaDeps.LibResolve
  ( wantsResolveDeps, stripResolveDepsFlag, resolveProjectDepsArgs )
import AgdaDeps.Logging ( setQuiet, info )
import AgdaDeps.Options ( defaultOptions )
import AgdaDeps.Precompute ( precomputeFromArgs )
import AgdaDeps.SkipAgda ( runSkipAgda, wantsSkipAgda )
import AgdaDeps.Util ( candidateDirs, looksLikeAgdaSource )

#if !MIN_VERSION_Agda(2,9,0)
-- | Agda 2.8 shim for 2.9's @runAgdaArgs@: run Agda with an explicit
-- argv. 2.9's @runAgdaArgs@ parses with exactly the given backends (no
-- builtin backends prepended), so we use @runAgda'@ — not @runAgda@ —
-- under a temporary 'withArgs'. (Type inferred from @runAgda'@ to avoid
-- needing the @Backend@ type synonym in scope.)
runAgdaArgs backends args = withArgs args (runAgda' backends)
#endif

main :: IO ()
main = do
  rawArgs <- getArgs
  -- Plain --help / -h / -? short-circuit to backend-only help; forms
  -- like --help=warning pass through to Agda.
  if any isHelpRequest rawArgs && not (any wantsAgdaHelp rawArgs)
    then printHelp >> exitSuccess
    else return ()
  -- --version / -V / --numeric-version report agda-deps's own version.
  case filter isVersionRequest rawArgs of
    (v:_) -> printVersion (v == "--numeric-version") >> exitSuccess
    []    -> return ()
  -- Detect --quiet before any 'info' call.
  setQuiet ("--quiet" `elem` rawArgs)

  -- Lift out the optional --config=PATH token so Agda's GetOpt never
  -- sees it and the YAML loads before argv parsing.
  let (cliConfigArg, argsNoConfig) = extractConfigArg rawArgs

  let cliResolveDeps    = wantsResolveDeps argsNoConfig
      argsNoResolveDeps = stripResolveDepsFlag argsNoConfig
  let args = rewriteLenientImports (rewriteAgdaHelp argsNoResolveDeps)
  args' <- canonicalizePathArgs args
  mRoot <- if userOptedOutOfLibDiscovery args'
             then return Nothing
             else discoverProjectRoot args'
  case mRoot of
    Just root -> do
      info $
        "agda-deps: changing directory to project root " ++ root
        ++ " so Agda picks up its .agda-lib"
      setCurrentDirectory root
    Nothing -> return ()

  -- Discover + load YAML config (if any) once cwd has settled on the
  -- project root. Config layered onto 'defaultOptions' is the seed
  -- Agda's GetOpt walks argv on top of.
  mCfgPath <- discoverConfigPath cliConfigArg
  cfg <- case mCfgPath of
    Just p -> do
      c <- loadConfig p
      info $ "agda-deps: applied config from " ++ p
      pure c
    Nothing -> pure defaultConfig
  let seedOptions = applyConfig cfg defaultOptions

  -- When --resolve-deps was passed (CLI or YAML), replace Agda's
  -- library resolver with an explicit
  -- @--no-libraries -i \<dir\> ...@ list derived from the project's
  -- @.agda-lib@ @depend:@ closure (see "AgdaDeps.LibResolve").
  let resolveDeps = cliResolveDeps
                 || cfgResolveDeps cfg == Just True
  resolveArgs <- if resolveDeps
    then do
      resolveRoot <- maybe getCurrentDirectory return mRoot
      resolveProjectDepsArgs info resolveRoot
    else return []
  let args'WithResolve = resolveArgs ++ args'

  -- Infer --format from the -o extension when --format wasn't given
  -- explicitly. Explicit --format in argv wins over inference, which
  -- wins over the config-file value, which wins over the default.
  let userGaveFormat = any ("--format" `isFlagPrefix`) args'WithResolve
      args'' = case (userGaveFormat, inferFormatFromOutput args'WithResolve) of
        (False, Just fmt) ->
          ("--format=" ++ fmt) : args'WithResolve
        _ -> args'WithResolve

  -- Pre-compute the module-level graph from .agda sources before
  -- handing off to Agda, so the rendered output carries every module
  -- under the user's -i paths. The result is written to an IORef that
  -- postCompileAD unions into importEdges.
  precomputed <- precomputeFromArgs args''
  writeIORef precomputedGraphRef precomputed
  let runWith = Backend (backendWithSeed seedOptions)
  if wantsSkipAgda args''
    then runSkipAgda seedOptions precomputed args''
    else if wantsKeepGoing args''
      then runAgdaArgsKeepGoing [runWith] args''
      else runAgdaArgs           [runWith] args''

-- | Does @arg@ start with @\"flag\"@ in either short (@\"flag=val\"@)
-- or two-token form (just @\"flag\"@)?
isFlagPrefix :: String -> String -> Bool
isFlagPrefix flag arg =
     arg == flag
  || take (length flag + 1) arg == (flag ++ "=")

-- | True when the user has already passed flags that govern library
-- handling (so our auto-discovery shouldn't second-guess them).
userOptedOutOfLibDiscovery :: [String] -> Bool
userOptedOutOfLibDiscovery = any isOptOut
  where
    isOptOut a =
         a == "--no-libraries"
      || a == "--library"      || hasPrefix "--library="      a
      || a == "-l"
      || a == "--library-file" || hasPrefix "--library-file=" a

    hasPrefix p s = take (length p) s == p

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
    else firstJustM walkUp candidates
  where
    sameDir a b = takeDirectory (a </> "x") == takeDirectory (b </> "x")

    walkUp :: FilePath -> IO (Maybe FilePath)
    walkUp d = do
      hit <- hasAgdaLib d
      if hit
        then return (Just d)
        else do
          let up = takeDirectory d
          if up == d then return Nothing else walkUp up

    hasAgdaLib :: FilePath -> IO Bool
    hasAgdaLib d = doesDirectoryExist d >>= \case
      False -> return False
      True  -> any ((== ".agda-lib") . takeExtension) <$> listDirectory d

    firstJustM :: (a -> IO (Maybe b)) -> [a] -> IO (Maybe b)
    firstJustM _ []     = return Nothing
    firstJustM f (x:xs) = f x >>= \case
      Just y  -> return (Just y)
      Nothing -> firstJustM f xs

-- | Rewrite every @--lenient-imports@ token to @--allow-unsolved-metas@,
-- before Agda's own option parser sees argv.
rewriteLenientImports :: [String] -> [String]
rewriteLenientImports = map (\a -> if a == "--lenient-imports" then "--allow-unsolved-metas" else a)
