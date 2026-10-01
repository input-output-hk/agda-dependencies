{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
-- | Entry point for the @agda-deps@ executable: intercept the @doctor@
-- subcommand and @--help@ \/ @--version@ \/ @--emit-schema@, pre-process
-- @argv@ (canonicalise
-- path-bearing flags, @cd@ to the nearest @.agda-lib@ ancestor), then
-- hand off to 'runAgdaArgs', 'runAgdaArgsKeepGoing', or 'runSkipAgda'.
module Main where

import System.Directory ( getCurrentDirectory, setCurrentDirectory )
import System.Environment ( getArgs )
import System.Exit ( die, exitSuccess )
import System.FilePath ( (</>), takeDirectory )

import Control.Monad ( forM_, when )

#if MIN_VERSION_Agda(2,9,0)
import Agda.Compiler.Backend ( Backend_boot(Backend), commandLineFlags )
import Agda.Main ( runAgdaArgs )
#else
-- Agda 2.8 has no 'runAgdaArgs'; shim it below over 'runAgda''.
import Agda.Compiler.Backend ( Backend, Backend_boot(Backend), commandLineFlags )
import Agda.Main ( runAgda' )
import System.Environment ( withArgs )
#endif

import Data.IORef ( writeIORef )
import Agda.Interaction.Options ( standardOptions, deadStandardOptions )
import Agda.Utils.GetOpt ( OptDescr(..), ArgDescr(..) )

import AgdaDeps.Arguments
import AgdaDeps.Backend
  ( backendWithSeed, parseBackendFlags, precomputedGraphRef )
import AgdaDeps.Config
  ( applyConfig, defaultConfig, discoverConfigPathFrom, loadConfig
  , cfgResolveDeps
  , showDefaultsYaml )
import AgdaDeps.Doctor  ( isDoctorCommand, runDoctor )
import AgdaDeps.Driver  ( runAgdaArgsKeepGoing )
import AgdaDeps.Backend.Wire ( expandedSchemaJson )
import AgdaDeps.Help ( printHelp, printVersion )
import AgdaDeps.LibResolve ( resolveProjectDepsDirs )
import AgdaDeps.Logging ( setQuiet, info )
import AgdaDeps.Options ( Options(..), defaultOptions, formatSlug )
import AgdaDeps.Precompute ( precomputeFromRoots )
import AgdaDeps.SkipAgda ( runSkipAgda )
import AgdaDeps.Util ( nearestAgdaLibAncestor )

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
  normalized <- either (die . ("agda-deps: " ++)) pure
                  (normalizeArguments argumentDescriptors rawArgs)
  -- Plain --help / -h / -? short-circuit to backend-only help; forms
  -- like --help=warning pass through to Agda.
  when ((hasBareOption "--help" normalized || hasOption "-h" normalized)
        && not (hasOption "--agda-help" normalized)) $
    printHelp >> exitSuccess
  -- --version / -V / --numeric-version report agda-deps's own version.
  case [ n | Flag n _ _ <- normalized,
             n `elem` ["--version", "--numeric-version"] ] of
    (v:_) -> printVersion (v == "--numeric-version") >> exitSuccess
    []    -> return ()
  -- --emit-schema prints the generated JSON Schema for expanded JSON
  -- output and exits (no Agda run, no input file needed).
  when (hasOption "--emit-schema" normalized) $
    putStrLn expandedSchemaJson >> exitSuccess
  -- --show-defaults prints a sample .agda-deps.yml (every option with its
  -- default value, commented out) and exits, so the user can seed a config
  -- file: `agda-deps --show-defaults > Project/.agda-deps.yml`.
  when (hasOption "--show-defaults" normalized) $
    putStr showDefaultsYaml >> exitSuccess

  invocationDir <- getCurrentDirectory
  absolute <- canonicalizeArguments invocationDir normalized
  mRoot <- if any (`hasOption` absolute)
                ["--no-libraries", "--library", "--library-file"]
             then return Nothing
             else discoverProjectRoot (sourceRoots absolute)
  mapM_ setCurrentDirectory mRoot

  -- Discover + load YAML config (if any) once cwd has settled on the
  -- project root. Config layered onto 'defaultOptions' is the seed
  -- Agda's GetOpt walks argv on top of.
  mCfgPath <- discoverConfigPathFrom invocationDir
                (lastOptionValue "--config" absolute)
  cfg <- maybe (pure defaultConfig) loadConfig mCfgPath
  let seedOptions = applyConfig cfg defaultOptions

  -- The full option set (defaults → config → CLI), resolved once so every
  -- decision taken before Agda runs reads the answer the backend will get.
  -- The backend itself stays seeded with 'seedOptions': Agda's parse layers
  -- the CLI on top again, and repeatable flags (--exclude) would otherwise
  -- count twice. Select only known backend flags: Agda option operands
  -- must never be reparsed as backend flags or source files.
  let withFormat = case inferredFormat absolute of
        Just fmt -> option "--format" (Just (formatSlug fmt)) : absolute
        Nothing -> absolute
  resolved <- either (die . ("agda-deps: " ++)) (pure . fst)
                (parseBackendFlags seedOptions
                  (renderArguments (selectOptions backendDescriptors withFormat)))
  setQuiet (optQuiet resolved)
  forM_ mRoot $ \root -> info $
    "agda-deps: changing directory to project root " ++ root
    ++ " so Agda picks up its .agda-lib"
  forM_ mCfgPath $ \p -> info $ "agda-deps: applied config from " ++ p

  -- --lenient-imports (CLI or config) is forwarded to Agda as
  -- --allow-unsolved-metas.
  let args = [ option "--allow-unsolved-metas" Nothing | optLenientImports resolved ]
             ++ map forwardHelp
                  (withoutOptions ["--config", "--resolve-deps", "--lenient-imports"]
                    withFormat)
      forwardHelp (Flag "--agda-help" _ _) = option "--help" Nothing
      forwardHelp arg = arg

  -- --resolve-deps (CLI or YAML): replace Agda's library resolver with an
  -- explicit @--no-libraries -i \<dir\> ...@ list from the project's
  -- @.agda-lib@ @depend:@ closure (see "AgdaDeps.LibResolve").
  let resolveDeps = hasOption "--resolve-deps" absolute
                 || cfgResolveDeps cfg == Just True
  resolveDirs <- if resolveDeps
    then do
      resolveRoot <- maybe getCurrentDirectory return mRoot
      resolveProjectDepsDirs info (lastOptionValue "--library-file" absolute) resolveRoot
    else return []
  let resolveArgs = if null resolveDirs then [] else
        option "--no-libraries" Nothing :
          map (option "--include-path" . Just) resolveDirs
      finalArgs = resolveArgs ++ args
      argv = renderArguments finalArgs

  -- Pre-compute the module-level graph from .agda sources so the output
  -- carries every module under the user's -i paths. Written to an IORef
  -- that postCompileAD unions into importEdges.
  precomputed <- precomputeFromRoots (sourceRoots finalArgs)
  writeIORef precomputedGraphRef precomputed
  let runWith = Backend (backendWithSeed seedOptions)
  if optSkipAgda resolved
    then runSkipAgda resolved precomputed (firstSource finalArgs)
    else if optKeepGoing resolved
      then runAgdaArgsKeepGoing [runWith] argv
      else runAgdaArgs           [runWith] argv

-- | Share the real flag arities with every startup decision. The option
-- actions are discarded: this pass recognises syntax without applying values.
backendDescriptors :: [OptDescr ()]
backendDescriptors = map (fmap (const ()))
  (commandLineFlags (backendWithSeed defaultOptions))

argumentDescriptors :: [OptDescr ()]
argumentDescriptors = backendDescriptors
  ++ map (fmap (const ())) (standardOptions ++ deadStandardOptions)
  ++ [ Option ['h'] [] (NoArg ()) ""
     ]
  ++ [ Option [] [name] (NoArg ()) ""
     | name <- ["agda-help", "emit-schema", "show-defaults"] ]

-- | Walk up from the include-path and source-file directories until we
-- find an ancestor containing an @.agda-lib@. Return that ancestor.
discoverProjectRoot :: [FilePath] -> IO (Maybe FilePath)
discoverProjectRoot candidates = do
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
