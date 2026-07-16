{-# LANGUAGE ScopedTypeVariables #-}
-- | @--incremental@: a per-module fragment cache for the expensive
-- per-definition backend walk.
--
-- A /fragment/ is the @[ADDef]@ 'AgdaDeps.Backend.postModuleAD' returns
-- for one module (dead-private extras included) plus the module's slices
-- of the two side-channels ('IgnoredEdgeMap', 'MethodProviderMap'). A
-- @Skip@ped module's @compileDef@ never runs, so those slices must be
-- cached or its helper edges are lost.
--
-- Cache key: @(fragment format version, content-option fingerprint,
-- iFullHash, nodeKeyVersion)@. 'iFullHash' folds in transitive
-- imported-interface hashes, so a fragment is invalidated exactly when a
-- change can alter this module's elaborated defs.
--
-- Written only from a fresh type-check: a warm interface load exposes a
-- dead-code-pruned signature and loses edges, so caching the fresh
-- fragment keeps output cache-state independent.
--
-- Serialisation rides 'Data.Binary'. Node identity is 'NodeRef' — a
-- precomputed, fully-serialisable value (see 'AgdaDeps.Deps') — so the
-- payload is plain data: no Agda 'EmbPrj', and identical on Agda 2.8 and
-- 2.9 (the cache works on both).
module AgdaDeps.FragmentCache
  ( FragmentData(..)
  , optionsFingerprint
  , fragmentFileFor
  , readFragment
  , writeFragment
  , gcFragments
  ) where

import qualified Control.Exception as E
import Control.Monad ( filterM )
import Control.Monad.IO.Class ( MonadIO, liftIO )
import Data.Binary ( Binary(..) )
import qualified Data.Binary as B
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as L
import Data.Word ( Word64 )
import Numeric ( showHex )
import qualified Data.Set as S
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, listDirectory, removeFile )
import System.FilePath
  ( (</>), takeDirectory, takeExtension, takeFileName )

import Agda.TypeChecking.Monad ( TCM )
import Agda.Utils.Hash ( hashString )

import AgdaDeps.Deps
  ( ADDef, IgnoredEdgeMap, MethodProviderMap, nodeKeyVersion )
import AgdaDeps.Logging ( info )
import AgdaDeps.Options ( Options(..) )

-- | One module's cached compile result.
data FragmentData = FragmentData
  { fragDefs      :: [ADDef]
    -- ^ What 'postModuleAD' returned (the 'Just's), dead-private
    -- extras included.
  , fragIgnored   :: IgnoredEdgeMap
    -- ^ This module's slice of the ignored-def side-channel.
  , fragProviders :: MethodProviderMap
    -- ^ This module's slice of the instance-method providers
    -- side-channel (only binders homed in this module).
  }

instance Binary FragmentData where
  put (FragmentData a b c) = put a *> put b *> put c
  get = FragmentData <$> get <*> get <*> get

-- | Bump whenever the fragment payload shape (or any encoded field's
-- meaning) changes. The side-channel slices must be exact before/after
-- deltas, not name-prefix filters — a filter drops anonymous-module
-- entries no module name prefixes.
--
-- 4: identity is 'NodeRef' serialised via 'Data.Binary' (was a 'QName'
--    'EmbPrj' wire form).
-- 5: derived fields dropped from the payload ('ADDef._deps',
--    'NodeRef.nrHash', both rebuilt on decode); 'NodeRef' stores the
--    unqualified display name, not the full 'prettyShow'.
fragmentFormatVersion :: Word64
fragmentFormatVersion = 5

-- | Fingerprint of every option that changes fragment /content/.
-- Rendering-only options (format, view, colours, externals filtering,
-- snippets, …) are applied in @postCompile@, downstream of the cache,
-- and deliberately excluded.
optionsFingerprint :: Options -> Word64
optionsFingerprint opts = hashString $ show
  ( optExcludeModules opts
  , optWithTermHashes opts
  , optMinTermDepth opts
  , optWithSignatures opts
  , optNormaliseSignatures opts
  , optShowImplicit opts
  )

