{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Same-directory atomic file replacement for consumer output and caches.
--
-- The temporary file lives beside its destination, so the final 'renameFile'
-- does not cross filesystems.  A failed write removes the temporary file and
-- leaves the previous destination untouched.
module AgdaDeps.AtomicWrite
  ( atomicWriteString
  , atomicWriteLazyText
  , atomicWriteLazyBytes
  ) where

import qualified Control.Exception as E
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.IO as TL
import System.Directory
  ( doesFileExist, removeFile, renameFile )
#ifdef mingw32_HOST_OS
import System.Directory
  ( Permissions, getPermissions, setPermissions )
#endif
import System.FilePath ( takeDirectory, takeFileName )
import System.IO
  ( Handle, hClose, hFlush, hPutStr
  , openBinaryTempFileWithDefaultPermissions
  , openTempFileWithDefaultPermissions
  )
#ifndef mingw32_HOST_OS
import System.Posix.Files ( fileMode, getFileStatus, setFileMode )
import System.Posix.Types ( FileMode )
#endif

-- | Atomically replace a text file using the process's normal text encoding,
-- matching 'writeFile'.
atomicWriteString :: FilePath -> String -> IO ()
atomicWriteString path body =
  atomicWriteWith openTempFileWithDefaultPermissions path (`hPutStr` body)

-- | Atomically replace a lazy 'Text' file, matching 'TL.writeFile'.
atomicWriteLazyText :: FilePath -> TL.Text -> IO ()
atomicWriteLazyText path body =
  atomicWriteWith openTempFileWithDefaultPermissions path (`TL.hPutStr` body)

-- | Atomically replace a binary file.
atomicWriteLazyBytes :: FilePath -> BL.ByteString -> IO ()
atomicWriteLazyBytes path body =
  atomicWriteWith openBinaryTempFileWithDefaultPermissions path (`BL.hPut` body)

atomicWriteWith
  :: (FilePath -> String -> IO (FilePath, Handle))
  -> FilePath
  -> (Handle -> IO ())
  -> IO ()
atomicWriteWith openTemp path writeBody = E.mask $ \restore -> do
  let dir      = takeDirectory path
      template = "." ++ takeFileName path ++ ".tmp"
  oldPermissions <- permissionsIfPresent path
  (tmp, h) <- openTemp dir template
  let ignoreIO action = action `E.catch` \(_ :: E.IOException) -> pure ()
      cleanup = do
        ignoreIO (hClose h)
        ignoreIO (removeFile tmp)
      finish = do
        restore (writeBody h)
        hFlush h
        hClose h
        -- Replacing an existing file should retain the permission behavior of
        -- ordinary truncate-and-write. New files already have the process's
        -- normal umask-derived permissions because the *WithDefaultPermissions
        -- temp-file constructors were used above.
        maybe (pure ()) (restorePermissions tmp) oldPermissions
        renameFile tmp path
  finish `E.onException` cleanup

#ifdef mingw32_HOST_OS
type SavedPermissions = Permissions

restorePermissions :: FilePath -> SavedPermissions -> IO ()
restorePermissions = setPermissions

permissionsIfPresent :: FilePath -> IO (Maybe SavedPermissions)
permissionsIfPresent path = do
  exists <- doesFileExist path
  if exists then Just <$> getPermissions path else pure Nothing
#else
type SavedPermissions = FileMode

restorePermissions :: FilePath -> SavedPermissions -> IO ()
restorePermissions = setFileMode

permissionsIfPresent :: FilePath -> IO (Maybe SavedPermissions)
permissionsIfPresent path = do
  exists <- doesFileExist path
  if exists then Just . fileMode <$> getFileStatus path else pure Nothing
#endif
