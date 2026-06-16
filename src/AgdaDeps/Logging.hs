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
  ) where

import Control.Monad ( unless )
import Control.Monad.IO.Class ( MonadIO(liftIO) )

import Data.IORef ( IORef, newIORef, readIORef, writeIORef )

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