-- | @\<cacheDir\>/\<sanitised module name\>-\<hash\>.frag@. The hash
-- (over the full module name) is the identity; the sanitised prefix is
-- for human eyes only.
fragmentFileFor :: FilePath -> String -> FilePath
fragmentFileFor cacheDir modName =
  cacheDir </> (prefix ++ "-" ++ hex (hashString modName) ++ ".frag")
  where
    prefix = take 60 (map sanitise modName)
    sanitise c | c `elem` ("/\\:*?\"<>| " :: String) = '_'
               | otherwise                           = c
    hex :: Word64 -> String
    hex w = pad (showHex w "")
    pad s = replicate (16 - length s) '0' ++ s

-- | Delete every @*.frag@ in @cacheDir@ whose module is not in
-- @liveModules@ (gone after a deletion\/rename). Returns the count
-- removed. Failures are swallowed — a GC hiccup must not fail the build.
gcFragments :: MonadIO m => FilePath -> [String] -> m Int
gcFragments cacheDir liveModules = liftIO $ do
  exists <- doesDirectoryExist cacheDir
  if not exists then pure 0 else do
    let liveSet =
          S.fromList
            [ takeFileName (fragmentFileFor cacheDir m) | m <- liveModules ]
    entries <- listDirectory cacheDir `E.catch`
                 \ (_ :: E.IOException) -> pure []
    let stale =
          [ cacheDir </> e
          | e <- entries
          , takeExtension e == ".frag"
          , not (e `S.member` liveSet)
          ]
    removed <- filterM tryRemove stale
    pure (length removed)
  where
    tryRemove p =
      (removeFile p >> pure True)
        `E.catch` \ (_ :: E.IOException) -> pure False

-- ** Key header

-- | Fixed key prefix serialised alongside the payload: a stale key fails
-- the equality check below and reads as a miss.
type Header = (Word64, Word64, Word64, Word64)

header :: Word64 -> Word64 -> Header
header fingerprint fullHash =
  ( fragmentFormatVersion
  , fingerprint
  , fullHash
  , fromIntegral nodeKeyVersion
  )

-- | Look a fragment up by key. 'Nothing' on any mismatch, decode
-- failure, or IO error — a miss, never an abort.
readFragment
  :: FilePath  -- ^ fragment file path ('fragmentFileFor')
  -> Word64    -- ^ expected options fingerprint
  -> Word64    -- ^ expected 'iFullHash'
  -> TCM (Maybe FragmentData)
readFragment path fingerprint fullHash = liftIO $ do
  mbs <- (Just <$> BS.readFile path)
           `E.catch` \ (_ :: E.IOException) -> pure Nothing
  case mbs of
    Nothing -> pure Nothing
    Just bs -> case B.decodeOrFail (L.fromStrict bs) of
      Right (_, _, (hdr, frag))
        | hdr == header fingerprint fullHash -> pure (Just frag)
      _ -> pure Nothing

-- | Write a fragment. Failures are reported as an info-channel
-- breadcrumb and swallowed (a broken cache write must not fail the
-- build).
writeFragment
  :: FilePath  -- ^ fragment file path ('fragmentFileFor')
  -> Word64    -- ^ options fingerprint
  -> Word64    -- ^ 'iFullHash'
  -> FragmentData
  -> TCM ()
writeFragment path fingerprint fullHash frag = do
  ok <- liftIO $
    ( do createDirectoryIfMissing True (takeDirectory path)
         -- 'B.encode' is total; force the bytes inside the guard so any
         -- exception (e.g. disk-full on write) degrades to a breadcrumb.
         L.writeFile path (B.encode (header fingerprint fullHash, frag))
         pure True
    ) `E.catch` \ (_ :: E.SomeException) -> pure False
  if ok then pure () else
    info $ "agda-deps: --incremental: failed to write fragment " ++ path
