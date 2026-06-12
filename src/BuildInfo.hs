{-# LANGUAGE CPP             #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Compile-time build identity for the @agda-deps@ executable.
--
-- 'buildFingerprint' is a one-line identity string combining four
-- components, each exposed individually:
--
--   * 'packageVersion' — the cabal package version (@Paths_agda_deps@);
--   * 'gitRevision' — the git revision at build time (best-effort;
--     @"unknown"@ for a tarball build, a @"+"@ suffix for a dirty tree);
--   * 'buildDate' — the compile date\/time (via the C preprocessor);
--   * 'ghcVersion' — the compiling GHC.
module BuildInfo
  ( buildFingerprint
  , gitRevision
  , buildDate
  , packageVersion
  , ghcVersion
  ) where

import           Data.Version    (showVersion)
import           System.Info     (compilerVersion)

import           BuildInfoTH     (gitRevisionE)
import           Paths_agda_deps (version)

-- | The cabal package version, e.g. @"1.1"@.
packageVersion :: String
packageVersion = showVersion version

-- | The GHC that compiled this binary, e.g. @"ghc 9.14"@.
ghcVersion :: String
ghcVersion = "ghc " ++ showVersion compilerVersion

-- | Compile date and time, captured by the C preprocessor when this
-- module is built.
buildDate :: String
buildDate = __DATE__ ++ " " ++ __TIME__

-- | Best-effort git revision captured at compile time. @"unknown"@ when
-- there's no git checkout (a source tarball); a trailing @"+"@ marks a
-- dirty working tree.
gitRevision :: String
gitRevision = $(gitRevisionE)

-- | The one-line build fingerprint surfaced by @--version@ and stamped
-- into @graph.json@ as @"producer"@.
buildFingerprint :: String
buildFingerprint =
  "agda-deps " ++ packageVersion
    ++ " (git " ++ gitRevision
    ++ ", built " ++ buildDate
    ++ ", " ++ ghcVersion ++ ")"
