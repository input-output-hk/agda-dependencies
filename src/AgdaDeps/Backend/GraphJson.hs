{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | v2 graph.json schema emitter.
--
-- 'buildGraphJson' emits the packed form (CSR adjacency, base64 typed
-- arrays) consumed by the HTML viewer; 'buildExpandedJson' emits the
-- record-array form for @--json-mode=expanded@. 'buildModuleDetails'
-- produces the per-module detail files for lazy mode. The lazy-ingest
-- filename scheme ('moduleDetailFilename', 'snippetBundleFilename') is
-- shared with "AgdaDeps.Backend.Html".
module AgdaDeps.Backend.GraphJson
  ( -- * Inputs gathered from the backend
    GraphInput(..)

    -- * Outputs
  , GraphJsonOutput(..)
  , ModuleDetailJson(..)

    -- * Externals summary (emitted only under @--no-externals@)
  , ExternalsSummary(..)
  , buildExternalsSummary

    -- * Top-level emission
  , buildGraphJson

    -- * Expanded JSON shape (--json-mode=expanded)
  , buildExpandedJson

    -- * Lazy-ingest filename scheme (shared with "AgdaDeps.Backend.Html")
  , moduleDetailFilename
  , snippetBundleFilename
  ) where

import Control.DeepSeq ( NFData(..) )
import Data.Char ( isAlphaNum, toLower )
import Data.Int ( Int32, Int8 )
import Data.List ( foldl', intercalate, sort, sortBy, sortOn )
import Data.Maybe ( isJust )
import Data.Word ( Word64 )
import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import qualified Data.Sequence as Seq
import Data.Set ( Set )
import qualified Data.Set as S

import Agda.Syntax.Abstract.Name ( QName )
import Agda.Syntax.Common.Pretty ( prettyShow )
import Agda.Utils.Hash ( hashString )

import AgdaDeps.Csr
  ( buildCsr, reverseCsr
  , encodeInt32LE, encodeInt8LE, encodeFloat32LE, encodeWord64LE
  , dedupSortedInt
  )
import AgdaDeps.Deps    ( ADDef(..), DefKind(..), DefAccess(..)
                        , EdgeProv(..)
                        , nodeKey, moduleKey, nodeKeyVersion, hashQName, collectAllQNames )
import BuildInfo        ( buildFingerprint )
import AgdaDeps.Layout  ( Position(..) )
import AgdaDeps.Options ( DefState(..) )
import AgdaDeps.Util    ( jsString )
import AgdaDeps.Backend.Wire
  ( ExpandedGraph(..), WireDef(..), WireEdge(..), WireExternals(..)
  , encodeExpanded, validateExpanded )

-- | Where graph data goes in the lazy split.
data EmitMode
  = EmitInline   -- ^ defs + edges live in graph.json
  | EmitLazy     -- ^ defs + edges live in per-module detail files

-- | Strict per-module {defined, postulate, hole, failed} accumulator
-- used by 'moduleStateCounts'.
data Counts = Counts !Int !Int !Int !Int

-- | Diagnostic summary of the external modules that @--no-externals@
-- stripped from the graph. Emitted at the top level as
-- @externals_summary@ only under @--no-externals@; carried by both
-- @packed@ and @expanded@ modes.
--
-- JSON shape:
--
-- @
--   { "modules": ["Agda.Builtin.Bool", ...],
--     "postulates_by_module": {
--       "Agda.Builtin.Bool": ["true", "false"], ... } }
-- @
data ExternalsSummary = ExternalsSummary
  { esModules            :: !(Set String)
    -- ^ Every module classified external and dropped.
  , esPostulatesByModule :: !(M.Map String [String])
    -- ^ Per dropped module, the *unqualified* postulate names (last
    -- dot-component).
  } deriving (Show)

instance NFData ExternalsSummary where
  rnf (ExternalsSummary ms pm) = rnf ms `seq` rnf pm

-- | Build the externals summary from the def list and the classified
-- external module set. Called from 'postCompileAD' before
-- 'dropExternalDefs', while the postulate defs are still in scope.
buildExternalsSummary :: Set String -> [ADDef] -> ExternalsSummary
buildExternalsSummary externals defs =
  let -- Per external module, accumulate the postulate short-names.
      bumpDef !acc d
        | not isExt           = acc
        | _state d /= Postulate = acc
        | otherwise =
            M.insertWith
              (++)   -- 'new' is always a singleton, so '(++)' == 'head new : old'
              m
              [shortNameOf (prettyShow (_name d))]
              acc
        where
          !m     = moduleKey (_name d)
          isExt  = S.member m externals
      !rawByMod = foldl' bumpDef M.empty defs
      -- Dedup + ascending-sort each list for deterministic wire order.
      !byMod    = M.map (S.toAscList . S.fromList) rawByMod
  in ExternalsSummary
       { esModules            = externals
       , esPostulatesByModule = byMod
       }
  where
    -- Unqualified name: last dot-component, or the whole name if no dot.
    shortNameOf :: String -> String
    shortNameOf s = case break (== '.') (reverse s) of
      (revLast, "")        -> reverse revLast
      (revLast, _revDotty) -> reverse revLast

-- | JSON for 'ExternalsSummary' (packed / @--lazy@ path). The expanded
-- path emits the same shape via @AgdaDeps.Backend.Wire@ — keep the two
-- byte-coherent if this shape changes.
externalsSummaryJson :: ExternalsSummary -> String
externalsSummaryJson (ExternalsSummary mods byMod) =
  "{\"modules\":" ++ stringArrayJson (S.toAscList mods)
  ++ ",\"postulates_by_module\":"
  ++ "{" ++ intercalate ","
         [ jsString k ++ ":" ++ stringArrayJson v
         | (k, v) <- M.toAscList byMod
         ]
  ++ "}"
  ++ "}"

-- | All the inputs the schema emitter needs.
data GraphInput = GraphInput
  { giDefs            :: [ADDef]
  , giStateMap        :: M.Map QName DefState
  , giImportEdges     :: [(String, String)]
  , giSourceFiles     :: [FilePath]
  , giModuleFile      :: M.Map String FilePath
  , giEntryModule     :: Maybe String
  , giExternalModules :: Set String
  , giFailedModules   :: Set String
  , giPositions       :: M.Map QName Position
  , giWithSource      :: Bool
  , giSnippetModules  :: [String]
  , giLazy            :: Bool
  , giExtraModules    :: Set String
    -- ^ Module names to include in the graph even if they have no
    -- defs, no import edges, and aren't the entry. Used by
    -- 'AgdaDeps.SkipAgda' to surface modules discovered by the
    -- source-file scan that happen to be orphans in the import graph.
  , giReExports       :: ![(String, String, [String])]
    -- ^ Per (host-module, source-module) the fully-qualified names the
    -- host module re-exports via @open … public@. Dedup-sorted by the
    -- producer. Emitted in expanded JSON only.
  , giExternalsSummary :: !(Maybe ExternalsSummary)
    -- ^ Diagnostic summary of the externals stripped under
    -- @--no-externals@; carried in both packed and expanded output.
    -- 'Nothing' when @--no-externals@ wasn't passed, in which case the
    -- field is omitted from the JSON.
  , giPackedAnalytical :: !Bool
    -- ^ @--packed-analytical@: augment the packed @defs@ object with the
    -- per-definition analytical arrays (kind / line / access / type /
    -- subterm hashes). Packed (non-lazy) path only; 'False' leaves
    -- packed output byte-identical.
  }

-- | Output of the v2 emitter, ready for the backend to write to disk.
data GraphJsonOutput = GraphJsonOutput
  { gjoGraphJson      :: String
  , gjoModuleDetails  :: [ModuleDetailJson]
  , gjoModuleNames    :: [String]
  }

-- | One per-module detail file in lazy mode.
--
-- 'mdjEpoch' is a cheap content fingerprint (no base64, no JSON
-- assembly) so the incremental-serialise path can skip rewriting a file
-- without forcing the lazy 'mdjContent' thunk. Keep it strict and the
-- content thunk lazy so a skipped file never renders.
data ModuleDetailJson = ModuleDetailJson
  { mdjModuleName :: String
  , mdjFileName   :: FilePath
  , mdjEpoch      :: !Word64
  , mdjContent    :: String
  }

-- ** Emission

buildGraphJson :: GraphInput -> GraphJsonOutput
buildGraphJson GraphInput{..} =
  let mode = if giLazy then EmitLazy else EmitInline

      -- (1) Definition list ---------------------------------------------
      allQNames :: [QName]
      allQNames = collectAllQNames giDefs

      -- Sort by hashQName for deterministic byte output across runs.
      defsList :: [QName]
      defsList = sortOn hashQName allQNames

      -- Edge endpoints index by canonical 'nodeKey' string, not 'QName'
      -- 'Ord' (which distinguishes same-key helpers and re-drops edges).
      defKeyIndexMap :: M.Map String Int
      defKeyIndexMap = M.fromList (zip (map nodeKey defsList) [0..])

      nDefs :: Int
      nDefs = length defsList

      defNames     :: [String]
      defNames     = map nodeKey defsList

      defModuleNames :: [String]
      defModuleNames = map moduleKey defsList

      -- (2) Module list -------------------------------------------------
      -- Union of def modules, import-edge endpoints, the entry module,
      -- failed modules, and extra modules. 'S.toAscList' is sorted.
      modulesSet :: S.Set String
      modulesSet =
        let !s0 = S.fromList defModuleNames
            !s1 = foldl' (\s (a, b) -> S.insert b (S.insert a s)) s0 giImportEdges
            !s2 = case giEntryModule of
                    Just m  -> S.insert m s1
                    Nothing -> s1
            !s3 = S.union s2 giFailedModules
        in S.union s3 giExtraModules

      modules :: [String]
      modules = S.toAscList modulesSet

      moduleIndexMap :: M.Map String Int
      moduleIndexMap = M.fromList (zip modules [0..])

      nModules :: Int
      nModules = length modules

      moduleOf :: QName -> Int
      moduleOf qn = case M.lookup (moduleKey qn) moduleIndexMap of
        Just i  -> i
        Nothing -> -1

      defModuleIdxs :: [Int32]
      defModuleIdxs = [ fromIntegral (moduleOf qn) | qn <- defsList ]

      -- (3) Per-def states + positions ---------------------------------
      defState :: QName -> DefState
      defState qn = M.findWithDefault Defined qn giStateMap

      -- Per-def state, looked up once and shared by 'defStateBytes' and
      -- 'moduleStateCounts' (both walk 'defsList'), rather than hitting
      -- 'giStateMap' twice per def.
      defStates :: [DefState]
      defStates = map defState defsList

      defStateBytes :: [Int8]
      defStateBytes = map encodeDefState defStates

      defPositions :: [(Float, Float)]
      defPositions =
        [ case M.lookup qn giPositions of
            Just p  -> (posX p, posY p)
            Nothing -> (0, 0)
        | qn <- defsList
        ]

      defXs :: [Float]
      defXs = map fst defPositions
      defYs :: [Float]
      defYs = map snd defPositions

      -- (4) File list + module/file maps -------------------------------
      moduleFilePathMap :: M.Map String FilePath
      moduleFilePathMap = giModuleFile

      allFilesSet :: S.Set FilePath
      allFilesSet = S.fromList $
        giSourceFiles ++ M.elems moduleFilePathMap

      files :: [FilePath]
      files = sort (S.toList allFilesSet)

      fileIndexMap :: M.Map FilePath Int
      fileIndexMap = M.fromList (zip files [0..])

      moduleToFile :: [Int32]
      moduleToFile =
        [ case M.lookup m moduleFilePathMap >>= (`M.lookup` fileIndexMap) of
            Just i  -> fromIntegral i
            Nothing -> -1
        | m <- modules
        ]

      fileToModules :: [[Int]]
      fileToModules =
        let byFile = foldl' insertModule IM.empty (zip [0..] modules)
            insertModule acc (mi, m) = case M.lookup m moduleFilePathMap of
              Just p  -> case M.lookup p fileIndexMap of
                Just fi -> IM.insertWith (++) fi [mi] acc
                Nothing -> acc
              Nothing -> acc
        in [ sort (IM.findWithDefault [] i byFile)
           | i <- [0 .. length files - 1]
           ]

      -- (5) Edges --------------------------------------------------------
      adjList :: [(Int, [Int])]
      adjList =
        [ (srcGi, [ ti
                  | t <- S.toList (_deps d)
                  , Just ti <- [M.lookup (nodeKey t) defKeyIndexMap]
                  ])
        | d <- giDefs
        , Just srcGi <- [M.lookup (nodeKey (_name d)) defKeyIndexMap]
        ]

      (outOffsets, outTargets) = buildCsr nDefs adjList
      (inOffsets,  inTargets)  = reverseCsr nDefs adjList

      -- Per-edge provenance, keyed @(srcGi, tgtGi) -> Int8@, for the
      -- byte array aligned to 'outTargets'. Byte encoding: 'encodeEdgeProv'.
      defProvByPair :: IM.IntMap (IM.IntMap Int8)
      defProvByPair = foldl' addDefEdges IM.empty giDefs
        where
          addDefEdges !acc d = case M.lookup (nodeKey (_name d)) defKeyIndexMap of
            Nothing    -> acc
            Just srcGi ->
              let !inner =
                    M.foldlWithKey'
                      (\ !m tgt prov -> case M.lookup (nodeKey tgt) defKeyIndexMap of
                          Nothing -> m
                          Just ti -> IM.insert ti (encodeEdgeProv prov) m)
                      IM.empty
                      (_depsProv d)
              in if IM.null inner
                   then acc
                   else IM.insert srcGi inner acc

      -- Per-edge provenance bytes aligned to 'outTargets'. One pass over
      -- 'outTargets', recovering each source bucket from the bucket-size
      -- list; 'EUnknown' for any miss.
      outTargetsProv :: [Int8]
      outTargetsProv = goBucket 0 bucketSizes outTargets
        where
          -- Adjacent-pair differences over outOffsets give each
          -- bucket's size (0..nDefs-1).
          bucketSizes :: [Int]
          bucketSizes = case outOffsets of
            (o0 : rest) -> zipWith (\a b -> fromIntegral (b - a)) (o0 : rest) rest
            []          -> []

          goBucket :: Int -> [Int] -> [Int32] -> [Int8]
          goBucket _ _ [] = []
          goBucket !_ [] _ = []
          goBucket !srcGi (sz : szs) tgts =
            let !innerMap = IM.findWithDefault IM.empty srcGi defProvByPair
                go n acc ts
                  | n == 0    = (reverse acc, ts)
                  | otherwise = case ts of
                      []      -> (reverse acc, [])
                      (t : r) ->
                        let !b = IM.findWithDefault
                                    (encodeEdgeProv EUnknown)
                                    (fromIntegral t)
                                    innerMap
                        in go (n - 1) (b : acc) r
                (here, after) = go sz [] tgts
            in here ++ goBucket (srcGi + 1) szs after

      -- Skip the def-level transitive reduction (O(V·(V+E))) above this
      -- size. The JS viewer treats an empty 'transitiveEdges' array as
      -- "no reduction precomputed" and shows every edge.
      defTransitiveThreshold :: Int
      defTransitiveThreshold = 3000

      defTransitivePacked :: [Int32]
      defTransitivePacked
        | nDefs > defTransitiveThreshold = []
        | otherwise =
            [ fromIntegral (s * nDefs + t)
            | (s, t) <- transitiveDefEdges adjList
            ]

      -- (6) Module edges -----------------------------------------------
      -- Fold leaf edges directly into a 'Set (Int, Int)' of distinct
      -- module pairs, then add import edges.
      moduleEdgeSet :: S.Set (Int, Int)
      moduleEdgeSet =
        let addLeafEdges !acc d =
              let !sMod = moduleOf (_name d)
              in if sMod < 0 then acc
                 else S.foldl'
                        (\ !s t ->
                          let !tMod = moduleOf t
                          in if tMod < 0 || sMod == tMod
                               then s
                               else S.insert (sMod, tMod) s)
                        acc (_deps d)
            !leafSet = foldl' addLeafEdges S.empty giDefs
            addImpEdge !acc (s, t) =
              case M.lookup s moduleIndexMap of
                Nothing -> acc
                Just i  -> case M.lookup t moduleIndexMap of
                  Nothing -> acc
                  Just j
                    | i == j    -> acc
                    | otherwise -> S.insert (i, j) acc
        in foldl' addImpEdge leafSet giImportEdges

      moduleEdgePairs :: [(Int, Int)]
      moduleEdgePairs = S.toAscList moduleEdgeSet

      transitiveModuleEdgePairs :: [(Int, Int)]
      transitiveModuleEdgePairs =
        transitiveEdgesInt moduleEdgePairs

      -- (7) Module states ----------------------------------------------
      moduleStateBytes :: [Int8]
      moduleStateBytes =
        [ if S.member m giFailedModules then 1 else 0
        | m <- modules
        ]

      -- (7b) Per-module {defined, postulate, hole, failed} counts ------
      -- Lets views render a per-module state-mix bar without
      -- re-scanning every def in JS.
      moduleStateCounts :: [[Int]]
      moduleStateCounts =
        let zero = Counts 0 0 0 0
            bump (Counts d p h f) s = case s of
              Defined   -> Counts (d + 1) p       h       f
              Postulate -> Counts d       (p + 1) h       f
              Hole      -> Counts d       p       (h + 1) f
              Failed    -> Counts d       p       h       (f + 1)
            byMod = foldl' addQ M.empty (zip defsList defStates)
              where
                addQ !acc (qn, !st) =
                  let !m = moduleKey qn
                  in M.insertWith add4 m (bump zero st) acc
                add4 (Counts a b c d) (Counts e f g h) =
                  Counts (a + e) (b + f) (c + g) (d + h)
            tup m = M.findWithDefault zero m byMod
            withFailed m =
              let !c0@(Counts d p h f) = tup m
              in if S.member m giFailedModules
                   then Counts d p h (f + 1)
                   else c0
        in [ let Counts d p h f = withFailed m in [d, p, h, f] | m <- modules ]

      -- (7c) Topological depth from entry per module -------------------
      -- BFS from the entry module's index over the module edge set.
      -- -1 for modules unreachable from the entry, or when no entry is
      -- known.
      moduleDepth :: [Int32]
      moduleDepth = case giEntryModule >>= (`M.lookup` moduleIndexMap) of
        Nothing       -> replicate nModules (-1)
        Just entryIdx ->
          let adj :: IM.IntMap IS.IntSet
              adj = IM.fromListWith IS.union
                [ (s, IS.singleton t) | (s, t) <- moduleEdgePairs ]
              depths = bfsDepths adj entryIdx
          in [ fromIntegral (IM.findWithDefault (-1) i depths)
             | i <- [0 .. nModules - 1]
             ]

      -- (7d) Module-DAG layout for the big-module-dag-pods view --------
      -- Pre-computed pod bounding boxes (x, y, width, height) per
      -- module, packed as a flat Float32 array of length 4 * nModules.
      -- Rank assignment from sources (in-degree 0), then column-pack
      -- within each rank centred on x=0, with fixed pod width /
      -- collapsed height. O(V+E).
      modulePodLayout :: [Float]
      modulePodLayout = buildModuleDagLayout nModules moduleEdgePairs

      -- (8) Externals ---------------------------------------------------
      externalModuleIdxs :: [Int32]
      externalModuleIdxs = sort
        [ fromIntegral i
        | (i, m) <- zip [0..] modules
        , S.member m giExternalModules
        ]

      -- (9) Trees -------------------------------------------------------
      fileTreeJson :: String
      fileTreeJson = renderFileTree files

      moduleTreeJson :: String
      moduleTreeJson = renderModuleTree modules

      -- (10) Bundle / module-detail filename maps ----------------------
      moduleFilesMap :: M.Map String FilePath
      moduleFilesMap
        | giLazy    = M.fromList
            [ (m, "modules/" ++ moduleDetailFilename m) | m <- modules ]
        | otherwise = M.empty

      bundleFilesMap :: M.Map String FilePath
      bundleFilesMap
        | giWithSource = M.fromList
            [ (m, "snippets/" ++ snippetBundleFilename m)
            | m <- giSnippetModules
            ]
        | otherwise = M.empty

      -- (11) Search index ----------------------------------------------
      (searchNames, searchKinds, searchBigrams) =
        buildSearchIndex modules defNames

      -- (12) Module detail files (lazy mode) ---------------------------
      moduleDetails :: [ModuleDetailJson]
      moduleDetails
        | giLazy = buildModuleDetails
                     defsList moduleOf adjList
                     defStateBytes defXs defYs moduleIndexMap
                     giExternalModules giFailedModules giExternalsSummary
        | otherwise = []

      -- (13) Assemble graph.json --------------------------------------
      analyticalSuffix
        | giPackedAnalytical = packedAnalyticalJson defsList giDefs
        | otherwise          = ""

      defsJson = case mode of
        EmitInline ->
          ",\"defs\":" ++ defsObjectJson defNames defModuleIdxs defStateBytes defXs defYs analyticalSuffix
        EmitLazy   -> ""

      edgesJson = case mode of
        EmitInline ->
          ",\"edges\":" ++ edgesObjectJson outOffsets outTargets inOffsets inTargets
        EmitLazy   -> ""

      -- Per-edge 'EdgeProv' as packed int8, parallel to 'outTargets'.
      -- Inline mode only.
      defEdgesProvJson = case mode of
        EmitInline ->
          ",\"definitionEdgesProvenance\":" ++ jsB64Int8 outTargetsProv
        EmitLazy   -> ""

      transitiveJson = case mode of
        EmitInline ->
          ",\"transitiveEdges\":" ++ jsB64Int32 defTransitivePacked
        EmitLazy   -> ""

      -- Optional diagnostic field; absent when @--no-externals@ wasn't
      -- passed.
      externalsSummaryField = case giExternalsSummary of
        Just es -> ",\"externals_summary\":" ++ externalsSummaryJson es
        Nothing -> ""

      graphJson = "{\"v\":2"
        ++ ",\"nodeKeyVersion\":" ++ show nodeKeyVersion
        ++ ",\"producer\":"     ++ jsString buildFingerprint
        ++ ",\"modules\":"      ++ stringArrayJson modules
        ++ ",\"files\":"        ++ stringArrayJson files
        ++ ",\"moduleToFile\":" ++ jsB64Int32 moduleToFile
        ++ ",\"fileToModules\":" ++ intArrayArrayJson fileToModules
        ++ defsJson
        ++ edgesJson
        ++ defEdgesProvJson
        ++ transitiveJson
        ++ ",\"moduleEdges\":" ++ pairArrayJson moduleEdgePairs
        ++ ",\"transitiveModuleEdges\":" ++ pairArrayJson transitiveModuleEdgePairs
        ++ ",\"moduleStates\":" ++ jsB64Int8 moduleStateBytes
        ++ ",\"moduleStateCounts\":" ++ intArrayArrayJson moduleStateCounts
        ++ ",\"moduleDepth\":" ++ jsB64Int32 moduleDepth
        ++ ",\"modulePodLayout\":" ++ jsB64Float32 modulePodLayout
        ++ ",\"fileTree\":"     ++ fileTreeJson
        ++ ",\"moduleTree\":"   ++ moduleTreeJson
        ++ ",\"entryModule\":"  ++ maybe "null" jsString giEntryModule
        ++ ",\"externalModules\":" ++ jsB64Int32 externalModuleIdxs
        ++ (if M.null bundleFilesMap then "" else
            ",\"bundleFiles\":" ++ stringMapJson bundleFilesMap)
        ++ (if M.null moduleFilesMap then "" else
            ",\"moduleFiles\":" ++ stringMapJson moduleFilesMap)
        ++ ",\"searchIndex\":" ++ searchIndexJson searchNames searchKinds searchBigrams
        ++ externalsSummaryField
        ++ "}"

  in GraphJsonOutput
       { gjoGraphJson     = graphJson
       , gjoModuleDetails = moduleDetails
       , gjoModuleNames   = modules
       }

-- ** Per-module detail emission

-- | Build per-module detail JSON files for lazy mode. One
-- 'ModuleDetailJson' per /real/ module (>=1 kept def) plus a
-- /placeholder/ file for every module with no kept defs (so lazy-mode
-- fetches don't 404).
--
-- A placeholder matches a normal detail file plus:
--
-- * @"placeholder": true@ — discriminator the consumer JS reads.
-- * @"module": "<name>"@ — for display.
-- * @"reason": "external" | "failed" | "filtered"@ — why no kept defs:
--   external = outside the project root; failed = type-check raised
--   @TCErr@ under @--keep-going@; filtered = every def dropped by
--   'ignoreDef' / privacy filtering.
-- * @"externalPostulates": […]@ — for @"external"@ modules that
--   'ExternalsSummary' tagged. Absent otherwise.
buildModuleDetails
  :: [QName]
  -> (QName -> Int)
  -> [(Int, [Int])]
  -> [Int8]
  -> [Float]
  -> [Float]
  -> M.Map String Int
  -> S.Set String           -- ^ externalModules (from 'GraphInput').
  -> S.Set String           -- ^ failedModules (from 'GraphInput').
  -> Maybe ExternalsSummary -- ^ for @"externalPostulates"@ on stubs.
  -> [ModuleDetailJson]
buildModuleDetails defsList moduleOfQ adjList stateBytes xs ys moduleIndexMap
                   externalMods failedMods mExtSummary =
  let defsArr     :: IM.IntMap QName
      defsArr     = IM.fromList (zip [0..] defsList)

      statesArr   :: IM.IntMap Int8
      statesArr   = IM.fromList (zip [0..] stateBytes)

      xsArr       :: IM.IntMap Float
      xsArr       = IM.fromList (zip [0..] xs)

      ysArr       :: IM.IntMap Float
      ysArr       = IM.fromList (zip [0..] ys)

      outByDef :: IM.IntMap [Int]
      outByDef = IM.fromList adjList

      indexToModule :: IM.IntMap String
      indexToModule = IM.fromList
        [ (i, m) | (m, i) <- M.toList moduleIndexMap ]

      -- Group def indices by their module index.
      defsByModule :: IM.IntMap [Int]
      defsByModule = foldl' insertDef IM.empty (zip [0..] defsList)
        where
          insertDef acc (gi, qn) =
            let mi = moduleOfQ qn
            in if mi < 0 then acc
               else IM.insertWith (++) mi [gi] acc

      moduleOfDef :: Int -> Int
      moduleOfDef gi = case IM.lookup gi defsArr of
        Just qn -> moduleOfQ qn
        Nothing -> -1

      -- Structured inputs to a real module's detail file, shared by the
      -- content renderer and the cheap epoch so the epoch fingerprints
      -- exactly what gets written.
      realInputs :: [Int] -> ([String], [Int8], [Float], [Float], [(Int, Int, Int)])
      realInputs giList =
        let sortedGis = sort giList
            names  = [ nodeKey (defsArr IM.! gi) | gi <- sortedGis ]
            stsM   = [ statesArr IM.! gi | gi <- sortedGis ]
            xsM    = [ xsArr     IM.! gi | gi <- sortedGis ]
            ysM    = [ ysArr     IM.! gi | gi <- sortedGis ]
            outEs  = concat
              [ [ (li, tgtGi, moduleOfDef tgtGi)
                | tgtGi <- IM.findWithDefault [] srcGi outByDef
                ]
              | (li, srcGi) <- zip [0..] sortedGis
              ]
        in (names, stsM, xsM, ysM, outEs)

      renderReal :: ([String], [Int8], [Float], [Float], [(Int, Int, Int)]) -> String
      renderReal (names, stsM, xsM, ysM, outEs) =
        "{\"defs\":" ++ defsObjectJsonModule names stsM xsM ysM
        ++ ",\"outEdges\":" ++ outEdgesJson outEs
        ++ "}"

      -- Cheap content fingerprint of a real module's detail file (hashes
      -- the structured inputs, no base64/JSON assembly). Separators keep
      -- distinct field contents from colliding.
      realEpoch :: ([String], [Int8], [Float], [Float], [(Int, Int, Int)]) -> Word64
      realEpoch (names, stsM, xsM, ysM, outEs) =
        hashString $ concat
          [ "R\f", intercalate "\f" names
          , "\v", show stsM, "\v", show xsM, "\v", show ysM
          , "\v", show outEs ]

      placeholderEpoch :: String -> String -> [String] -> Word64
      placeholderEpoch m reason ps =
        hashString $ concat [ "P\f", m, "\v", reason, "\v", intercalate "\f" ps ]

      realDetails :: [ModuleDetailJson]
      !realDetails =
        [ ModuleDetailJson
            { mdjModuleName = m
            , mdjFileName   = moduleDetailFilename m
            , mdjEpoch      = realEpoch ins
            , mdjContent    = renderReal ins
            }
        | (mi, gis) <- IM.toList defsByModule
        , Just m <- [IM.lookup mi indexToModule]
        , let ins = realInputs gis
        ]

      -- Modules listed in 'moduleIndexMap' with zero kept defs; each
      -- gets a placeholder detail file per the rules on
      -- 'buildModuleDetails'.
      modulesWithDefsIdx :: IM.IntMap ()
      !modulesWithDefsIdx = IM.map (const ()) defsByModule

      classifyEmpty :: String -> String
      classifyEmpty m
        | S.member m failedMods   = "failed"
        | S.member m externalMods = "external"
        | otherwise               = "filtered"

      externalPostulatesFor :: String -> [String]
      externalPostulatesFor m = case mExtSummary of
        Just (ExternalsSummary _ byMod) ->
          M.findWithDefault [] m byMod
        Nothing -> []

      renderPlaceholder :: String -> String
      renderPlaceholder m =
        let !reason = classifyEmpty m
            !ps     = externalPostulatesFor m
            extField
              | null ps   = ""
              | otherwise = ",\"externalPostulates\":" ++ stringArrayJson ps
        in "{\"defs\":"     ++ defsObjectJsonModule [] [] [] []
        ++ ",\"outEdges\":" ++ outEdgesJson []
        ++ ",\"placeholder\":true"
        ++ ",\"module\":"   ++ jsString m
        ++ ",\"reason\":"   ++ jsString reason
        ++ extField
        ++ "}"

      placeholderDetails :: [ModuleDetailJson]
      !placeholderDetails =
        [ ModuleDetailJson
            { mdjModuleName = m
            , mdjFileName   = moduleDetailFilename m
            , mdjEpoch      = placeholderEpoch m (classifyEmpty m) (externalPostulatesFor m)
            , mdjContent    = renderPlaceholder m
            }
        | (m, mi) <- M.toAscList moduleIndexMap
        , not (IM.member mi modulesWithDefsIdx)
        ]
  in realDetails ++ placeholderDetails

-- ** JSON shape helpers

-- | The packed @defs@ object. @analytical@ is the optional
-- @--packed-analytical@ suffix, spliced before the closing brace; @""@
-- for the default (byte-identical) form.
defsObjectJson :: [String] -> [Int32] -> [Int8] -> [Float] -> [Float] -> String -> String
defsObjectJson names mods states xs ys analytical =
  "{\"names\":"      ++ stringArrayJson names
  ++ ",\"modules\":" ++ jsB64Int32   mods
  ++ ",\"states\":"  ++ jsB64Int8    states
  ++ ",\"x\":"       ++ jsB64Float32 xs
  ++ ",\"y\":"       ++ jsB64Float32 ys
  ++ analytical
  ++ "}"

-- | The @--packed-analytical@ @defs@ suffix: per-definition kind / line
-- / access arrays (always), the type array (under @--with-signatures@),
-- and the CSR-packed subterm hashes\/depths (under @--with-term-hashes@).
-- Keyed by QName over @defsList@ via the shared 'mkDef*' lookups so it
-- agrees with the expanded form node-for-node; @types@=@null@ /
-- @access@=@0@ for QNames with no local 'ADDef' match expanded's
-- omission of those keys.
packedAnalyticalJson :: [QName] -> [ADDef] -> String
packedAnalyticalJson defsList defs =
  ",\"kinds\":"  ++ jsB64Int8  kinds
  ++ ",\"lines\":"  ++ jsB64Int32 lns
  ++ ",\"access\":" ++ jsB64Int8  accs
  ++ typesField
  ++ subtermFields
  where
    defKind   = mkDefKind   defs
    defLine   = mkDefLine   defs
    defAccess = mkDefAccess defs
    defSig    = mkDefSig    defs
    hashesByQ = mkDefHashes defs
    depthsByQ = mkDefDepths defs

    kinds = [ encodeDefKind (defKind qn) | qn <- defsList ]
    lns   = [ maybe (-1) fromIntegral (defLine qn) | qn <- defsList ] :: [Int32]
    accs  = [ encodeDefAccess (defAccess qn) | qn <- defsList ]
    sigs  = [ defSig qn | qn <- defsList ]

    typesField
      | any isJust sigs = ",\"types\":" ++ stringOrNullArrayJson sigs
      | otherwise       = ""

    subtermFields
      | M.null hashesByQ = ""
      | otherwise =
          let perHashes = [ M.findWithDefault [] qn hashesByQ | qn <- defsList ]
              perDepths = [ M.findWithDefault [] qn depthsByQ | qn <- defsList ]
              offs = scanl (+) 0
                       (map (fromIntegral . length) perHashes) :: [Int32]
              flatH = concat perHashes :: [Word64]
              flatD = map fromIntegral (concat perDepths) :: [Int32]
          in ",\"subtermOffsets\":" ++ jsB64Int32 offs
          ++ ",\"subtermHashes\":"  ++ jsString (encodeWord64LE flatH)
          ++ ",\"subtermDepths\":"  ++ jsB64Int32 flatD

-- | JSON array of strings-or-@null@ (one per def, parallel to names).
stringOrNullArrayJson :: [Maybe String] -> String
stringOrNullArrayJson xs =
  "[" ++ intercalate "," (map (maybe "null" jsString) xs) ++ "]"

defsObjectJsonModule :: [String] -> [Int8] -> [Float] -> [Float] -> String
defsObjectJsonModule names states xs ys =
  "{\"names\":"      ++ stringArrayJson names
  ++ ",\"states\":"  ++ jsB64Int8    states
  ++ ",\"x\":"       ++ jsB64Float32 xs
  ++ ",\"y\":"       ++ jsB64Float32 ys
  ++ "}"

edgesObjectJson :: [Int32] -> [Int32] -> [Int32] -> [Int32] -> String
edgesObjectJson outOff outTgt inOff inTgt =
  "{\"outOffsets\":"   ++ jsB64Int32 outOff
  ++ ",\"outTargets\":" ++ jsB64Int32 outTgt
  ++ ",\"inOffsets\":"  ++ jsB64Int32 inOff
  ++ ",\"inTargets\":"  ++ jsB64Int32 inTgt
  ++ "}"

outEdgesJson :: [(Int, Int, Int)] -> String
outEdgesJson xs = "[" ++ intercalate "," (map one xs) ++ "]"
  where
    one (a, b, c) = "[" ++ show a ++ "," ++ show b ++ "," ++ show c ++ "]"

stringArrayJson :: [String] -> String
stringArrayJson xs = "[" ++ intercalate "," (map jsString xs) ++ "]"

stringMapJson :: M.Map String FilePath -> String
stringMapJson m =
  "{" ++ intercalate ","
    [ jsString k ++ ":" ++ jsString v | (k, v) <- M.toList m ]
  ++ "}"

pairArrayJson :: [(Int, Int)] -> String
pairArrayJson xs = "[" ++ intercalate "," (map p xs) ++ "]"
  where
    p (a, b) = "[" ++ show a ++ "," ++ show b ++ "]"

intArrayArrayJson :: [[Int]] -> String
intArrayArrayJson xss = "[" ++ intercalate "," (map row xss) ++ "]"
  where
    row xs = "[" ++ intercalate "," (map show xs) ++ "]"

jsB64Int32 :: [Int32] -> String
jsB64Int32 = jsString . encodeInt32LE

jsB64Int8 :: [Int8] -> String
jsB64Int8 = jsString . encodeInt8LE

jsB64Float32 :: [Float] -> String
jsB64Float32 = jsString . encodeFloat32LE

-- ** State encoding

encodeDefState :: DefState -> Int8
encodeDefState Defined   = 0
encodeDefState Postulate = 1
encodeDefState Hole      = 2
encodeDefState Failed    = 3

-- | Wire encoding for 'DefKind' in the packed-analytical @defs.kinds@
-- array. Must mirror 'AgdaDeps.Backend.Wire.wireKind''s string ordering
-- so the consumer maps the byte back to the same @kind@ the expanded
-- form emits.
encodeDefKind :: DefKind -> Int8
encodeDefKind DKFunction    = 0
encodeDefKind DKProjection  = 1
encodeDefKind DKDatatype    = 2
encodeDefKind DKRecord      = 3
encodeDefKind DKConstructor = 4
encodeDefKind DKPostulate   = 5
encodeDefKind DKPrimitive   = 6
encodeDefKind DKOther       = 7

-- | Wire encoding for @defs.access@. MUST stay 3-valued
-- (0 unknown\/absent, 1 public, 2 private): @0@ round-trips to
-- expanded's omission of @access@ for QNames with no local 'ADDef', so
-- external nodes match node-for-node.
encodeDefAccess :: Maybe DefAccess -> Int8
encodeDefAccess Nothing          = 0
encodeDefAccess (Just AccPublic) = 1
encodeDefAccess (Just AccPrivate) = 2

-- ** Per-QName analytical lookups (shared by packed-analytical + expanded)
--
-- Both forms key these by 'QName' over the same @defsList@, so a QName
-- with no local 'ADDef' gets the same default in both — this is what
-- keeps packed-analytical node-for-node identical to expanded. Do not
-- inline these back per-form.

-- | Structural kind by QName; 'DKOther' for QNames with no 'ADDef'.
mkDefKind :: [ADDef] -> (QName -> DefKind)
mkDefKind defs =
  let !m = M.fromList [ (_name d, _kind d) | d <- defs ]
  in \qn -> M.findWithDefault DKOther qn m

-- | Source line by QName; 'Nothing' for QNames with no 'ADDef' / no line.
mkDefLine :: [ADDef] -> (QName -> Maybe Int)
mkDefLine defs =
  let !m = M.fromList [ (_name d, ln) | d <- defs, Just ln <- [_line d] ]
  in (`M.lookup` m)

-- | Access by QName; 'Nothing' for QNames with no 'ADDef'.
mkDefAccess :: [ADDef] -> (QName -> Maybe DefAccess)
mkDefAccess defs =
  let !m = M.fromList [ (_name d, a) | d <- defs, Just a <- [_access d] ]
  in (`M.lookup` m)

-- | Rendered signature by QName ('--with-signatures'); 'Nothing' otherwise.
mkDefSig :: [ADDef] -> (QName -> Maybe String)
mkDefSig defs =
  let !m = M.fromList [ (_name d, s) | d <- defs, Just s <- [_sig d] ]
  in (`M.lookup` m)

-- | Subterm-hash map by QName ('--with-term-hashes'); empty when off.
mkDefHashes :: [ADDef] -> M.Map QName [Word64]
mkDefHashes defs =
  M.fromList [ (_name d, hs) | d <- defs, Just hs <- [_subtermHashes d] ]

-- | Subterm-depth map by QName, parallel to 'mkDefHashes'.
mkDefDepths :: [ADDef] -> M.Map QName [Int]
mkDefDepths defs =
  M.fromList [ (_name d, ds) | d <- defs, Just ds <- [_subtermDepths d] ]

-- | Wire encoding for 'EdgeProv' in the packed JSON form.
encodeEdgeProv :: EdgeProv -> Int8
encodeEdgeProv ESignature   = 0
encodeEdgeProv EBody        = 1
encodeEdgeProv EModuleLocal = 2
encodeEdgeProv EWith        = 3
encodeEdgeProv EUnknown     = 4

-- ** File tree

renderFileTree :: [FilePath] -> String
renderFileTree files =
  let tokens :: [(FilePath, [String])]
      tokens = [ (f, splitPath' f) | f <- files ]

      -- Set-based dedup avoids the O(n^2) of 'nub'.
      allPaths :: [[String]]
      allPaths = S.toAscList . S.fromList $
        concatMap (\(_, comps) -> filter (not . null) (inits' comps)) tokens

      fileLookup :: M.Map [String] FilePath
      fileLookup = M.fromList [ (comps, f) | (f, comps) <- tokens ]

      fileIndex :: M.Map FilePath Int
      fileIndex = M.fromList (zip files [0..])

      treeIdx :: M.Map [String] Int
      treeIdx = M.fromList (zip allPaths [0..])

      parentOf :: [String] -> Int
      parentOf [] = -1
      parentOf comps = case init comps of
        [] -> -1
        p  -> M.findWithDefault (-1) p treeIdx

      entry :: [String] -> String
      entry comps =
        let name = if null comps then "" else last comps
            parent = parentOf comps
            fIdx = case M.lookup comps fileLookup of
              Just f  -> show (M.findWithDefault (-1) f fileIndex)
              Nothing -> "null"
        in "{\"name\":" ++ jsString name
        ++ ",\"parent\":" ++ show parent
        ++ ",\"fileIndex\":" ++ fIdx
        ++ "}"
  in "[" ++ intercalate "," (map entry allPaths) ++ "]"

inits' :: [a] -> [[a]]
inits' []     = [[]]
inits' (x:xs) = [] : map (x:) (inits' xs)

splitPath' :: FilePath -> [String]
splitPath' = filter (not . null) . splitOn '/'

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (chunk, [])     -> [chunk]
  (chunk, _:rest) -> chunk : splitOn c rest

-- ** Module tree

renderModuleTree :: [String] -> String
renderModuleTree modules =
  let moduleIdx :: M.Map String Int
      moduleIdx = M.fromList (zip modules [0..])

      -- Set-dedup over the union of prefixes and module names.
      prefixSet :: S.Set String
      prefixSet = foldl'
        (\acc m -> foldl' (flip S.insert) acc (properPrefixes m))
        S.empty modules

      treeNames :: [String]
      treeNames = S.toAscList (foldl' (flip S.insert) prefixSet modules)

      treeIdx :: M.Map String Int
      treeIdx = M.fromList (zip treeNames [0..])

      parentOf :: String -> Int
      parentOf m = case reverse (properPrefixes m) of
        []     -> -1
        (p:ps) -> case M.lookup p treeIdx of
          Just i  -> i
          Nothing -> findFirst ps
        where
          findFirst []     = -1
          findFirst (q:qs) = case M.lookup q treeIdx of
            Just i  -> i
            Nothing -> findFirst qs

      lastComponent :: String -> String
      lastComponent s = case reverse (splitOn '.' s) of
        []    -> s
        (x:_) -> x

      entry :: String -> String
      entry name =
        "{\"name\":" ++ jsString (lastComponent name)
        ++ ",\"parent\":" ++ show (parentOf name)
        ++ ",\"moduleIndex\":" ++ maybe "null" show (M.lookup name moduleIdx)
        ++ "}"

  in "[" ++ intercalate "," (map entry treeNames) ++ "]"

properPrefixes :: String -> [String]
properPrefixes "" = []
properPrefixes s  = go [] [] s
  where
    go acc _   []       = reverse acc
    go acc cur (c:cs)
      | c == '.'  =
          let prefix = reverse cur
          in go (prefix : acc) (c : cur) cs
      | otherwise = go acc (c : cur) cs

-- ** Search index

buildSearchIndex :: [String] -> [String] -> ([String], [Int8], M.Map String [Int])
buildSearchIndex modules defs =
  let modLower = map (map toLower) modules
      defLower = map (map toLower) defs
      names    = modLower ++ defLower
      kinds    = replicate (length modLower) 0 ++ replicate (length defLower) 1

      bigramsOf :: String -> [String]
      bigramsOf s
        | length s < 2 = []
        | otherwise    = zipWith (\a b -> [a, b]) s (tail s)

      -- Build the posting lists with O(1) cons per insert, then sort +
      -- dedup once per bigram.
      bigramMap :: M.Map String [Int]
      bigramMap
        -- Above 'bigramThreshold' total names, emit an empty map; the
        -- JS search falls back to a linear scan over 'names'.
        | length names > bigramThreshold = M.empty
        | otherwise = M.map dedupSortedInt $
            foldl' insertNameBigrams M.empty (zip [0..] names)
        where
          insertNameBigrams !acc (i, name) =
            foldl' (\m bg -> M.insertWith (++) bg [i] m)
                   acc
                   (S.toList (S.fromList (bigramsOf name)))

  in (names, kinds, bigramMap)

-- | Above this many combined module+def names the bigram postings map
-- is skipped; the JS falls back to a linear scan over 'names'.
bigramThreshold :: Int
bigramThreshold = 50000

searchIndexJson :: [String] -> [Int8] -> M.Map String [Int] -> String
searchIndexJson names kinds bigrams =
  "{\"names\":"      ++ stringArrayJson names
  ++ ",\"kinds\":"   ++ jsB64Int8 kinds
  ++ ",\"bigrams\":" ++ bigramObj
  ++ "}"
  where
    bigramObj =
      "{" ++ intercalate ","
        [ jsString bg ++ ":[" ++ intercalate "," (map show is) ++ "]"
        | (bg, is) <- M.toList bigrams
        ]
      ++ "}"

-- ** Filename helpers

-- | Filesystem-safe filename for a module: the module name verbatim
-- when every character is safe, else a @\<prefix\>\<hash\>@ fallback.
-- The lazy-ingest manifest and the on-disk files both derive names
-- through this.
safeFilename :: String -> String -> FilePath
safeFilename prefix m
  | all isSafeChar m && not (null m) = m ++ ".json"
  | otherwise = prefix ++ show (hashString m) ++ ".json"
  where
    isSafeChar c = isAlphaNum c || c == '.' || c == '_' || c == '-'

moduleDetailFilename :: String -> FilePath
moduleDetailFilename = safeFilename "detail-"

snippetBundleFilename :: String -> FilePath
snippetBundleFilename = safeFilename "bundle-"

-- ** Transitive-edge helpers

-- | Definition-level transitive reduction over an adjacency list.
transitiveDefEdges :: [(Int, [Int])] -> [(Int, Int)]
transitiveDefEdges adjList =
  let adj :: IM.IntMap IS.IntSet
      adj = IM.fromListWith IS.union
        [ (s, IS.fromList ts) | (s, ts) <- adjList, not (null ts) ]

      reach :: IM.IntMap IS.IntSet
      reach = IM.fromList [ (u, bfsFrom adj u) | u <- IM.keys adj ]

      isTransitive u v =
        let others = IS.delete v (IM.findWithDefault IS.empty u adj)
        in any (\w -> IS.member v (IM.findWithDefault IS.empty w reach))
               (IS.toList others)

  in [ (s, t)
     | (s, ts) <- adjList
     , t <- ts
     , isTransitive s t
     ]

transitiveEdgesInt :: [(Int, Int)] -> [(Int, Int)]
transitiveEdgesInt edges =
  let adj :: IM.IntMap IS.IntSet
      adj = IM.fromListWith IS.union
        [ (s, IS.singleton t) | (s, t) <- edges ]

      reach :: IM.IntMap IS.IntSet
      reach = IM.fromList [ (u, bfsFrom adj u) | u <- IM.keys adj ]

      isTransitive u v =
        let others = IS.delete v (IM.findWithDefault IS.empty u adj)
        in any (\w -> IS.member v (IM.findWithDefault IS.empty w reach))
               (IS.toList others)

  in [ (s, t) | (s, t) <- edges, isTransitive s t ]

-- | Reachable set from @start@ via a stack-style traversal (no level
-- order).
bfsFrom :: IM.IntMap IS.IntSet -> Int -> IS.IntSet
bfsFrom adj start = go IS.empty [start]
  where
    go !visited [] = visited
    go !visited (cur : rest)
      | IS.member cur visited = go visited rest
      | otherwise =
          let neighbors = IM.findWithDefault IS.empty cur adj
              !rest' = IS.foldr (:) rest neighbors
          in go (IS.insert cur visited) rest'

-- | BFS distances from a single source, as a map node -> depth. The
-- source has depth 0; unreachable nodes are omitted. Uses a 'Seq'
-- queue for amortised-constant enqueue.
bfsDepths :: IM.IntMap IS.IntSet -> Int -> IM.IntMap Int
bfsDepths adj start = go (IM.singleton start 0) (Seq.singleton (start, 0))
  where
    go !acc q = case Seq.viewl q of
      Seq.EmptyL -> acc
      (cur, d) Seq.:< rest ->
        let neighbors = IM.findWithDefault IS.empty cur adj
            (acc', next) = IS.foldl' step (acc, rest) neighbors
            step (!m, !qq) n
              | IM.member n m = (m, qq)
              | otherwise     = (IM.insert n (d + 1) m, qq Seq.|> (n, d + 1))
        in go acc' next

-- ** Module-DAG layout (for the big-module-dag-pods view)

-- | Pod dimensions (graph-space units, also used as device pixels at
-- zoom = 1). Shared with the JS template.
podWidth, podHeight, podColGap, podRowGap :: Float
podWidth  = 200
podHeight = 52
podColGap = 30
podRowGap = 80

-- | Compute a top-down DAG layout for the module-level graph and
-- pack it as @[x0, y0, w0, h0, x1, y1, w1, h1, …]@ (flat 'Float'
-- list, one quadruple per module in module-index order).
--
-- Longest-path rank assignment via Kahn's topological order. Within
-- each rank, modules are column-packed centred on @x = 0@, sorted by
-- index. Rows stack top-to-bottom with a uniform 'podRowGap'
-- separator. @O(V + E)@.
buildModuleDagLayout :: Int -> [(Int, Int)] -> [Float]
buildModuleDagLayout nMods edges
  | nMods <= 0 = []
  | otherwise =
      let -- adjacency: out-neighbours per source
          adjOut :: IM.IntMap IS.IntSet
          adjOut = IM.fromListWith IS.union
            [ (s, IS.singleton t) | (s, t) <- edges, s /= t ]

          -- in-degree per node (only counts nodes with edges).
          inDeg :: IM.IntMap Int
          inDeg = foldl' bump IM.empty edges
            where bump !m (s, t)
                    | s == t    = m
                    | otherwise = IM.insertWith (+) t 1 m

          -- Longest-path rank via Kahn's algorithm: source nodes get
          -- rank 0, every other node gets max(rank predecessors) + 1.
          rank :: IM.IntMap Int
          rank = kahnRanks nMods adjOut inDeg

          -- Group module indices by rank. IntMap of [moduleIdx],
          -- prepended in iteration order so the within-rank ordering
          -- stays deterministic.
          byRank :: IM.IntMap [Int]
          byRank = foldl' add IM.empty [0 .. nMods - 1]
            where
              add !acc i =
                let !r = IM.findWithDefault 0 i rank
                in IM.insertWith (++) r [i] acc

          -- Position map: moduleIdx -> (x, y, w, h).
          positions :: IM.IntMap (Float, Float, Float, Float)
          positions = snd $ IM.foldlWithKey' placeRank (0, IM.empty) byRank

          placeRank
            :: (Float, IM.IntMap (Float, Float, Float, Float))
            -> Int -> [Int]
            -> (Float, IM.IntMap (Float, Float, Float, Float))
          placeRank (!yOff, !acc) _ idxs =
            let -- Sort within a rank by index for stable layout.
                sorted  = sort idxs
                k       = length sorted
                totalW  = fromIntegral k * podWidth
                        + fromIntegral (max 0 (k - 1)) * podColGap
                xStart  = -totalW / 2
                step i  = xStart + fromIntegral i * (podWidth + podColGap)
                acc'    = foldl'
                  (\ !m (i, mi) ->
                    IM.insert mi (step i, yOff, podWidth, podHeight) m)
                  acc
                  (zip [0..] sorted)
                yOff'   = yOff + podHeight + podRowGap
            in (yOff', acc')
      in concatMap
           (\i -> case IM.lookup i positions of
                    Just (x, y, w, h) -> [x, y, w, h]
                    Nothing           -> [0, 0, podWidth, podHeight])
           [0 .. nMods - 1]

-- | Longest-path rank assignment via Kahn's algorithm. Nodes with no
-- in-edges end up at rank 0; every other node sits one rank below the
-- max of its predecessors. Nodes in a cycle never get enqueued and
-- collapse to rank 0.
kahnRanks :: Int -> IM.IntMap IS.IntSet -> IM.IntMap Int -> IM.IntMap Int
kahnRanks nMods adjOut inDeg0 =
  let initialFrontier =
        [ i | i <- [0 .. nMods - 1], IM.findWithDefault 0 i inDeg0 == 0 ]
      seed = foldl' (\m i -> IM.insert i 0 m) IM.empty initialFrontier
  in go seed inDeg0 (Seq.fromList initialFrontier)
  where
    go !ranks !inDeg q = case Seq.viewl q of
      Seq.EmptyL -> ranks
      cur Seq.:< rest ->
        let !rCur     = IM.findWithDefault 0 cur ranks
            neighbors = IM.findWithDefault IS.empty cur adjOut
            (ranks', inDeg', enq) =
              IS.foldl' step (ranks, inDeg, []) neighbors

            step (!rs, !ids, !buf) n =
              let !rNew      = max (IM.findWithDefault 0 n rs) (rCur + 1)
                  !rs'       = IM.insert n rNew rs
                  !newInDeg  = IM.findWithDefault 0 n ids - 1
                  !ids'      = IM.insert n newInDeg ids
              in if newInDeg <= 0
                   then (rs', ids', n : buf)
                   else (rs', ids', buf)

            q' = foldl' (Seq.|>) rest enq
        in go ranks' inDeg' q'

-- ** Expanded JSON shape

-- The expanded JSON object: arrays of records keyed by qname /
-- module-name, no base64 typed arrays, no CSR adjacency. The field set
-- and shape are defined once in "AgdaDeps.Backend.Wire" (which also
-- generates the JSON Schema); this module only assembles the typed
-- 'ExpandedGraph' value ('toExpandedGraph').

-- | Validate-then-encode the expanded graph. Aborts on a wire-shape
-- invariant violation ('validateExpanded') — a regression assertion,
-- since the invariants hold by construction.
buildExpandedJson :: GraphInput -> String
buildExpandedJson gi =
  case validateExpanded eg of
    []   -> encodeExpanded eg
    errs -> error $ "buildExpandedJson: wire-shape invariant violation:\n"
                 ++ unlines (map ("  - " ++) errs)
  where eg = toExpandedGraph gi

-- | Build the typed expanded-graph value from a 'GraphInput'. Single
-- source for the emitted bytes (via 'encodeExpanded') and the structural
-- check ('validateExpanded').
toExpandedGraph :: GraphInput -> ExpandedGraph
toExpandedGraph GraphInput{..} =
  let allQNames :: [QName]
      allQNames = collectAllQNames giDefs

      defsList :: [QName]
      defsList = sortOn hashQName allQNames

      defIndexMap :: M.Map QName Int
      defIndexMap = M.fromList (zip defsList [0..])

      -- Node set as wire-name strings. An edge survives iff its
      -- target's 'nodeKey' names a node here.
      defKeySet :: S.Set String
      defKeySet = S.fromList (map nodeKey defsList)

      defState :: QName -> DefState
      defState qn = M.findWithDefault Defined qn giStateMap

      -- Per-QName analytical lookups, shared with the packed-analytical
      -- path so the two forms agree node-for-node (incl. the default for
      -- QNames with no local ADDef).
      defKind   = mkDefKind   giDefs
      defLine   = mkDefLine   giDefs
      defAccess = mkDefAccess giDefs
      defSig    = mkDefSig    giDefs

      defModuleOf  = map moduleKey defsList

      -- modules: same union as buildGraphJson so the two shapes agree.
      modulesSet :: S.Set String
      modulesSet =
        let !s0 = S.fromList defModuleOf
            !s1 = foldl' (\s (a, b) -> S.insert b (S.insert a s)) s0 giImportEdges
            !s2 = case giEntryModule of
                    Just m  -> S.insert m s1
                    Nothing -> s1
            !s3 = S.union s2 giFailedModules
        in S.union s3 giExtraModules

      modules    = S.toAscList modulesSet
      externals  = S.toAscList giExternalModules
      failedMods = S.toAscList giFailedModules

      -- Definition edges as qname pairs with parallel provenance tags,
      -- filtered to deps present in 'defKeySet'. 'definitionEdges' and
      -- 'definitionEdgesProvenance' share length and order, so the
      -- combined list is sorted once and unzipped.
      defEdgesWithProv :: [((String, String), EdgeProv)]
      defEdgesWithProv = sortOn fst
        [ ((sKey, tKey), prov)
        | d <- giDefs
        , let sKey = nodeKey (_name d)
        , (t, prov) <- M.toAscList (_depsProv d)
        , let tKey = nodeKey t
        , S.member tKey defKeySet
        ]

      defEdgePairs :: [(String, String)]
      defEdgePairs = map fst defEdgesWithProv

      defEdgeProv :: [EdgeProv]
      defEdgeProv = map snd defEdgesWithProv

      -- Module edges as name pairs (sorted, deduped).
      moduleEdgePairs :: [(String, String)]
      moduleEdgePairs =
        let leafEdges =
              [ (sMod, tMod)
              | d <- giDefs
              , let sMod = moduleKey (_name d)
              , t <- S.toAscList (_deps d)
              , let tMod = moduleKey t
              , sMod /= tMod
              ]
            impEdges =
              [ (s, t) | (s, t) <- giImportEdges, s /= t ]
            allEdges = leafEdges ++ impEdges
        in S.toAscList (S.fromList allEdges)

      transModPairs :: [(String, String)]
      transModPairs = sort $
        let idxToName   = IM.fromList (zip [0..] modules)
            nameOf i     = IM.findWithDefault "?" i idxToName
            moduleIxMap = M.fromList (zip modules [(0::Int)..])
            idxEdges    = [ (i, j)
                          | (s, t) <- moduleEdgePairs
                          , Just i <- [M.lookup s moduleIxMap]
                          , Just j <- [M.lookup t moduleIxMap]
                          ]
        in [ (nameOf s, nameOf t) | (s, t) <- transitiveEdgesInt idxEdges ]

      -- Per-definition wire record; encoded by AgdaDeps.Backend.Wire's
      -- field tables (the single source of truth shared with the schema).
      mkWireDef qn = WireDef
        { wdId     = M.findWithDefault (-1) qn defIndexMap
        , wdName   = nodeKey qn
        , wdModule = moduleKey qn
        , wdState  = defState qn
        , wdKind   = defKind qn
        , wdLine   = defLine qn
        , wdAccess = defAccess qn
        , wdType   = defSig qn
        , wdX      = fmap posX (M.lookup qn giPositions)
        , wdY      = fmap posY (M.lookup qn giPositions)
        }

      -- Externals summary decomposed (ascending) for the wire encoder.
      toWireExternals (ExternalsSummary mods byMod) =
        WireExternals (S.toAscList mods) (M.toAscList byMod)

      -- @"definitionSubtermHashes"@ / @"definitionSubtermDepths"@:
      -- arrays parallel to @"definitions"@, one @[Word64]@ / @[Int]@ per
      -- def's walked subterms. Both absent under no @--with-term-hashes@.
      defHashesByQ :: M.Map QName [Word64]
      defHashesByQ = mkDefHashes giDefs

      defDepthsByQ :: M.Map QName [Int]
      defDepthsByQ = mkDefDepths giDefs

  -- Assemble the typed wire value; encoding + structural validation are
  -- handled by 'buildExpandedJson' via AgdaDeps.Backend.Wire.
  in ExpandedGraph
       { egNodeKeyVersion = nodeKeyVersion
       , egProducer       = buildFingerprint
       , egModules        = modules
       , egEntryModule    = giEntryModule
       , egExternals      = externals
       , egFailed         = failedMods
       , egDefs           = map mkWireDef defsList
       , egDefEdges       = map WireEdge defEdgePairs
       , egDefEdgeProv    = defEdgeProv
       , egModuleEdges    = map WireEdge moduleEdgePairs
       , egTransModEdges  = map WireEdge transModPairs
       , egModuleFiles    = M.toList giModuleFile
       , egSourceFiles    = giSourceFiles
       , egReExports      = giReExports
       , egSubtermHashes  =
           if M.null defHashesByQ then Nothing
           else Just [ M.findWithDefault [] qn defHashesByQ | qn <- defsList ]
       , egSubtermDepths  =
           if M.null defDepthsByQ then Nothing
           else Just [ M.findWithDefault [] qn defDepthsByQ | qn <- defsList ]
       , egExternalsSummary = fmap toWireExternals giExternalsSummary
       }
