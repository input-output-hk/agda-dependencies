{-# LANGUAGE CPP #-}
-- | Custom @--help@ output that lists only @agda-deps@'s own flags (the
-- backend's 'commandLineFlags' plus the ones "Main" handles before Agda
-- runs) and points to the README for details; and version handling.
--
-- "Main" intercepts @--help@ \/ @-h@ \/ @-?@ and routes to 'printHelp';
-- @--agda-help@ is rewritten to a plain @--help@ for Agda's full help.
--
-- Key functions: 'printHelp', 'printVersion'.
module AgdaDeps.Help
  ( printHelp
  , printVersion
  ) where

import Data.Version ( showVersion )
import Paths_agda_deps ( version )

import BuildInfo ( buildFingerprint )

import Agda.Compiler.Backend ( commandLineFlags )
import Agda.Utils.GetOpt ( OptDescr(Option), ArgDescr(NoArg), usageInfo )

import AgdaDeps.Backend ( backend )

-- | Print the @agda-deps@ build identity. Plain @--version@ \/ @-V@
-- prints the full 'buildFingerprint' (version + git revision + build
-- date + compiling GHC); @--numeric-version@ prints just the bare
-- version number for tooling that parses it.
printVersion :: Bool -> IO ()
printVersion numericOnly
  | numericOnly = putStrLn (showVersion version)
  | otherwise   = putStrLn buildFingerprint

-- | Print a short help message: usage, one line per @agda-deps@ flag,
-- and a pointer to the README for details.
printHelp :: IO ()
printHelp = putStr $ unlines
  [ "agda-deps " ++ showVersion version
      ++ ": dependency graphs of Agda definitions, as DOT or JSON."
  , ""
  , "Usage: agda-deps [OPTIONS] FILE.agda"
  , "       agda-deps doctor [--config=PATH] [--strict]   check a config file"
  ]
    -- 2.9 added a leading minimum-column-width argument to 'usageInfo';
    -- 0 keeps 2.8's layout (column as wide as the longest flag).
#if MIN_VERSION_Agda(2,9,0)
  ++ usageInfo 0 "\nOptions:" opts
#else
  ++ usageInfo "\nOptions:" opts
#endif
  ++ unlines
  [ ""
  , "Agda flags (-i DIR, -l LIB, --no-libraries, ...) are passed to Agda."
  , "Details: README.md and Examples.md, or"
  , "https://github.com/input-output-hk/agda-dependencies#readme"
  ]
  where
    -- One table, so every flag lines up: the backend's own flags (with
    -- their 'Flag' parsers discarded), then those "Main" handles itself.
    opts :: [OptDescr ()]
    opts = map (fmap (const ())) (commandLineFlags backend) ++
      [ Option ['h'] ["help"]            (NoArg ()) "Show this help"
      , Option []    ["agda-help"]       (NoArg ()) "Show Agda's full help"
      , Option ['V'] ["version"]         (NoArg ()) "Print the version"
      , Option []    ["numeric-version"] (NoArg ()) "Print the version number"
      , Option []    ["emit-schema"]     (NoArg ()) "Print the expanded JSON Schema"
      , Option []    ["show-defaults"]   (NoArg ()) "Print a sample .agda-deps.yml"
      ]
