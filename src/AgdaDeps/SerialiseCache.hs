{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | @--incremental@ serialise cache: lets a rebuild skip re-emitting
-- byte-identical output. Two skip mechanisms, both keyed off a tiny
-- text manifest persisted next to the fragment cache:
--
-- * __Monolithic output__ (@deps.json@ / inline @deps.html@): one blob,
--   so only a no-op rebuild wins. Skip generation and write when no
--   module recompiled this run AND the output-affecting context (module
--   set, options, build identity) is unchanged — both guards required.
--
-- * __Lazy per-module files__ (@modules\/\<M\>.json@,
--   @snippets\/\<M\>.json@): each carries a content /epoch/; regenerate
--   only files whose epoch changed. Adding\/removing a definition shifts
--   the global node indices, so many epochs change.
--
-- Manifest header carries a format version + the @--gzip@ flag; a change
-- to either invalidates it wholesale. Needs no CPP.
module AgdaDeps.SerialiseCache
  ( Manifest
  , emptyManifest
  , readManifest
  , writeManifest
  , manifestLookup
  , manifestFromList
  , Epoch
  , combineEpochs
  , hashEpoch
  ) where

import qualified Control.Exception as E
import Data.Word ( Word64 )
import qualified Data.Map.Strict as M
import Numeric ( readHex, showHex )
import System.Directory
  ( createDirectoryIfMissing, doesFileExist )
import System.FilePath ( (</>), takeDirectory )

import Agda.Utils.Hash ( hashString )

-- | A content fingerprint.
type Epoch = Word64

-- | Hash a string to an 'Epoch'.
hashEpoch :: String -> Epoch
hashEpoch = hashString

-- | Fold a list of 'Epoch's into one (order-sensitive multiply-add).
-- Combines several component fingerprints into a single token.
combineEpochs :: [Epoch] -> Epoch
combineEpochs = foldl (\ !acc x -> acc * 1099511628211 + x) 1469598103934665603

-- | Slot name -> content epoch. Slots are output-relative paths
-- (@"deps.json"@, @"modules\/Foo.json"@, …) plus the synthetic
-- @"::mono::"@ token slot for the monolithic no-op check.
type Manifest = M.Map String Epoch

emptyManifest :: Manifest
emptyManifest = M.empty

manifestLookup :: String -> Manifest -> Maybe Epoch
manifestLookup = M.lookup

manifestFromList :: [(String, Epoch)] -> Manifest
manifestFromList = M.fromList

manifestVersion :: Int
manifestVersion = 1

manifestFileName :: FilePath -> FilePath
manifestFileName cacheDir = cacheDir </> "serialise.manifest"

-- | Read the manifest for the given cache dir. Returns 'emptyManifest'
-- (\"everything stale, rewrite all\") on any mismatch or IO error: wrong
-- format version, changed @--gzip@ setting, missing\/corrupt file. The
-- @gzip@ argument is the current run's setting.
readManifest :: FilePath -> Bool -> IO Manifest
readManifest cacheDir gzip = do
  let path = manifestFileName cacheDir
  ok <- doesFileExist path
  if not ok then pure emptyManifest else
    (do txt <- readFile path
        -- Force the read fully before the handle closes (lazy readFile).
        length txt `seq` pure ()
        case lines txt of
          (hdr : rest)
            | hdr == headerLine gzip -> pure (manifestFromList (parseLines rest))
          _ -> pure emptyManifest)
      `E.catch` \ (_ :: E.IOException) -> pure emptyManifest
  where
    parseLines = foldr step []
      where
        step ln acc = case break (== ' ') ln of
          (hex, ' ' : slot)
            | [(e, "")] <- readHex hex -> (slot, e) : acc
          _ -> acc

-- | Write the manifest. Failures are swallowed (a manifest-write hiccup
-- must not fail the build — worst case the next run rewrites all).
writeManifest :: FilePath -> Bool -> Manifest -> IO ()
writeManifest cacheDir gzip manifest =
  (do createDirectoryIfMissing True cacheDir
      writeFile (manifestFileName cacheDir) body)
    `E.catch` \ (_ :: E.IOException) -> pure ()
  where
    body = unlines $
      headerLine gzip
      : [ showHex e (' ' : slot) | (slot, e) <- M.toAscList manifest ]

headerLine :: Bool -> String
headerLine gzip =
  "agda-deps-serialise v" ++ show manifestVersion
  ++ " gzip=" ++ (if gzip then "1" else "0")
