-- | Thin shim between "Main" and "AgdaDeps.ModuleExplorer".
--
-- Supplies the backend-specific glue (the 'failedModulesRef' IORef
-- written when @--keep-going@ catches a type-check error) and exposes
-- 'runAgdaArgsKeepGoing', a drop-in for 'Agda.Main.runAgdaArgs'. The
-- partial-compile machinery lives in "AgdaDeps.ModuleExplorer".
module AgdaDeps.Driver
  ( runAgdaArgsKeepGoing
  , wantsKeepGoing
  ) where

import qualified Data.Set as S
import Data.IORef ( modifyIORef' )

import System.Environment ( withArgs )

import Agda.Compiler.Backend ( Backend )

import AgdaDeps.Backend ( failedModulesRef )
import AgdaDeps.ModuleExplorer ( runPartial )

-- | Quick scan of argv for @--keep-going@ so @Main.main@ can decide
-- which driver to call without a full option parse.
wantsKeepGoing :: [String] -> Bool
wantsKeepGoing = elem "--keep-going"

-- | Drop-in for 'Agda.Main.runAgdaArgs' using the partial-compile
-- interactor from "AgdaDeps.ModuleExplorer". Threads failed module
-- names into 'failedModulesRef' so the backend's @postCompile@ can tag
-- them in the rendered graph.
runAgdaArgsKeepGoing :: [Backend] -> [String] -> IO ()
runAgdaArgsKeepGoing backends args = withArgs args $
  runPartial reportFailed backends
  where
    reportFailed m = modifyIORef' failedModulesRef (S.insert m)
