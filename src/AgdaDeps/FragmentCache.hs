{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | @--incremental@: a per-module fragment cache for the expensive
-- per-definition backend walk.
--
-- A /fragment/ is the value 'AgdaDeps.Backend.postModuleAD' returns
-- for one module — its final @[ADDef]@ /including/ the recovered
-- dead-private extras — plus the module's contributions to the two
-- compile-time side-channels ('IgnoredEdgeMap', 'MethodProviderMap'),
-- which a @Skip@ped module would otherwise never populate (its
-- @compileDef@ hooks don't run).
--
-- Cache key: @(fragment format version, content-option fingerprint,
-- iFullHash, nodeKeyVersion)@. Agda's 'iFullHash' folds in the
-- transitive imported-interface hashes — the same mechanism that
-- decides @.agdai@ validity — so a fragment is invalidated exactly
-- when a dependency change can alter this module's elaborated defs.
--
-- Fragments are only ever written from a /fresh/ type-check (see the
-- write-side gate in 'AgdaDeps.Backend.postModuleAD'): a warm
-- interface load exposes a dead-code-pruned signature and loses a few
-- edges, so caching the fresh fragment makes output cache-state
-- /independent/ rather than inheriting that non-determinism.
--
-- Serialisation rides Agda's own 'EmbPrj' machinery (the @.agdai@
-- encoder), so 'QName's — 'NameId's, binding-site ranges and all —
-- round-trip exactly; downstream TCM lookups ('getConstInfo') on
-- decoded names behave as if the defs had been compiled this run.
-- The byte-level layer ('Agda.Utils.Serialize') is only exposed by
-- Agda >= 2.9; on 2.8 the cache degrades to "always miss, never
-- write" ('fragmentCacheSupported').
module AgdaDeps.FragmentCache
  ( fragmentCacheSupported
  , FragmentData(..)
  , optionsFingerprint
  , fragmentFileFor
  , readFragment
  , writeFragment
  , gcFragments
  ) where

import qualified Control.Exception as E
import Control.Monad ( filterM )
import Control.Monad.IO.Class ( MonadIO, liftIO )
import Data.Word ( Word64 )
import Numeric ( showHex )
import qualified Data.Set as S
import System.Directory
  ( doesDirectoryExist, listDirectory, removeFile )
import System.FilePath ( (</>), takeExtension, takeFileName )

import Agda.TypeChecking.Monad ( TCM )
import Agda.Utils.Hash ( hashString )

import AgdaDeps.Deps ( ADDef(..), IgnoredEdgeMap, MethodProviderMap )
import AgdaDeps.Options ( Options(..) )

#if MIN_VERSION_Agda(2,9,0)
import Control.Monad.Except ( catchError )
import Control.Monad.Trans.Maybe ( runMaybeT )

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M

import System.Directory ( createDirectoryIfMissing )
import System.FilePath ( takeDirectory )

import Agda.Syntax.Abstract.Name ( QName )
-- 'EmbPrj' lives in Serialise.Base (the umbrella module doesn't
-- re-export it in 2.9); 'encode' / 'decode' are the generic
-- hash-consing layer; 'serialize' / 'deserialize' the byte layer.
import Agda.TypeChecking.Serialise.Base ( EmbPrj )
import qualified Agda.TypeChecking.Serialise as Ser
import Agda.Utils.Serialize ( Serialize, serialize, deserialize )

import AgdaDeps.Deps
  ( DefKind(..), EdgeProv(..), nodeKeyVersion )
import AgdaDeps.Logging ( info )
import AgdaDeps.Options ( DefState(..) )
#endif

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

-- | Bump whenever the fragment payload shape (or the meaning of any
-- encoded field) changes.
--
--   * v1 — initial; side-channel slices were name-prefix filtered
--     (lost anonymous-module entries — do not honour).
--   * v2 — side-channel slices are exact before/after deltas.
fragmentFormatVersion :: Word64
fragmentFormatVersion = 2

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
    -- 'Numeric.showHex' is lowercase, has no leading zeros, and gives
    -- "0" for 0 — identical to the old hand-rolled converter, so the
    -- @.frag@ filenames are unchanged.
    hex :: Word64 -> String
    hex w = pad (showHex w "")
    pad s = replicate (16 - length s) '0' ++ s

-- | Garbage-collect stale fragment files: delete every @*.frag@ in
-- @cacheDir@ whose module name is not in @liveModules@ (modules no
-- longer in the graph after a deletion / rename). Returns the number
-- removed. Version-independent (a 2.8 build never writes fragments, so
-- it finds none); failures are swallowed — a GC hiccup must not fail
-- the build.
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

#if MIN_VERSION_Agda(2,9,0)

-- Real implementation: Agda >= 2.9 exposes the byte-level
-- serialisation layer ('Agda.Utils.Serialize') and a generic
-- 'encode' to its hash-consed 'Encoded' form.

#else

-- Agda 2.8: 'Agda.TypeChecking.Serialise' does not export a
-- byte-level path for arbitrary 'EmbPrj' values ('Encoded' is
-- abstract), so the cache degrades to a no-op: every lookup misses
-- and nothing is written. 'AgdaDeps.Backend' warns once when
-- @--incremental@ is requested on a 2.8 build.

#endif

-- | Whether this build can actually cache ('True' on Agda >= 2.9).
fragmentCacheSupported :: Bool

-- | Look a fragment up by key. 'Nothing' on any mismatch, decode
-- failure, or IO error — a miss, never an abort.
readFragment
  :: FilePath  -- ^ fragment file path ('fragmentFileFor')
  -> Word64    -- ^ expected options fingerprint
  -> Word64    -- ^ expected 'iFullHash'
  -> TCM (Maybe FragmentData)

-- | Write a fragment. Failures are reported as an info-channel
-- breadcrumb and swallowed (a broken cache write must not fail the
-- build).
writeFragment
  :: FilePath  -- ^ fragment file path ('fragmentFileFor')
  -> Word64    -- ^ options fingerprint
  -> Word64    -- ^ 'iFullHash'
  -> FragmentData
  -> TCM ()

#if MIN_VERSION_Agda(2,9,0)

fragmentCacheSupported = True

readFragment path fingerprint fullHash = do
  mbs <- liftIO $
    (Just <$> BS.readFile path) `E.catch` \ (_ :: E.IOException) -> pure Nothing
  case mbs of
    Nothing -> pure Nothing
    Just bs
      | BS.length bs <= headerSize -> pure Nothing
      | otherwise -> do
          let (hdrBytes, body) = BS.splitAt headerSize bs
          mHdr <- liftIO $ tryDeserialize hdrBytes
          case mHdr of
            Just hdr | hdr == header fingerprint fullHash -> do
              mPayload <- decodeBytes body
              pure (fromWire =<< mPayload)
            _ -> pure Nothing

writeFragment path fingerprint fullHash frag = do
  -- 'encode' runs in TCM (a 'TCErr' is conceivable); the file write
  -- can throw IO exceptions. Both degrade to a breadcrumb — a broken
  -- cache write must never fail the build.
  mBody <- (Just <$> encodeBytes (toWire frag))
             `catchError` \ _ -> pure Nothing
  ok <- case mBody of
    Nothing   -> pure False
    Just body -> liftIO $
      ( do hdrBytes <- serialize (header fingerprint fullHash)
           createDirectoryIfMissing True (takeDirectory path)
           BS.writeFile path (hdrBytes <> body)
           pure True
      ) `E.catch` \ (_ :: E.SomeException) -> pure False
  if ok then pure () else
    info $ "agda-deps: --incremental: failed to write fragment " ++ path

-- ** Key header

-- | Fixed-size key prefix: four Word64s, 32 bytes.
type Header = (Word64, Word64, Word64, Word64)

header :: Word64 -> Word64 -> Header
header fingerprint fullHash =
  ( fragmentFormatVersion
  , fingerprint
  , fullHash
  , fromIntegral nodeKeyVersion
  )

headerSize :: Int
headerSize = 32

tryDeserialize :: Serialize a => BS.ByteString -> IO (Maybe a)
tryDeserialize bs =
  (Just <$> deserialize bs)
    `E.catch` \ (E.ErrorCall _) -> pure Nothing

-- ** EmbPrj-friendly wire form
--
-- 'EmbPrj' ships instances for pairs/triples, lists, 'Maybe', 'Int',
-- 'Word64', 'Char' and 'QName', so the payload is expressed in those
-- and the enums ('DefState' / 'DefKind' / 'EdgeProv') become tagged
-- 'Int's. Decoding is total-with-Maybe: an out-of-range tag fails the
-- whole fragment (treated as a miss).

type WireProv    = (QName, Int)
type WireDef     =
  ( (QName, [WireProv])
  , ((Int, Int), Maybe Int)
  , ((Maybe [Word64], Maybe [Int]), Maybe String)
  )
type WirePayload = ([WireDef], ([(QName, [WireProv])], [(QName, [QName])]))

toWire :: FragmentData -> WirePayload
toWire (FragmentData defs ignored providers) =
  ( map defToWire defs
  , ( [ (qn, provsToWire m) | (qn, m) <- M.toList ignored ]
    , M.toList providers
    )
  )
  where
    defToWire d =
      ( (_name d, provsToWire (_depsProv d))
      , ((stateToInt (_state d), kindToInt (_kind d)), _line d)
      , ((_subtermHashes d, _subtermDepths d), _sig d)
      )
    provsToWire m = [ (qn, provToInt p) | (qn, p) <- M.toList m ]

fromWire :: WirePayload -> Maybe FragmentData
fromWire (wdefs, (wignored, wproviders)) = do
  defs    <- mapM defFromWire wdefs
  ignored <- mapM (\ (qn, ps) -> (,) qn <$> provsFromWire ps) wignored
  pure FragmentData
    { fragDefs      = defs
    , fragIgnored   = M.fromList ignored
    , fragProviders = M.fromList wproviders
    }
  where
    defFromWire ((qn, wps), ((st, kd), line), ((hs, ds), sig)) = do
      prov  <- provsFromWire wps
      state <- intToState st
      kind  <- intToKind kd
      pure ADDef
        { _name   = qn
        , _deps   = M.keysSet prov
        , _depsProv = prov
        , _state  = state
        , _kind   = kind
        , _line   = line
        , _access = Nothing  -- back-filled in postCompile, like a fresh def
        , _subtermHashes = hs
        , _subtermDepths = ds
        , _sig    = sig
        }
    provsFromWire ps =
      M.fromList <$> mapM (\ (qn, p) -> (,) qn <$> intToProv p) ps

stateToInt :: DefState -> Int
stateToInt Defined   = 0
stateToInt Postulate = 1
stateToInt Hole      = 2
stateToInt Failed    = 3

intToState :: Int -> Maybe DefState
intToState 0 = Just Defined
intToState 1 = Just Postulate
intToState 2 = Just Hole
intToState 3 = Just Failed
intToState _ = Nothing

kindToInt :: DefKind -> Int
kindToInt DKFunction    = 0
kindToInt DKProjection  = 1
kindToInt DKDatatype    = 2
kindToInt DKRecord      = 3
kindToInt DKConstructor = 4
kindToInt DKPostulate   = 5
kindToInt DKPrimitive   = 6
kindToInt DKOther       = 7

intToKind :: Int -> Maybe DefKind
intToKind 0 = Just DKFunction
intToKind 1 = Just DKProjection
intToKind 2 = Just DKDatatype
intToKind 3 = Just DKRecord
intToKind 4 = Just DKConstructor
intToKind 5 = Just DKPostulate
intToKind 6 = Just DKPrimitive
intToKind 7 = Just DKOther
intToKind _ = Nothing

provToInt :: EdgeProv -> Int
provToInt ESignature = 0
provToInt EBody      = 1
provToInt EWhere     = 2
provToInt EWith      = 3
provToInt EUnknown   = 4

intToProv :: Int -> Maybe EdgeProv
intToProv 0 = Just ESignature
intToProv 1 = Just EBody
intToProv 2 = Just EWhere
intToProv 3 = Just EWith
intToProv 4 = Just EUnknown
intToProv _ = Nothing

-- ** Byte-level plumbing (Agda >= 2.9 only)

encodeBytes :: EmbPrj a => a -> TCM BS.ByteString
encodeBytes a = do
  enc <- Ser.encode a
  liftIO $ serialize enc

decodeBytes :: EmbPrj a => BS.ByteString -> TCM (Maybe a)
decodeBytes bs = do
  mEnc <- liftIO $ tryDeserialize bs
  case mEnc of
    Nothing  -> pure Nothing
    Just enc -> runMaybeT (Ser.decode enc)

#else

fragmentCacheSupported = False
readFragment _ _ _    = pure Nothing
writeFragment _ _ _ _ = pure ()

#endif
