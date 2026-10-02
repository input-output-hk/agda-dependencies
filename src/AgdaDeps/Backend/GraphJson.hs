{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | v2 graph.json schema emitter.
--
-- 'buildGraphJson' emits the packed form (CSR adjacency, base64 typed
-- arrays) consumed by @agda-plotter@'s views; 'buildExpandedJson' emits
-- the record-array form for @--json-mode=expanded@, consumed by analysis
-- tools. 'buildModuleDetails' produces the per-module detail files for
-- @--lazy@, named through 'moduleDetailFilename'. Only the packed form
-- honours 'giLazy'. 'renderJson' picks the form for a monolithic file.
module AgdaDeps.Backend.GraphJson
  ( -- * Inputs gathered from the backend
    GraphInput(..)
  , emptyGraphInput

    -- * Outputs
  , GraphJsonOutput(..)
  , ModuleDetailJson(..)

    -- * Externals summary (emitted only under @--no-externals@)
  , ExternalsSummary(..)
  , buildExternalsSummary

    -- * Top-level emission
  , buildGraphJson
  , renderJson

    -- * Expanded JSON shape (--json-mode=expanded)
  , buildExpandedJson
  ) where

import Prelude hiding ( foldl' )
import Data.Bits ( (.|.) )
import Data.Char ( isAlphaNum, toLower )
import Data.Int ( Int32, Int8 )
import Data.List ( foldl', inits, intercalate, sort, sortOn )
import Data.Maybe ( fromMaybe, isJust )
import Data.Word ( Word64 )
import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import qualified Data.Sequence as Seq
import Data.Set ( Set )
import qualified Data.Set as S

import Agda.Utils.Hash ( hashString )

import AgdaDeps.Csr
  ( buildCsr, reverseCsr
  , encodeInt32LE, encodeInt8LE, encodeFloat32LE, encodeWord64LE
  , dedupSortedInt
  )
import AgdaDeps.Deps    ( ADDef(..), NodeRef(..), DefKind(..), DefAccess(..)
                        , EdgeProv(..), UnsafeTag(..), ArgUsage(..)
                        , defKindCode, edgeProvCode
                        , nodeKey, moduleKey, nodeKeyVersion, collectAllQNames )
import BuildInfo        ( buildFingerprint )
import AgdaDeps.Layout  ( Position(..) )
import AgdaDeps.Options ( DefState(..), JsonMode(..), defStateCode )
import AgdaDeps.Util
  ( jsString, jsB64Raw, jArray, jObj, jStrArray, jStrMap, jStrArrMap, splitOn )
import AgdaDeps.Backend.Wire
  ( ExpandedGraph(..), WireDef(..), WireEdge(..), WireExternals(..)
  , encodeExpanded, encodeObject, externalsSummaryFields, validateExpanded
  , unsolvedModulesJson )

-- | Strict per-module {defined, postulate, hole, failed} accumulator
-- used by 'moduleStateCounts'.
data Counts = Counts !Int !Int !Int !Int

-- | Structured form of the optional packed analytical arrays.  Keeping this
-- separate from the renderer lets lazy detail epochs fingerprint the values
-- without first allocating their base64/JSON representation.
data PackedAnalytical = PackedAnalytical
  [Int8]                         -- kinds
  [Int32]                        -- lines
  [Int8]                         -- access
  [Int8]                         -- unsafe bitmasks
  [Int32]                        -- unsolved metas
  (Maybe [Maybe String])         -- types
  (Maybe ([Int32], [Word64], [Int32])) -- subterm offsets/hashes/depths
  deriving (Show)

-- | Corpus-wide lookups shared by every lazy module.  Constructing these once
-- avoids turning lazy analytical emission into O(modules * definitions).
data PackedAnalyticalLookup = PackedAnalyticalLookup
  (NodeRef -> DefKind)
  (NodeRef -> Maybe Int)
  (NodeRef -> Maybe DefAccess)
  (NodeRef -> Maybe String)
  (NodeRef -> [UnsafeTag])
  (NodeRef -> Int)
  (M.Map NodeRef [Word64])
  (M.Map NodeRef [Int])

-- | Structured inputs for one non-placeholder lazy detail file.  The
-- analytical component is absent unless @--packed-analytical@ was requested.
data ModuleDetailInput = ModuleDetailInput
  [String]
  [Int8]
  [Float]
  [Float]
  [(Int, Int, Int)]
  (Maybe PackedAnalytical)

-- | Diagnostic summary of the external modules that @--no-externals@
-- stripped from the graph. Emitted at the top level as
-- @externals_summary@ in both @packed@ and @expanded@ modes.
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
              [nrShort (_name d)]
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

-- | 'ExternalsSummary' decomposed (ascending) for the wire encoder.
toWireExternals :: ExternalsSummary -> WireExternals
toWireExternals (ExternalsSummary mods byMod) =
  WireExternals (S.toAscList mods) (M.toAscList byMod)

-- | JSON for 'ExternalsSummary' (packed / @--lazy@ path): the expanded
-- form's encoder, so the two are byte-identical by construction.
externalsSummaryJson :: ExternalsSummary -> String
externalsSummaryJson = encodeObject externalsSummaryFields . toWireExternals

-- | All the inputs the schema emitter needs. Per-def state is read off
-- 'giDefs' ('_state'); a node with no 'ADDef' of its own is 'Defined'.
data GraphInput = GraphInput
  { giTypeTerms       :: !(Maybe String)
    -- ^ UTF-8 decoded JSON from TypeExport; expanded output only.
  , giDefs            :: [ADDef]
  , giImportEdges     :: [(String, String)]
  , giSourceFiles     :: [FilePath]
  , giModuleFile      :: M.Map String FilePath
  , giEntryModule     :: Maybe String
  , giExternalModules :: Set String
  , giFailedModules   :: Set String
  , giPositions       :: M.Map NodeRef Position
  , giLazy            :: Bool
  , giExtraModules    :: Set String
    -- ^ Module names to include in the graph even if they have no
    -- defs, no import edges, and aren't the entry. Both compilation and
    -- 'AgdaDeps.SkipAgda' use this to retain source-scan modules that
    -- happen to be orphans in the import graph.
  , giReExports       :: ![(String, String, [String], [(String, String)])]
    -- ^ Per (host-module, source-module) the fully-qualified names the
    -- host module re-exports via @open … public@, plus the renamed
    -- (alias, canonical-nodeKey) pairs for that row (empty when nothing
    -- was renamed). Dedup-sorted by the producer. Emitted in expanded
    -- JSON only.
  , giExternalsSummary :: !(Maybe ExternalsSummary)
    -- ^ Diagnostic summary of the externals stripped under
    -- @--no-externals@; carried in both packed and expanded output.
    -- 'Nothing' when @--no-externals@ wasn't passed, in which case the
    -- field is omitted from the JSON.
  , giPackedAnalytical :: !Bool
    -- ^ @--packed-analytical@: augment the packed @defs@ object with the
    -- per-definition analytical arrays (kind / line / access / type /
    -- subterm hashes). In lazy mode the same arrays live in each module
    -- detail file. 'False' leaves packed output byte-identical.
  , giModuleOptionEscapes :: ![(String, [String])]
    -- ^ Per module, the file-level @{-# OPTIONS ⋯ #-}@ soundness escapes
    -- ('AgdaDeps.Deps.optionEscapes'), ascending by module; only modules
    -- with an escape appear. Emitted as the optional top-level
    -- @moduleOptionEscapes@ object (packed / expanded / lazy); omitted
    -- when empty so escape-free corpora stay byte-identical.
  , giModuleEffectiveOptions :: ![(String, [String])]
    -- ^ Per module, the actionability-relevant options actually in force
    -- ('AgdaDeps.Deps.effectiveOptionFlags' — currently @--erasure@),
    -- ascending by module; only modules enabling one appear. Emitted as
    -- the optional top-level @moduleEffectiveOptions@ object (packed /
    -- expanded / lazy); omitted when empty.
  , giUnsolvedModules :: ![(String, ([Int], [Int]))]
    -- ^ Per top-level module, @(silent unsolved-meta lines,
    -- unsolved-constraint lines)@ under @--allow-unsolved-metas@
    -- ('AgdaDeps.Deps.unsolvedInterfaceLines'), ascending by module; only
    -- modules with at least one entry appear. Emitted as the optional
    -- top-level @unsolvedModules@ object (packed / expanded / lazy);
    -- omitted when empty so unsolved-free corpora stay byte-identical.
  }

-- | A graph with nothing in it; callers override the fields they have
-- (see "AgdaDeps.SkipAgda").
emptyGraphInput :: GraphInput
emptyGraphInput = GraphInput
  { giTypeTerms              = Nothing
  , giDefs                   = []
  , giImportEdges            = []
  , giSourceFiles            = []
  , giModuleFile             = M.empty
  , giEntryModule            = Nothing
  , giExternalModules        = S.empty
  , giFailedModules          = S.empty
  , giPositions              = M.empty
  , giLazy                   = False
  , giExtraModules           = S.empty
  , giReExports              = []
  , giExternalsSummary       = Nothing
  , giPackedAnalytical       = False
  , giModuleOptionEscapes    = []
  , giModuleEffectiveOptions = []
  , giUnsolvedModules        = []
  }

-- | Output of the v2 emitter, ready for the backend to write to disk.
data GraphJsonOutput = GraphJsonOutput
  { gjoGraphJson      :: String
  , gjoModuleDetails  :: [ModuleDetailJson]
  }

-- | One per-module detail file in lazy mode.
--
-- 'mdjEpoch' is a cheap content fingerprint (no base64/JSON assembly),
-- so the incremental-serialise path can skip rewriting a file without
-- forcing 'mdjContent'. Both fields are lazy: the epoch is only computed
-- when the cache consults it, and a skipped file never renders.
data ModuleDetailJson = ModuleDetailJson
  { mdjFileName   :: FilePath
  , mdjEpoch      :: Word64
  , mdjContent    :: String
  }

-- ** Emission

-- | The monolithic JSON document for @--json-mode@: packed or expanded.
-- (The @--lazy@ tree is written from 'buildGraphJson' directly.)
renderJson :: JsonMode -> GraphInput -> String
renderJson JsonPacked   = gjoGraphJson . buildGraphJson
renderJson JsonExpanded = buildExpandedJson

-- | Deterministic definition list shared by both emitters: every NodeRef
-- in the graph, ascending by 'hashQName' ('collectAllQNames' returns
-- 'IM.elems' order) for stable byte output. Keeping it in one place is
-- what makes 'buildGraphJson' and 'toExpandedGraph' agree node-for-node.
graphDefsList :: [ADDef] -> [NodeRef]
graphDefsList = collectAllQNames

-- | Each def's 'DefState' by 'NodeRef'; 'Defined' for a node with no
-- 'ADDef' of its own. Shared by both emitters.
mkDefState :: [ADDef] -> (NodeRef -> DefState)
mkDefState = mkDefDefault Defined _state

-- | Module-level edges as index pairs into @moduleIndexMap@, ascending
-- and deduplicated: the distinct cross-module pairs over definition
-- edges, plus the import edges. Every endpoint is in the module list
-- ('graphModulesSet'), and indices follow the ascending module order, so
-- mapping the pairs back to names gives the same ascending name pairs.
-- Shared by both emitters.
moduleEdgeIndexPairs
  :: M.Map String Int -> [ADDef] -> [(String, String)] -> [(Int, Int)]
moduleEdgeIndexPairs moduleIndexMap defs importEdges =
  S.toAscList (foldl' addImpEdge leafSet importEdges)
  where
    moduleOf qn = M.findWithDefault (-1) (moduleKey qn) moduleIndexMap
    addLeafEdges !acc d =
      let !sMod = moduleOf (_name d)
      in if sMod < 0 then acc
         else S.foldl'
                (\ !s t ->
                  let !tMod = moduleOf t
                  in if tMod < 0 || sMod == tMod
                       then s
                       else S.insert (sMod, tMod) s)
                acc (_deps d)
    !leafSet = foldl' addLeafEdges S.empty defs
    addImpEdge !acc (s, t) =
      case (M.lookup s moduleIndexMap, M.lookup t moduleIndexMap) of
        (Just i, Just j) | i /= j -> S.insert (i, j) acc
        _                         -> acc

-- | The module-name node set shared by both emitters: union of def
-- modules, import-edge endpoints, the entry module, failed modules, and
-- extra modules. @'S.toAscList'@ of the result is the ascending module
-- list both forms emit.
graphModulesSet
  :: [String]           -- ^ 'moduleKey' of each definition
  -> [(String, String)] -- ^ import edges
  -> Maybe String       -- ^ entry module
  -> S.Set String       -- ^ failed modules
  -> S.Set String       -- ^ extra modules
  -> S.Set String
graphModulesSet defModuleNames importEdges entryModule failedModules extraModules =
  let !s0 = S.fromList defModuleNames
      !s1 = foldl' (\s (a, b) -> S.insert b (S.insert a s)) s0 importEdges
      !s2 = case entryModule of
              Just m  -> S.insert m s1
              Nothing -> s1
      !s3 = S.union s2 failedModules
  in S.union s3 extraModules

buildGraphJson :: GraphInput -> GraphJsonOutput
buildGraphJson GraphInput{..} =
  let -- Fields that move to the per-module detail files under @--lazy@.
      inlineOnly s = if giLazy then "" else s

      -- (1) Definition list ---------------------------------------------
      defsList :: [NodeRef]
      defsList = graphDefsList giDefs

      -- Index edge endpoints by 'NodeRef'. Its 'Eq' is identity-key
      -- equality ('nrHash' is derived from 'nrKey'), mostly as a
      -- 'Word64' compare.
      defIndexMap :: M.Map NodeRef Int
      defIndexMap = M.fromList (zip defsList [0..])

      nDefs :: Int
      nDefs = length defsList

      defNames     :: [String]
      defNames     = map nodeKey defsList

      defModuleNames :: [String]
      defModuleNames = map moduleKey defsList

      -- (2) Module list ('graphModulesSet'; 'S.toAscList' is sorted) -----
      modulesSet :: S.Set String
      modulesSet = graphModulesSet defModuleNames giImportEdges
                     giEntryModule giFailedModules giExtraModules

      modules :: [String]
      modules = S.toAscList modulesSet

      moduleIndexMap :: M.Map String Int
      moduleIndexMap = M.fromList (zip modules [0..])

      nModules :: Int
      nModules = length modules

      moduleOf :: NodeRef -> Int
      moduleOf qn = case M.lookup (moduleKey qn) moduleIndexMap of
        Just i  -> i
        Nothing -> -1

      defModuleIdxs :: [Int32]
      defModuleIdxs = [ fromIntegral (moduleOf qn) | qn <- defsList ]

      -- (3) Per-def states + positions ---------------------------------
      -- Per-def state, shared by 'defStateBytes' and 'moduleStateCounts'.
      defStates :: [DefState]
      defStates = map (mkDefState giDefs) defsList

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
      files = S.toAscList allFilesSet

      fileIndexMap :: M.Map FilePath Int
      fileIndexMap = M.fromList (zip files [0..])

      moduleFileIdx :: String -> Maybe Int
      moduleFileIdx m = M.lookup m moduleFilePathMap >>= (`M.lookup` fileIndexMap)

      moduleToFile :: [Int32]
      moduleToFile = [ maybe (-1) fromIntegral (moduleFileIdx m) | m <- modules ]

      fileToModules :: [[Int]]
      fileToModules =
        let byFile = IM.fromListWith (++)
              [ (fi, [mi]) | (mi, m) <- zip [0..] modules
                           , Just fi <- [moduleFileIdx m] ]
        in [ sort (IM.findWithDefault [] i byFile)
           | i <- [0 .. length files - 1]
           ]

      -- (5) Edges --------------------------------------------------------
      adjList :: [(Int, [Int])]
      adjList =
        [ (srcGi, [ ti
                  | t <- S.toList (_deps d)
                  , Just ti <- [M.lookup t defIndexMap]
                  ])
        | d <- giDefs
        , Just srcGi <- [M.lookup (_name d) defIndexMap]
        ]

      (outOffsets, outTargets) = buildCsr nDefs adjList
      (inOffsets,  inTargets)  = reverseCsr nDefs adjList

      -- Per-edge provenance, keyed @(srcGi, tgtGi) -> Int8@, for the
      -- byte array aligned to 'outTargets'. Byte encoding: 'encodeEdgeProv'.
      defProvByPair :: IM.IntMap (IM.IntMap Int8)
      defProvByPair = foldl' addDefEdges IM.empty giDefs
        where
          addDefEdges !acc d = case M.lookup (_name d) defIndexMap of
            Nothing    -> acc
            Just srcGi ->
              let !inner =
                    M.foldlWithKey'
                      (\ !m tgt prov -> case M.lookup tgt defIndexMap of
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
      -- size. An empty 'transitiveEdges' array means "no reduction
      -- precomputed" to consumers.
      defTransitiveThreshold :: Int
      defTransitiveThreshold = 3000

      defTransitivePacked :: [Int32]
      defTransitivePacked
        | nDefs > defTransitiveThreshold = []
        | otherwise =
            [ fromIntegral (s * nDefs + t)
            | (s, t) <- transitiveDefEdges adjList
            ]

      -- (6) Module edges: distinct leaf-edge module pairs, plus imports --
      moduleEdgePairs :: [(Int, Int)]
      moduleEdgePairs = moduleEdgeIndexPairs moduleIndexMap giDefs giImportEdges

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
      -- Lets consumers show a state mix without re-scanning defs.
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
      -- BFS from the entry over module edges; -1 if unreachable or no entry.
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

      -- (7d) Module-DAG layout ('modulePodLayout') ---------------------
      -- Pod bounding boxes (x, y, w, h) per module, flat Float32 of
      -- length 4 * nModules. Algorithm in 'buildModuleDagLayout'.
      modulePodLayout :: [Float]
      modulePodLayout = buildModuleDagLayout nModules moduleEdgePairs

      -- (8) Externals (ascending, as 'modules' is) ---------------------
      externalModuleIdxs :: [Int32]
      externalModuleIdxs =
        [ fromIntegral i
        | (i, m) <- zip [0 :: Int ..] modules
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

      -- (11) Search index ----------------------------------------------
      (searchNames, searchKinds, searchBigrams) =
        buildSearchIndex modules defNames

      -- (12) Module detail files (lazy mode) ---------------------------
      moduleDetails :: [ModuleDetailJson]
      moduleDetails
        | giLazy = buildModuleDetails
                     defsList giDefs giPackedAnalytical moduleOf adjList
                     defStateBytes defXs defYs moduleIndexMap
                     giExternalModules giFailedModules giExternalsSummary
        | otherwise = []

      -- (13) Assemble graph.json --------------------------------------
      analyticalSuffix
        | giPackedAnalytical = packedAnalyticalJson defsList giDefs
        | otherwise          = ""

      defsJson = inlineOnly $
        ",\"defs\":" ++ defsObjectJson defNames defModuleIdxs defStateBytes defXs defYs analyticalSuffix

      edgesJson = inlineOnly $
        ",\"edges\":" ++ edgesObjectJson outOffsets outTargets inOffsets inTargets

      -- Per-edge 'EdgeProv' as packed int8, parallel to 'outTargets'.
      defEdgesProvJson = inlineOnly $
        ",\"definitionEdgesProvenance\":" ++ jsB64Int8 outTargetsProv

      transitiveJson = inlineOnly $
        ",\"transitiveEdges\":" ++ jsB64Int32 defTransitivePacked

      -- Optional diagnostic field; absent without @--no-externals@.
      externalsSummaryField = case giExternalsSummary of
        Just es -> ",\"externals_summary\":" ++ externalsSummaryJson es
        Nothing -> ""

      -- Optional module-level soundness escapes (file @OPTIONS@ pragmas);
      -- omitted when empty so escape-free corpora stay byte-identical.
      moduleOptionEscapesField
        | null giModuleOptionEscapes = ""
        | otherwise = ",\"moduleOptionEscapes\":"
                   ++ jStrArrMap giModuleOptionEscapes

      -- Optional module-level effective options (currently @--erasure@);
      -- omitted when empty, same encoder as the escapes above.
      moduleEffectiveOptionsField
        | null giModuleEffectiveOptions = ""
        | otherwise = ",\"moduleEffectiveOptions\":"
                   ++ jStrArrMap giModuleEffectiveOptions

      -- Optional module-level silent-unsolved-meta / unsolved-constraint
      -- rollup; omitted when empty (same encoder as the expanded form).
      unsolvedModulesField
        | null giUnsolvedModules = ""
        | otherwise = ",\"unsolvedModules\":"
                   ++ unsolvedModulesJson giUnsolvedModules

      graphJson = "{\"v\":2"
        ++ ",\"nodeKeyVersion\":" ++ show nodeKeyVersion
        ++ ",\"producer\":"     ++ jsString buildFingerprint
        ++ ",\"modules\":"      ++ jStrArray modules
        ++ ",\"files\":"        ++ jStrArray files
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
        ++ (if M.null moduleFilesMap then "" else
            ",\"moduleFiles\":" ++ stringMapJson moduleFilesMap)
        ++ ",\"searchIndex\":" ++ searchIndexJson searchNames searchKinds searchBigrams
        ++ externalsSummaryField
        ++ moduleOptionEscapesField
        ++ moduleEffectiveOptionsField
        ++ unsolvedModulesField
        ++ "}"

  in GraphJsonOutput
       { gjoGraphJson     = graphJson
       , gjoModuleDetails = moduleDetails
       }

-- ** Per-module detail emission

-- | Build per-module detail JSON files for lazy mode. One
-- 'ModuleDetailJson' per /real/ module (>=1 kept def) plus a
-- /placeholder/ file for every module with no kept defs (so lazy-mode
-- fetches don't 404).
--
-- A placeholder matches a normal detail file plus:
--
-- * @"placeholder": true@ — the discriminator consumers read.
-- * @"module": "<name>"@ — for display.
-- * @"reason": "external" | "failed" | "filtered"@ — why no kept defs:
--   external = outside the project root; failed = type-check raised
--   @TCErr@ under @--keep-going@; filtered = every def dropped by
--   'ignoreDef' / privacy filtering.
-- * @"externalPostulates": […]@ — for @"external"@ modules that
--   'ExternalsSummary' tagged. Absent otherwise.
buildModuleDetails
  :: [NodeRef]
  -> [ADDef]
  -> Bool                  -- ^ Include packed analytical arrays.
  -> (NodeRef -> Int)
  -> [(Int, [Int])]
  -> [Int8]
  -> [Float]
  -> [Float]
  -> M.Map String Int
  -> S.Set String           -- ^ externalModules (from 'GraphInput').
  -> S.Set String           -- ^ failedModules (from 'GraphInput').
  -> Maybe ExternalsSummary -- ^ for @"externalPostulates"@ on stubs.
  -> [ModuleDetailJson]
buildModuleDetails defsList defs includeAnalytical moduleOfQ adjList stateBytes xs ys moduleIndexMap
                   externalMods failedMods mExtSummary =
  let defsArr     :: IM.IntMap NodeRef
      defsArr     = IM.fromList (zip [0..] defsList)

      analyticalLookup :: Maybe PackedAnalyticalLookup
      analyticalLookup
        | includeAnalytical = Just (mkPackedAnalyticalLookup defs)
        | otherwise         = Nothing

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
      defsByModule = IM.fromListWith (++)
        [ (mi, [gi]) | (gi, qn) <- zip [0..] defsList
                     , let mi = moduleOfQ qn, mi >= 0 ]

      moduleOfDef :: Int -> Int
      moduleOfDef gi = case IM.lookup gi defsArr of
        Just qn -> moduleOfQ qn
        Nothing -> -1

      -- Structured inputs to a real module's detail file, shared by the
      -- content renderer and the cheap epoch so the epoch fingerprints
      -- exactly what gets written.
      realInputs :: [Int] -> ModuleDetailInput
      realInputs giList =
        let sortedGis = sort giList
            qnames = [ defsArr IM.! gi | gi <- sortedGis ]
            names  = map nodeKey qnames
            stsM   = [ statesArr IM.! gi | gi <- sortedGis ]
            xsM    = [ xsArr     IM.! gi | gi <- sortedGis ]
            ysM    = [ ysArr     IM.! gi | gi <- sortedGis ]
            outEs  = concat
              [ [ (li, tgtGi, moduleOfDef tgtGi)
                | tgtGi <- IM.findWithDefault [] srcGi outByDef
                ]
              | (li, srcGi) <- zip [0..] sortedGis
              ]
            analytical
              = packedAnalyticalDataFrom qnames <$> analyticalLookup
        in ModuleDetailInput names stsM xsM ysM outEs analytical

      renderReal :: ModuleDetailInput -> String
      renderReal (ModuleDetailInput names stsM xsM ysM outEs analytical) =
        "{\"defs\":" ++ defsObjectJsonModule names stsM xsM ysM
                           (maybe "" packedAnalyticalDataJson analytical)
        ++ ",\"outEdges\":" ++ outEdgesJson outEs
        ++ "}"

      -- Cheap content fingerprint of a real module's detail file (hashes
      -- the structured inputs, no base64/JSON assembly). Separators keep
      -- distinct field contents from colliding.
      realEpoch :: ModuleDetailInput -> Word64
      realEpoch (ModuleDetailInput names stsM xsM ysM outEs analytical) =
        hashString $ concat
          [ "R\f", intercalate "\f" names
          , "\v", show stsM, "\v", show xsM, "\v", show ysM
          , "\v", show outEs
          , maybe "" (\a -> "\vA\v" ++ show a) analytical ]

      placeholderEpoch :: String -> String -> [String] -> Maybe PackedAnalytical -> Word64
      placeholderEpoch m reason ps analytical =
        hashString $ concat
          [ "P\f", m, "\v", reason, "\v", intercalate "\f" ps
          , maybe "" (\a -> "\vA\v" ++ show a) analytical ]

      realDetails :: [ModuleDetailJson]
      !realDetails =
        [ ModuleDetailJson
            { mdjFileName   = moduleDetailFilename m
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

      emptyAnalytical :: Maybe PackedAnalytical
      emptyAnalytical = packedAnalyticalDataFrom [] <$> analyticalLookup

      renderPlaceholder :: String -> String
      renderPlaceholder m =
        let !reason = classifyEmpty m
            !ps     = externalPostulatesFor m
            extField
              | null ps   = ""
              | otherwise = ",\"externalPostulates\":" ++ jStrArray ps
        in "{\"defs\":"     ++ defsObjectJsonModule [] [] [] []
                                  (maybe "" packedAnalyticalDataJson emptyAnalytical)
        ++ ",\"outEdges\":" ++ outEdgesJson []
        ++ ",\"placeholder\":true"
        ++ ",\"module\":"   ++ jsString m
        ++ ",\"reason\":"   ++ jsString reason
        ++ extField
        ++ "}"

      placeholderDetails :: [ModuleDetailJson]
      !placeholderDetails =
        [ ModuleDetailJson
            { mdjFileName   = moduleDetailFilename m
            , mdjEpoch      = placeholderEpoch m (classifyEmpty m)
                                (externalPostulatesFor m) emptyAnalytical
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
  "{\"names\":"      ++ jStrArray names
  ++ ",\"modules\":" ++ jsB64Int32   mods
  ++ ",\"states\":"  ++ jsB64Int8    states
  ++ ",\"x\":"       ++ jsB64Float32 xs
  ++ ",\"y\":"       ++ jsB64Float32 ys
  ++ analytical
  ++ "}"

-- | The @--packed-analytical@ @defs@ suffix: per-definition kind / line
-- / access arrays (always), the type array (under @--with-signatures@),
-- and the CSR-packed subterm hashes\/depths (under @--with-term-hashes@).
-- Keyed by NodeRef over @defsList@ via the shared 'mkDef*' lookups so it
-- agrees with the expanded form node-for-node; @types@=@null@ /
-- @access@=@0@ for QNames with no local 'ADDef' match expanded's
-- omission of those keys.
packedAnalyticalJson :: [NodeRef] -> [ADDef] -> String
packedAnalyticalJson defsList defs =
  packedAnalyticalDataJson (packedAnalyticalData defsList defs)

-- | Compute packed analytical values once for either the monolithic definition
-- table or one lazy module's local definition table.
packedAnalyticalData :: [NodeRef] -> [ADDef] -> PackedAnalytical
packedAnalyticalData defsList defs =
  packedAnalyticalDataFrom defsList (mkPackedAnalyticalLookup defs)

mkPackedAnalyticalLookup :: [ADDef] -> PackedAnalyticalLookup
mkPackedAnalyticalLookup defs = PackedAnalyticalLookup
  (mkDefKind defs)
  (mkDefLine defs)
  (mkDefAccess defs)
  (mkDefSig defs)
  (mkDefUnsafe defs)
  (mkDefUnsolvedMetas defs)
  (mkDefHashes defs)
  (mkDefDepths defs)

packedAnalyticalDataFrom :: [NodeRef] -> PackedAnalyticalLookup -> PackedAnalytical
packedAnalyticalDataFrom defsList
  (PackedAnalyticalLookup defKind defLine defAccess defSig defUnsafe
                          defUnsolved hashesByQ depthsByQ) =
  PackedAnalytical kinds lns accs unsafes unsolveds types subterms
  where
    kinds = [ encodeDefKind (defKind qn) | qn <- defsList ]
    lns   = [ maybe (-1) fromIntegral (defLine qn) | qn <- defsList ] :: [Int32]
    accs  = [ encodeDefAccess (defAccess qn) | qn <- defsList ]
    unsafes = [ encodeUnsafeByte (defUnsafe qn) | qn <- defsList ] :: [Int8]
    unsolveds = [ fromIntegral (defUnsolved qn) | qn <- defsList ] :: [Int32]
    sigs  = [ defSig qn | qn <- defsList ]
    types
      | any isJust sigs = Just sigs
      | otherwise       = Nothing
    subterms
      | M.null hashesByQ = Nothing
      | otherwise =
          let perHashes = [ M.findWithDefault [] qn hashesByQ | qn <- defsList ]
              perDepths = [ M.findWithDefault [] qn depthsByQ | qn <- defsList ]
              offs = scanl (+) 0
                       (map (fromIntegral . length) perHashes) :: [Int32]
              flatH = concat perHashes :: [Word64]
              flatD = map fromIntegral (concat perDepths) :: [Int32]
          in Just (offs, flatH, flatD)

packedAnalyticalDataJson :: PackedAnalytical -> String
packedAnalyticalDataJson
  (PackedAnalytical kinds lns accs unsafes unsolveds types subterms) =
  ",\"kinds\":"  ++ jsB64Int8  kinds
  ++ ",\"lines\":"  ++ jsB64Int32 lns
  ++ ",\"access\":" ++ jsB64Int8  accs
  ++ ",\"unsafe\":" ++ jsB64Int8  unsafes
  ++ ",\"unsolvedMetas\":" ++ jsB64Int32 unsolveds
  ++ maybe "" (\sigs -> ",\"types\":" ++ stringOrNullArrayJson sigs) types
  ++ maybe "" renderSubterms subterms
  where
    renderSubterms (offs, flatH, flatD) =
      ",\"subtermOffsets\":" ++ jsB64Int32 offs
      ++ ",\"subtermHashes\":"  ++ jsB64Raw (encodeWord64LE flatH)
      ++ ",\"subtermDepths\":"  ++ jsB64Int32 flatD

-- | JSON array of strings-or-@null@ (one per def, parallel to names).
stringOrNullArrayJson :: [Maybe String] -> String
stringOrNullArrayJson = jArray (maybe "null" jsString)

defsObjectJsonModule :: [String] -> [Int8] -> [Float] -> [Float] -> String -> String
defsObjectJsonModule names states xs ys analytical =
  "{\"names\":"      ++ jStrArray names
  ++ ",\"states\":"  ++ jsB64Int8    states
  ++ ",\"x\":"       ++ jsB64Float32 xs
  ++ ",\"y\":"       ++ jsB64Float32 ys
  ++ analytical
  ++ "}"

edgesObjectJson :: [Int32] -> [Int32] -> [Int32] -> [Int32] -> String
edgesObjectJson outOff outTgt inOff inTgt =
  "{\"outOffsets\":"   ++ jsB64Int32 outOff
  ++ ",\"outTargets\":" ++ jsB64Int32 outTgt
  ++ ",\"inOffsets\":"  ++ jsB64Int32 inOff
  ++ ",\"inTargets\":"  ++ jsB64Int32 inTgt
  ++ "}"

outEdgesJson :: [(Int, Int, Int)] -> String
outEdgesJson = jArray (\(a, b, c) -> intArrayJson [a, b, c])

-- | @{ <key>: <str>, … }@ from a 'M.Map'; a typed convenience over the
-- shared 'jStrMap' ('M.toList' is ascending).
stringMapJson :: M.Map String FilePath -> String
stringMapJson = jStrMap . M.toList

pairArrayJson :: [(Int, Int)] -> String
pairArrayJson = jArray (\(a, b) -> intArrayJson [a, b])

intArrayArrayJson :: [[Int]] -> String
intArrayArrayJson = jArray intArrayJson

intArrayJson :: [Int] -> String
intArrayJson = jArray show

-- The 'encode*LE' helpers emit base64 ('AgdaDeps.Csr.b64', RFC 4648
-- alphabet + @=@ padding), which needs no JSON escaping, so quote it with
-- 'jsB64Raw' rather than paying 'jsString''s per-char escape dispatch over
-- these arrays (the packed output's dominant byte mass).
jsB64Int32 :: [Int32] -> String
jsB64Int32 = jsB64Raw . encodeInt32LE

jsB64Int8 :: [Int8] -> String
jsB64Int8 = jsB64Raw . encodeInt8LE

jsB64Float32 :: [Float] -> String
jsB64Float32 = jsB64Raw . encodeFloat32LE

-- ** State encoding

encodeDefState :: DefState -> Int8
encodeDefState = fromIntegral . defStateCode

-- | Wire encoding for 'DefKind' in the packed-analytical @defs.kinds@
-- array. Must mirror 'AgdaDeps.Backend.Wire.wireKind''s string ordering
-- so the consumer maps the byte back to the same @kind@ the expanded
-- form emits.
encodeDefKind :: DefKind -> Int8
encodeDefKind = fromIntegral . defKindCode

-- | Wire encoding for @defs.access@. MUST stay 3-valued
-- (0 unknown\/absent, 1 public, 2 private): @0@ round-trips to
-- expanded's omission of @access@ for QNames with no local 'ADDef', so
-- external nodes match node-for-node.
encodeDefAccess :: Maybe DefAccess -> Int8
encodeDefAccess Nothing          = 0
encodeDefAccess (Just AccPublic) = 1
encodeDefAccess (Just AccPrivate) = 2

-- | Pack a def's soundness escapes into one @Int8@ bitmask for the
-- packed-analytical @defs.unsafe@ array. Bit layout (MUST match
-- @schema/packed_analytical_check.py@ and the README): bit 0 (1) =
-- @non-terminating@, bit 1 (2) = @trustme@. @0@ = no escapes, mirroring
-- expanded's omission of the @unsafe@ key for such defs.
encodeUnsafeByte :: [UnsafeTag] -> Int8
encodeUnsafeByte = foldl' (\acc t -> acc .|. tagBit t) 0
  where
    tagBit UNonTerminating = 1
    tagBit UTrustMe        = 2

-- ** Per-NodeRef analytical lookups (shared by packed-analytical + expanded)
--
-- Both forms key these by 'NodeRef' over the same @defsList@, so a NodeRef
-- with no local 'ADDef' gets the same default in both — this keeps
-- packed-analytical node-for-node identical to expanded. Don't inline per-form.

-- | Index the defs by 'NodeRef' on a field that is only sometimes present:
-- absent entries stay out of the map, so a lookup answers 'Nothing' both for
-- a QName with no 'ADDef' and for one whose field is unset.
defOptionalMap :: (ADDef -> Maybe b) -> [ADDef] -> M.Map NodeRef b
defOptionalMap get defs =
  M.fromList [ (_name d, v) | d <- defs, Just v <- [get d] ]

mkDefOptional :: (ADDef -> Maybe b) -> [ADDef] -> (NodeRef -> Maybe b)
mkDefOptional get defs =
  let !m = defOptionalMap get defs
  in (`M.lookup` m)

-- | Index the defs by 'NodeRef' on a total field, with @dflt@ standing in for
-- a QName that has no 'ADDef' at all.
mkDefDefault :: b -> (ADDef -> b) -> [ADDef] -> (NodeRef -> b)
mkDefDefault dflt get defs =
  let !m = M.fromList [ (_name d, get d) | d <- defs ]
  in \qn -> M.findWithDefault dflt qn m

-- | Structural kind by NodeRef; 'DKOther' for QNames with no 'ADDef'.
mkDefKind :: [ADDef] -> (NodeRef -> DefKind)
mkDefKind = mkDefDefault DKOther _kind

-- | Source line by NodeRef; 'Nothing' for QNames with no 'ADDef' / no line.
mkDefLine :: [ADDef] -> (NodeRef -> Maybe Int)
mkDefLine = mkDefOptional _line

-- | Access by NodeRef; 'Nothing' for QNames with no 'ADDef'.
mkDefAccess :: [ADDef] -> (NodeRef -> Maybe DefAccess)
mkDefAccess = mkDefOptional _access

-- | Rendered signature by NodeRef ('--with-signatures'); 'Nothing' otherwise.
mkDefSig :: [ADDef] -> (NodeRef -> Maybe String)
mkDefSig = mkDefOptional _sig

-- | Subterm-hash map by NodeRef ('--with-term-hashes'); empty when off.
mkDefHashes :: [ADDef] -> M.Map NodeRef [Word64]
mkDefHashes = defOptionalMap _subtermHashes

-- | Subterm-depth map by NodeRef, parallel to 'mkDefHashes'.
mkDefDepths :: [ADDef] -> M.Map NodeRef [Int]
mkDefDepths = defOptionalMap _subtermDepths

-- | Soundness-escape tags by NodeRef; @[]@ for QNames with no 'ADDef'.
-- Shared by packed-analytical and expanded so the two agree
-- node-for-node.
mkDefUnsafe :: [ADDef] -> (NodeRef -> [UnsafeTag])
mkDefUnsafe = mkDefDefault [] _unsafe

-- | Silent unsolved-meta count by NodeRef; @0@ for QNames with no 'ADDef'.
-- Shared by packed-analytical and expanded so the two agree
-- node-for-node.
-- Sparse on purpose: only the defs that actually carry a meta are stored,
-- and an absent entry reads back as the 0 it would have held.
mkDefUnsolvedMetas :: [ADDef] -> (NodeRef -> Int)
mkDefUnsolvedMetas defs = fromMaybe 0 . mkDefOptional nonZero defs
  where nonZero d = case _unsolvedMetas d of
          n | n > 0     -> Just n
            | otherwise -> Nothing

-- | Never-used-argument verdict by NodeRef; 'Nothing' for QNames with no
-- 'ADDef' (and for the many defs with nothing to report). Expanded-only:
-- the packed form has no typed-array shape for a nested object, so unlike
-- the other analytical fields this one has no packed counterpart.
mkDefArgUsage :: [ADDef] -> (NodeRef -> Maybe ArgUsage)
mkDefArgUsage = mkDefOptional _argUsage

-- | Wire encoding for 'EdgeProv' in the packed JSON form.
encodeEdgeProv :: EdgeProv -> Int8
encodeEdgeProv = fromIntegral . edgeProvCode

-- ** File tree

renderFileTree :: [FilePath] -> String
renderFileTree files =
  let tokens :: [(FilePath, [String])]
      tokens = [ (f, splitPath' f) | f <- files ]

      -- Set-based dedup avoids the O(n^2) of 'nub'.
      allPaths :: [[String]]
      allPaths = S.toAscList . S.fromList $
        concatMap (\(_, comps) -> filter (not . null) (inits comps)) tokens

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
  in jArray entry allPaths

splitPath' :: FilePath -> [String]
splitPath' = filter (not . null) . splitOn '/'

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
      parentOf m = findFirst (reverse (properPrefixes m))
        where
          findFirst []     = -1
          findFirst (q:qs) = case M.lookup q treeIdx of
            Just i  -> i
            Nothing -> findFirst qs

      -- 'splitOn' never returns @[]@, so 'last' is total here.
      lastComponent :: String -> String
      lastComponent = last . splitOn '.'

      entry :: String -> String
      entry name =
        "{\"name\":" ++ jsString (lastComponent name)
        ++ ",\"parent\":" ++ show (parentOf name)
        ++ ",\"moduleIndex\":" ++ maybe "null" show (M.lookup name moduleIdx)
        ++ "}"

  in jArray entry treeNames

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
        | otherwise    = zipWith (\a b -> [a, b]) s (drop 1 s)

      -- Build the posting lists with O(1) cons per insert, then sort +
      -- dedup once per bigram.
      bigramMap :: M.Map String [Int]
      bigramMap
        -- Above 'bigramThreshold' total names, emit an empty map.
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
-- is skipped (empty); consumers then scan 'names' linearly.
bigramThreshold :: Int
bigramThreshold = 50000

searchIndexJson :: [String] -> [Int8] -> M.Map String [Int] -> String
searchIndexJson names kinds bigrams =
  "{\"names\":"      ++ jStrArray names
  ++ ",\"kinds\":"   ++ jsB64Int8 kinds
  ++ ",\"bigrams\":" ++ jObj [ (bg, intArrayJson is) | (bg, is) <- M.toList bigrams ]
  ++ "}"

-- ** Filename helpers

-- | Filesystem-safe filename for a module's detail file: the module name
-- verbatim when every character is safe, else a @detail-\<hash\>@
-- fallback. The lazy-ingest manifest and the on-disk files both derive
-- names through this, so they cannot disagree.
moduleDetailFilename :: String -> FilePath
moduleDetailFilename m
  | all isSafeChar m && not (null m) = m ++ ".json"
  | otherwise = "detail-" ++ show (hashString m) ++ ".json"
  where
    isSafeChar c = isAlphaNum c || c == '.' || c == '_' || c == '-'

-- ** Transitive-edge helpers

-- | The @edge (u, v) is transitively implied by another out-edge of u@
-- predicate for a fixed adjacency map. The per-node reachable set
-- ('reach') is computed once and shared across every edge query via the
-- returned closure.
transitiveEdgePred :: IM.IntMap IS.IntSet -> (Int -> Int -> Bool)
transitiveEdgePred adj =
  let reach :: IM.IntMap IS.IntSet
      reach = IM.fromList [ (u, bfsFrom adj u) | u <- IM.keys adj ]
  in \u v ->
       let others = IS.delete v (IM.findWithDefault IS.empty u adj)
       in any (\w -> IS.member v (IM.findWithDefault IS.empty w reach))
              (IS.toList others)

-- | Definition-level transitive reduction over an adjacency list.
transitiveDefEdges :: [(Int, [Int])] -> [(Int, Int)]
transitiveDefEdges adjList =
  let adj = IM.fromListWith IS.union
        [ (s, IS.fromList ts) | (s, ts) <- adjList, not (null ts) ]
      isTransitive = transitiveEdgePred adj
  in [ (s, t)
     | (s, ts) <- adjList
     , t <- ts
     , isTransitive s t
     ]

transitiveEdgesInt :: [(Int, Int)] -> [(Int, Int)]
transitiveEdgesInt edges =
  let adj = IM.fromListWith IS.union
        [ (s, IS.singleton t) | (s, t) <- edges ]
      isTransitive = transitiveEdgePred adj
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

-- ** Module-DAG layout (@modulePodLayout@)

-- | Pod dimensions (graph-space units, also used as device pixels at
-- zoom = 1). Part of the wire bytes: consumers draw pods at these sizes.
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

          -- Longest-path rank via Kahn's algorithm (see 'kahnRanks').
          rank :: IM.IntMap Int
          rank = kahnRanks nMods adjOut inDeg

          -- Group module indices by rank. IntMap of [moduleIdx],
          -- prepended in iteration order so the within-rank ordering
          -- stays deterministic.
          byRank :: IM.IntMap [Int]
          byRank = IM.fromListWith (++)
            [ (IM.findWithDefault 0 i rank, [i]) | i <- [0 .. nMods - 1] ]

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
                  (zip [0 :: Int ..] sorted)
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
  let defsList :: [NodeRef]
      defsList = graphDefsList giDefs

      -- An edge survives iff its target is a node here ('NodeRef' 'Eq'
      -- is identity-key equality).
      defIndexMap :: M.Map NodeRef Int
      defIndexMap = M.fromList (zip defsList [0..])

      -- Per-NodeRef analytical lookups, shared with packed-analytical
      -- (see 'mkDefKind') so the two forms agree node-for-node.
      defState  = mkDefState  giDefs
      defKind   = mkDefKind   giDefs
      defLine   = mkDefLine   giDefs
      defAccess = mkDefAccess giDefs
      defSig    = mkDefSig    giDefs
      defUnsafe = mkDefUnsafe giDefs
      defUnsolved = mkDefUnsolvedMetas giDefs
      defArgUsage = mkDefArgUsage giDefs

      defModuleOf  = map moduleKey defsList

      -- modules: shared with buildGraphJson so the two shapes agree.
      modulesSet :: S.Set String
      modulesSet = graphModulesSet defModuleOf giImportEdges
                     giEntryModule giFailedModules giExtraModules

      modules    = S.toAscList modulesSet
      externals  = S.toAscList giExternalModules
      failedMods = S.toAscList giFailedModules

      -- Definition edges as qname pairs with parallel provenance tags,
      -- filtered to deps that are nodes. 'definitionEdges' and
      -- 'definitionEdgesProvenance' share length and order, so the
      -- combined list is sorted once and unzipped.
      defEdgesWithProv :: [((String, String), EdgeProv)]
      defEdgesWithProv = sortOn fst
        [ ((sKey, nodeKey t), prov)
        | d <- giDefs
        , let sKey = nodeKey (_name d)
        , (t, prov) <- M.toAscList (_depsProv d)
        , M.member t defIndexMap
        ]

      defEdgePairs :: [(String, String)]
      defEdgePairs = map fst defEdgesWithProv

      defEdgeProv :: [EdgeProv]
      defEdgeProv = map snd defEdgesWithProv

      -- Module edges: the packed form's index pairs, named. Both lists
      -- stay ascending ('moduleEdgeIndexPairs').
      moduleIdxEdges :: [(Int, Int)]
      moduleIdxEdges = moduleEdgeIndexPairs
                         (M.fromList (zip modules [0..])) giDefs giImportEdges

      moduleNamePairs :: [(Int, Int)] -> [(String, String)]
      moduleNamePairs =
        let nameOf i = IM.findWithDefault "?" i (IM.fromList (zip [0..] modules))
        in map (\(s, t) -> (nameOf s, nameOf t))

      moduleEdgePairs, transModPairs :: [(String, String)]
      moduleEdgePairs = moduleNamePairs moduleIdxEdges
      transModPairs   = moduleNamePairs (transitiveEdgesInt moduleIdxEdges)

      -- Per-definition wire record for the node at index @i@ of
      -- 'defsList'; encoded by AgdaDeps.Backend.Wire's field tables (the
      -- single source of truth shared with the schema).
      mkWireDef i qn = let pos = M.lookup qn giPositions in WireDef
        { wdId     = i
        , wdName   = nodeKey qn
        , wdModule = moduleKey qn
        , wdState  = defState qn
        , wdKind   = defKind qn
        , wdLine   = defLine qn
        , wdAccess = defAccess qn
        , wdType   = defSig qn
        , wdUnsafe = defUnsafe qn
        , wdUnsolvedMetas = defUnsolved qn
        , wdArgUsage = defArgUsage qn
        , wdX      = fmap posX pos
        , wdY      = fmap posY pos
        }

      -- @"definitionSubtermHashes"@ / @"definitionSubtermDepths"@:
      -- arrays parallel to @"definitions"@, one @[Word64]@ / @[Int]@ per
      -- def's walked subterms. Both absent under no @--with-term-hashes@.
      defHashesByQ :: M.Map NodeRef [Word64]
      defHashesByQ = mkDefHashes giDefs

      defDepthsByQ :: M.Map NodeRef [Int]
      defDepthsByQ = mkDefDepths giDefs

  -- Assemble the typed wire value; encoding + structural validation are
  -- handled by 'buildExpandedJson' via AgdaDeps.Backend.Wire.
  in ExpandedGraph
       { egTypeTerms      = giTypeTerms
       , egNodeKeyVersion = nodeKeyVersion
       , egProducer       = buildFingerprint
       , egModules        = modules
       , egEntryModule    = giEntryModule
       , egExternals      = externals
       , egFailed         = failedMods
       , egDefs           = zipWith mkWireDef [0..] defsList
       , egDefEdges       = map WireEdge defEdgePairs
       , egDefEdgeProv    = defEdgeProv
       , egModuleEdges    = map WireEdge moduleEdgePairs
       , egTransModEdges  = map WireEdge transModPairs
       , egModuleFiles    = M.toList giModuleFile
       , egSourceFiles    = giSourceFiles
       , egReExports      = giReExports
       , egModuleOptionEscapes = giModuleOptionEscapes
       , egModuleEffectiveOptions = giModuleEffectiveOptions
       , egUnsolvedModules = giUnsolvedModules
       , egSubtermHashes  =
           if M.null defHashesByQ then Nothing
           else Just [ M.findWithDefault [] qn defHashesByQ | qn <- defsList ]
       , egSubtermDepths  =
           if M.null defDepthsByQ then Nothing
           else Just [ M.findWithDefault [] qn defDepthsByQ | qn <- defsList ]
       , egExternalsSummary = fmap toWireExternals giExternalsSummary
       }
