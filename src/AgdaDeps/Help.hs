{-# LANGUAGE CPP #-}
-- | Custom @--help@ output that lists only @agda-deps@ backend options
-- (the backend's 'commandLineFlags' plus a short list of commonly
-- combined Agda CLI flags), and version handling.
--
-- "Main" intercepts @--help@ \/ @-h@ \/ @-?@ and routes to 'printHelp';
-- @--agda-help@ is rewritten to a plain @--help@ for Agda's full help.
--
-- Key functions: 'isHelpRequest', 'wantsAgdaHelp', 'rewriteAgdaHelp',
-- 'printHelp', 'isVersionRequest', 'printVersion'.
module AgdaDeps.Help
  ( isHelpRequest
  , wantsAgdaHelp
  , rewriteAgdaHelp
  , printHelp
  , isVersionRequest
  , printVersion
  ) where

import Data.Version ( showVersion )
import Paths_agda_deps ( version )

import BuildInfo ( buildFingerprint )

import Agda.Compiler.Backend ( commandLineFlags )
import Agda.Utils.GetOpt ( OptDescr, usageInfo )

import AgdaDeps.Backend ( backend )

-- | True for the bare help flags (no @=topic@ suffix). Topic forms
-- (@--help=warning@, @--help=error@, …) are forwarded to Agda
-- unchanged so its topic-specific help still works.
isHelpRequest :: String -> Bool
isHelpRequest a = a == "--help" || a == "-h" || a == "-?"

-- | True for the version flags (@--version@, @-V@,
-- @--numeric-version@), intercepted to print the @agda-deps@ version
-- rather than Agda's.
isVersionRequest :: String -> Bool
isVersionRequest a = a == "--version" || a == "-V" || a == "--numeric-version"

-- | True if the user asked for Agda's full upstream help.
wantsAgdaHelp :: String -> Bool
wantsAgdaHelp = (== "--agda-help")

-- | Replace every @--agda-help@ token with @--help@ so Agda's own
-- help printer fires.
rewriteAgdaHelp :: [String] -> [String]
rewriteAgdaHelp = map (\a -> if wantsAgdaHelp a then "--help" else a)

-- | Print the @agda-deps@ build identity. Plain @--version@ \/ @-V@
-- prints the full 'buildFingerprint' (version + git revision + build
-- date + compiling GHC); @--numeric-version@ prints just the bare
-- version number for tooling that parses it.
printVersion :: Bool -> IO ()
printVersion numericOnly
  | numericOnly = putStrLn (showVersion version)
  | otherwise   = putStrLn buildFingerprint

-- | Print a help message listing only the @agda-deps@ backend options,
-- plus a brief reminder of the Agda CLI flags routinely combined with
-- it.
printHelp :: IO ()
printHelp = putStr $ unlines
  [ "agda-deps " ++ showVersion version
  , ""
  , "Usage: agda-deps [OPTIONS...] FILE.agda"
  , "       agda-deps doctor [--config=PATH] [--strict]"
  , ""
  , "An Agda compiler backend that emits a dependency graph (DOT/HTML/JSON)"
  , "of every definition reachable from FILE.agda."
  ]
    -- 2.9 added a leading column-width argument to 'usageInfo'.
#if MIN_VERSION_Agda(2,9,0)
  ++ usageInfo 40 "\nagda-deps backend options:\n" backendOpts
#else
  ++ usageInfo "\nagda-deps backend options:\n" backendOpts
#endif
  ++ unlines
  [ ""
  , "Commands (handled by agda-deps; no Agda run):"
  , ""
  , "  doctor     Check the YAML config file and exit: unknown keys, invalid"
  , "             values, and settings that do nothing in combination."
  , "             Takes --config=PATH to check a specific file, and --strict"
  , "             to exit non-zero on warnings as well as errors."
  , ""
  , "Other backend flags (handled by agda-deps before Agda starts):"
  , ""
  , "  --version, -V, --numeric-version"
  , "             Print the agda-deps version and exit."
  , "  --emit-schema"
  , "             Print the JSON Schema for expanded graph.json and exit."
  , "  --show-defaults"
  , "             Print a commented sample .agda-deps.yml with every option"
  , "             at its default value, then exit. Seed a config file with"
  , "             'agda-deps --show-defaults > .agda-deps.yml'."
  , "  --agda-help"
  , "             Show Agda's own full help instead of just the backend's."
  , ""
  , "Frequently-used Agda CLI flags (forwarded to the Agda frontend):"
  , ""
  , "  -i DIR     Add DIR to the Agda module search path. Repeatable."
  , "  -l LIB     Use Agda library LIB."
  , "  --library-file=FILE"
  , "             Use FILE instead of the standard libraries file."
  , "  --no-libraries"
  , "             Don't consult any .agda-libraries file."
  , ""
  , "Use --agda-help to see Agda's full option list."
  ]
  where
    -- Discard the 'Flag' parser inside each 'OptDescr'.
    backendOpts :: [OptDescr ()]
    backendOpts = map (fmap (const ())) (commandLineFlags backend)
