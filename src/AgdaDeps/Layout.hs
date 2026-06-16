{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Pre-computed 2-D positions for the definition-level graph, so the
-- viewer can draw immediately without running a browser-side layout.
-- 'computePositions' picks one of three modes:
--
-- 1. Below 'sfdpNodeThreshold' — pipe the graph through Graphviz's
--    @sfdp -Tplain@.
-- 2. Above the threshold — use a module-grouped grid: each module
--    occupies a tile, definitions inside it form a sub-grid. O(V)
--    and deterministic.
-- 3. If sfdp isn't on @PATH@ or exceeds 'sfdpTimeoutSec' — same
--    fallback as (2).
--
-- All three paths produce a 'Position' per input node id, in the same
-- order. A single stderr line announces which path was taken.
module AgdaDeps.Layout
  ( -- * Computing positions
    computePositions
  , Position(..)

    -- * Tuning knobs (exposed for testing)
  , sfdpNodeThreshold
  , sfdpTimeoutSec
  ) where

import Control.Exception ( SomeException, try )
import Control.Monad ( when )

import Data.List ( foldl' )
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS

import System.Exit ( ExitCode(..) )
import System.Process ( readProcessWithExitCode )
import System.Timeout ( timeout )

import AgdaDeps.Logging ( info )

-- | An (x, y) position for a graph node, in arbitrary units. The HTML
-- viewer rescales these to the canvas.
data Position = Position { posX :: !Float, posY :: !Float }
  deriving (Show)

-- | Above this many definition nodes, skip sfdp entirely and use the
-- grid fallback.
sfdpNodeThreshold :: Int
sfdpNodeThreshold = 3000

-- | Hard timeout on the sfdp subprocess; once exceeded, fall back to
-- the grid layout.
sfdpTimeoutSec :: Int
sfdpTimeoutSec = 60

-- | Compute a position per node.
--
-- @nodesByModule@ pairs each node id with the integer id of its
-- module (or any value for ungrouped nodes); the grid fallback uses
-- it to put a module's definitions together. @edges@ is a list of
-- @(src, tgt)@ pairs using the same node ids. The returned list has
-- one 'Position' per input node id, in input order.
computePositions
  :: [(Int, Int)]   -- ^ (nodeId, moduleId) pairs, in stable order.
  -> [(Int, Int)]   -- ^ Edges (src, tgt) referencing those ids.
  -> IO [Position]
computePositions nodesByModule edges
  | null nodesByModule = return []
  | n > sfdpNodeThreshold = do
      info $
        "agda-deps: layout: " ++ show n
        ++ " nodes exceeds sfdp threshold ("
        ++ show sfdpNodeThreshold
        ++ "); using module-grouped grid."
      return (moduleGrouped nodesByModule)
  | otherwise = trySfdp
  where
    n = length nodesByModule
    nodeIds = map fst nodesByModule

    trySfdp = do
      info $
        "agda-deps: layout: running sfdp on " ++ show n ++ " nodes…"
      let dotInput = renderDot nodeIds edges
      let runSfdp :: IO (Either SomeException (ExitCode, String, String))
          runSfdp = try (readProcessWithExitCode "sfdp" ["-Tplain"] dotInput)
      result <- timeout (sfdpTimeoutSec * 1_000_000) runSfdp
      case result of
        Just (Right (ExitSuccess, out, _err))
          | Just positions <- parsePlain nodeIds out -> do
              info "agda-deps: layout: sfdp done."
              return positions
        Just _ -> do
          info $
            "agda-deps: layout: sfdp not available or failed; "
            ++ "falling back to module-grouped grid."
          return (moduleGrouped nodesByModule)
        Nothing -> do
          info $
            "agda-deps: layout: sfdp exceeded "
            ++ show sfdpTimeoutSec
            ++ "s timeout; falling back to module-grouped grid."
          return (moduleGrouped nodesByModule)

-- | Emit a minimal DOT representation suitable for @sfdp -Tplain@.
renderDot :: [Int] -> [(Int, Int)] -> String
renderDot nodeIds edges =
  "digraph G {\n"
  ++ "  node [shape=point];\n"
  ++ concatMap (\nid -> "  " ++ show nid ++ ";\n") nodeIds
  ++ concatMap (\(s, t) -> "  " ++ show s ++ " -> " ++ show t ++ ";\n") edges
  ++ "}\n"

-- | Parse Graphviz @-Tplain@ output.
parsePlain :: [Int] -> String -> Maybe [Position]
parsePlain nodeIds out =
  let entries = [ (nid, Position x y)
                | line <- lines out
                , Just (nid, x, y) <- [parseNodeLine line]
                ]
      posMap = IM.fromList entries
  in mapM (`IM.lookup` posMap) nodeIds
  where
    parseNodeLine :: String -> Maybe (Int, Float, Float)
    parseNodeLine line = case words line of
      "node":nameStr:xStr:yStr:_ -> do
        nid <- readMaybe nameStr
        x   <- readMaybe xStr
        y   <- readMaybe yStr
        return (nid, x, y)
      _ -> Nothing

    readMaybe :: Read a => String -> Maybe a
    readMaybe s = case reads s of
      [(v, rest)] | all (`elem` (" \t" :: String)) rest -> Just v
      _ -> Nothing

-- | Module-grouped grid layout. Each distinct module id gets a tile
-- on a coarse grid; the definitions inside that module sit on a
-- smaller sub-grid centred on the tile. Deterministic.
moduleGrouped :: [(Int, Int)] -> [Position]
moduleGrouped nodes =
  let -- Distinct module ids in first-appearance order.
      orderedModules = uniq (map snd nodes)
      modIx :: IM.IntMap Int
      modIx = IM.fromList (zip orderedModules [(0 :: Int)..])
      nMods = max 1 (length orderedModules)
      modSide = max 1 (ceiling (sqrt (fromIntegral nMods :: Double)))

      -- Tile spacing between module centres.
      tileSpacing = 1000.0 :: Float

      -- Group nodes back together by module; each value list ends up
      -- in reverse-insertion order (each combined value is a singleton,
      -- so '(++)' is exactly the old 'head new : old').
      byMod :: IM.IntMap [Int]
      byMod = IM.fromListWith (++) [ (m, [nid]) | (nid, m) <- nodes ]

      tileCentre m =
        let i = IM.findWithDefault 0 m modIx
            tx = i `mod` modSide
            ty = i `div` modSide
        in ( fromIntegral tx * tileSpacing
           , fromIntegral ty * tileSpacing
           )

      subPositions m =
        let ids   = IM.findWithDefault [] m byMod
            (cx, cy) = tileCentre m
            k     = length ids
            side  = max 1 (ceiling (sqrt (fromIntegral k :: Double)))
            sp    = 40.0 :: Float
            half  = fromIntegral (side - 1) * sp / 2
        in IM.fromList
             [ ( nid
               , Position
                   (cx - half + fromIntegral (i `mod` side) * sp)
                   (cy - half + fromIntegral (i `div` side) * sp)
               )
             | (i, nid) <- zip [0..] ids
             ]

      -- Build a global map then look up in input order.
      allPos :: IM.IntMap Position
      allPos = foldl' (\acc m -> IM.union acc (subPositions m))
                      IM.empty orderedModules
  in [ IM.findWithDefault (Position 0 0) nid allPos
     | (nid, _) <- nodes
     ]

-- | Deduplicate 'Int's preserving first-occurrence order.
uniq :: [Int] -> [Int]
uniq = go IS.empty
  where
    go _    []     = []
    go !seen (x:xs)
      | IS.member x seen = go seen xs
      | otherwise        = x : go (IS.insert x seen) xs
