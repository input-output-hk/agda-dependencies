-- | Thin shim between "Main" and "AgdaDeps.ModuleExplorer".
--
-- Supplies the backend-specific glue (the 'failedModulesRef' IORef
-- written when @--keep-going@ catches a type-check error) and exposes
-- 'runAgdaArgsKeepGoing', the independent project-source sweep. The
-- partial-compile machinery lives in "AgdaDeps.ModuleExplorer".
module AgdaDeps.Driver
  ( runAgdaArgsKeepGoing
  ) where

import Control.Monad ( filterM )
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.IORef ( modifyIORef' )

import System.Environment ( withArgs )

import Agda.Compiler.Backend ( Backend )

import AgdaDeps.Backend ( failedModulesRef )
import AgdaDeps.ModuleExplorer ( runPartial )
import AgdaDeps.Logging ( info )
import AgdaDeps.Options ( Options(..), isExcludedModule )
import AgdaDeps.Precompute ( PrecomputedGraph(..) )
import AgdaDeps.Util ( underRoot )

-- | Sweep discovered project sources, not entire external include trees.
-- The scan supplies names for diagnostics and exclusions only; Agda remains
-- the authority for parsing and checking each source, including files whose
-- header the heuristic scanner could not recognise. Failed module names are
-- recorded in 'failedModulesRef' for the backend's @postCompile@.
runAgdaArgsKeepGoing :: FilePath -> Options -> PrecomputedGraph -> [Backend] -> [String] -> IO ()
runAgdaArgsKeepGoing projectRoot opts precomputed backends args = do
  isUnderRoot <- underRoot projectRoot
  files <- filterM isUnderRoot (precomputedSourceFiles precomputed)
  let names = M.fromList [ (p, m) | (m, p) <- precomputedModuleFiles precomputed ]
      targets = [ (name, p) | p <- files
                            , let name = M.lookup p names
                            , maybe True (not . isExcludedModule (optExcludeModules opts)) name ]
  info $ "agda-deps: --keep-going: sweeping " ++ show (length targets)
      ++ " project source file(s) under " ++ projectRoot ++ "."
  withArgs args $ runPartial targets reportFailed backends

reportFailed :: String -> IO ()
reportFailed m = modifyIORef' failedModulesRef (S.insert m)
