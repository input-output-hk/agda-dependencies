{-# LANGUAGE FlexibleContexts #-}
-- | Logging shim where @--quiet@ suppresses progress output, backed
-- by a global flag rather than a threaded 'Options' value.
--
-- 'Main' calls 'setQuiet' from argv before any work fires. Progress
-- lines route through 'info'; errors and warnings use
-- 'hPutStrLn stderr' directly so they are never muted.
module AgdaDeps.Logging
  ( setQuiet
  , info
  , measure
  , withPhase
  , resetTimings
  , reportTimings
  ) where

import Control.Concurrent ( forkIO, killThread, threadDelay )
import Control.Exception ( bracket )
import Control.Monad ( unless, when )
import Control.Monad.IO.Class ( MonadIO(liftIO) )

import Data.IORef ( IORef, newIORef, readIORef, writeIORef, atomicModifyIORef' )
import qualified Data.Map.Strict as M
import Data.Word ( Word64 )
import GHC.Clock ( getMonotonicTimeNSec )
import System.CPUTime ( getCPUTime )

import System.IO ( hPutStrLn, stderr )
import System.IO.Unsafe ( unsafePerformIO )

-- | Global @--quiet@ flag. 'False' (verbose) by default; flipped by
-- 'Main' when argv contains @--quiet@.
{-# NOINLINE quietRef #-}
quietRef :: IORef Bool
quietRef = unsafePerformIO $ newIORef False

setQuiet :: Bool -> IO ()
setQuiet = writeIORef quietRef

isQuiet :: IO Bool
isQuiet = readIORef quietRef

-- | Progress / informational line on stderr. Suppressed under
-- @--quiet@; otherwise printed verbatim.
info :: MonadIO m => String -> m ()
info msg = liftIO $ do
  q <- isQuiet
  unless q $ hPutStrLn stderr msg

-- Strict fields prevent arithmetic thunks from accumulating between reports.
data Timing = Timing !Int !Word64 !Integer

-- Nested measurements overlap: totals must not be summed as disjoint phases.
{-# NOINLINE timingsRef #-}
timingsRef :: IORef (M.Map String Timing)
timingsRef = unsafePerformIO $ newIORef M.empty

-- | Clear accumulated measurements before an in-process backend run.
resetTimings :: IO ()
resetTimings = writeIORef timingsRef M.empty

-- | Measure a successful action, reporting progress every 250 calls.
measure :: MonadIO m => String -> m a -> m a
measure name action = do
  quiet <- liftIO isQuiet
  if quiet then action else do
    (start, cpuStart) <- liftIO readClock
    value <- action
    (end, cpuEnd) <- liftIO readClock
    timing@(Timing count _ _) <- liftIO $ atomicModifyIORef' timingsRef $ \rows ->
      let Timing n total cpu = M.findWithDefault (Timing 0 0 0) name rows
          current = Timing (n + 1) (total + end - start) (cpu + cpuEnd - cpuStart)
      in (M.insert name current rows, current)
    when (count == 1 || count `mod` 250 == 0) $
      info ("agda-deps: phase " ++ name ++ ": " ++ timingSummary timing)
    pure value

-- | Time an IO phase, keeping progress visible during long output writes.
withPhase :: String -> IO a -> IO a
withPhase name action = do
  quiet <- isQuiet
  if quiet then action else do
    info ("agda-deps: phase " ++ name ++ " started")
    (start, cpuStart) <- readClock
    let heartbeat = do
          threadDelay 15000000
          now <- getMonotonicTimeNSec
          info ("agda-deps: phase " ++ name ++ " running: " ++
                show ((now - start) `div` 1000000000) ++ " s elapsed")
          heartbeat
    value <- bracket (forkIO heartbeat) killThread (const action)
    (end, cpuEnd) <- readClock
    info ("agda-deps: phase " ++ name ++ " completed: " ++
          elapsedSummary (end - start) (cpuEnd - cpuStart) ++ " (child CPU excluded)")
    pure value

-- | Report inclusive totals for the current backend run.
reportTimings :: MonadIO m => m ()
reportTimings = do
  rows <- liftIO $ readIORef timingsRef
  unless (M.null rows) $ do
    info "agda-deps: capture phase totals (nested/inclusive, not additive):"
    mapM_ (\(name, timing) -> info ("  " ++ name ++ ": " ++ timingSummary timing))
      (M.toAscList rows)

readClock :: IO (Word64, Integer)
readClock = (,) <$> getMonotonicTimeNSec <*> getCPUTime

timingSummary :: Timing -> String
timingSummary (Timing count total cpu) =
  show count ++ " definition(s), " ++ elapsedSummary total cpu

elapsedSummary :: Word64 -> Integer -> String
elapsedSummary wall cpu = "wall_ms=" ++ show (wall `div` 1000000) ++
  ", process_cpu_ms=" ++ show (cpu `div` 1000000000)
