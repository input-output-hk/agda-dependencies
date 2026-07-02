{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | @--incremental@ serialise cache: lets a rebuild skip re-emitting
-- byte-identical output. Two skip mechanisms, both keyed off a tiny
-- text manifest persisted next to the fragment cache:
--
-- * __Monolithic output__ (@deps.json@ / inline @deps.html@) is one
--   blob, so the win is limited to the no-op rebuild: skip both
--   generation and write when no module recompiled this run AND the
--   output-affecting context (module set, options, build identity) is
--   unchanged.
--
-- * __Lazy per-module files__ (@modules\/\<M\>.json@,
--   @snippets\/\<M\>.json@) each carry a content /epoch/; only files
--   whose epoch changed are regenerated. Adding\/removing a definition
--   shifts the global node indices the per-module @outEdges@ reference,
--   so many epochs change — correct, if not minimal.
--
-- The manifest header carries a format version + the @--gzip@ flag; a
-- change to either invalidates it wholesale. Needs no CPP (only the
-- version-stable 'Agda.Utils.Hash' is pulled from Agda).
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
  ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist )
import System.FilePath ( (</>), takeDirectory )

import Agda.Utils.Hash ( hashString )

-- | A content fingerprint.
type Epoch = Word64

-- | Hash a string to an 'Epoch'.
hashEpoch :: String -> Epoch
hashEpoch = hashString

-- | Mix a list of 'Epoch's into one (order-sensitive multiply-add
-- fold). Used to fold several component fingerprints into a single
-- token; collision-resistance only needs \"different inputs ⇒ almost
-- surely different output\", which this gives.
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
-- (i.e. \"everything is stale, rewrite all\") on any mismatch or IO
-- error: wrong format version, a different @--gzip@ setting than the
-- last run, a missing\/corrupt file. The @gzip@ argument is the
-- /current/ run's setting.
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
  (do exists <- doesDirectoryExist cacheDir
      _ <- if exists then pure () else createDirectoryIfMissing True cacheDir
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
