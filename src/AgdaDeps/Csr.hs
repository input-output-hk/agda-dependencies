{-# LANGUAGE BangPatterns #-}
-- | Compressed-sparse-row (CSR) builders plus base64-encoded typed-array
-- serialisation, used by the v2 graph.json schema.
--
-- The v2 schema packs adjacency lists into two flat arrays per direction:
--
--   * @offsets[i] .. offsets[i+1]@ slices into @targets@ to enumerate
--     the neighbours of node @i@.
--   * @offsets@ has length @nNodes+1@; @targets@ has length @E@.
--
-- The on-wire form is little-endian raw bytes of the typed arrays,
-- base64-encoded, decoded JS-side via @atob@ + @Uint8Array.from@.
--
-- Key functions: 'buildCsr', 'reverseCsr', 'dedupSortedInt',
-- 'encodeInt32LE', 'encodeInt8LE', 'encodeFloat32LE', 'b64'.
module AgdaDeps.Csr
  ( -- * CSR builders
    buildCsr
  , reverseCsr

    -- * Sorted-int dedup
  , dedupSortedInt

    -- * Base64-encoded typed-array emission
  , encodeInt32LE
  , encodeInt8LE
  , encodeFloat32LE
  , encodeWord64LE
  , b64
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Builder as B
import Data.Bits ( shiftL, shiftR, (.&.), (.|.) )
import Data.Int ( Int32, Int8 )
import Data.Word ( Word64 )
import qualified Data.IntMap.Strict as IM
import Data.List ( sort )

-- | Build a CSR @(offsets, targets)@ pair from an adjacency list keyed
-- by source node. @nNodes@ is the total number of nodes; nodes with no
-- outgoing edges produce an empty slice (consecutive equal entries in
-- @offsets@).
--
-- @adj@ is a list of @(srcIdx, [tgtIdx])@ pairs. Duplicate @srcIdx@
-- entries are merged. Nothing in @adj@ may have @srcIdx >= nNodes@.
buildCsr :: Int -> [(Int, [Int])] -> ([Int32], [Int32])
buildCsr nNodes adj =
  let buckets :: [[Int]]
      buckets = bucketize nNodes adj

      -- Single pass: prepend each bucket's targets to the target-list
      -- accumulator and emit the running offset; both lists are
      -- reversed once at the end.
      go :: Int32 -> [Int32] -> [Int32] -> [[Int]] -> ([Int32], [Int32])
      go !off offsAcc tgtsAcc [] = (reverse (off : offsAcc), reverse tgtsAcc)
      go !off offsAcc tgtsAcc (b : bs) =
        let !(newOff, tgtsAcc') = pushBucket off tgtsAcc b
        in go newOff (off : offsAcc) tgtsAcc' bs

      pushBucket :: Int32 -> [Int32] -> [Int] -> (Int32, [Int32])
      pushBucket !off acc [] = (off, acc)
      pushBucket !off acc (t : ts) =
        pushBucket (off + 1) (fromIntegral t : acc) ts
  in go 0 [] [] buckets

-- | Build a reverse CSR (incoming edges) from a forward adjacency list.
reverseCsr :: Int -> [(Int, [Int])] -> ([Int32], [Int32])
reverseCsr nNodes adj =
  let reversed = [ (t, [s]) | (s, ts) <- adj, t <- ts ]
  in buildCsr nNodes reversed

-- | Bucket adjacency-list entries by source index, dedup + sort targets
-- so the CSR is canonical. @nNodes@ slots are filled (empty list for
-- sources with no outgoing edges).
bucketize :: Int -> [(Int, [Int])] -> [[Int]]
bucketize nNodes adj =
  let merged :: IM.IntMap [Int]
      merged = IM.fromListWith (++) adj

      mp :: IM.IntMap [Int]
      mp = IM.map dedupSortedInt merged
  in [ IM.findWithDefault [] i mp | i <- [0 .. nNodes - 1] ]

-- | Sort a list of ints and collapse runs of equal elements. Used for
-- adjacency dedup ('bucketize') and the search-index posting lists in
-- "AgdaDeps.Backend.GraphJson".
dedupSortedInt :: [Int] -> [Int]
dedupSortedInt = uniqSorted . sort
  where
    uniqSorted []     = []
    uniqSorted [x]    = [x]
    uniqSorted (a:b:xs)
      | a == b    = uniqSorted (b:xs)
      | otherwise = a : uniqSorted (b:xs)

-- ** Base64 typed-array helpers

-- | Encode a list of 32-bit signed ints as a base64 string of their
-- little-endian byte representation.
encodeInt32LE :: [Int32] -> String
encodeInt32LE xs = b64 . BL.toStrict . B.toLazyByteString $
  foldMap B.int32LE xs

-- | Encode a list of 8-bit signed ints as a base64 string.
encodeInt8LE :: [Int8] -> String
encodeInt8LE xs = b64 . BL.toStrict . B.toLazyByteString $
  foldMap B.int8 xs

-- | Encode a list of 32-bit floats as a base64 string of their
-- little-endian byte representation.
encodeFloat32LE :: [Float] -> String
encodeFloat32LE xs = b64 . BL.toStrict . B.toLazyByteString $
  foldMap B.floatLE xs

-- | Encode a list of 64-bit words as a base64 string of their
-- little-endian byte representation. Used for the canonical 'Word64'
-- subterm hashes in the packed-analytical @defs@ arrays (exact, unlike
-- the JSON-number form expanded uses).
encodeWord64LE :: [Word64] -> String
encodeWord64LE xs = b64 . BL.toStrict . B.toLazyByteString $
  foldMap B.word64LE xs

-- | RFC 4648 base64 encoding of a strict 'BS.ByteString', standard
-- alphabet plus @=@ padding. Hand-rolled to avoid a new package
-- dependency.
b64 :: BS.ByteString -> String
b64 bs = go 0
  where
    n = BS.length bs

    enc :: Int -> Char
    enc i = toEnum (fromIntegral (BS.index alphabetBS i))

    go :: Int -> String
    go !i
      | i >= n    = []
      | i + 1 == n =
          let a' = fromIntegral (BS.index bs i) :: Int
              c0 = a' `shiftR` 2
              c1 = (a' .&. 0x03) `shiftL` 4
          in [enc c0, enc c1, '=', '=']
      | i + 2 == n =
          let a' = fromIntegral (BS.index bs i)       :: Int
              b' = fromIntegral (BS.index bs (i + 1)) :: Int
              c0 = a' `shiftR` 2
              c1 = ((a' .&. 0x03) `shiftL` 4) .|. (b' `shiftR` 4)
              c2 = (b' .&. 0x0F) `shiftL` 2
          in [enc c0, enc c1, enc c2, '=']
      | otherwise =
          let a' = fromIntegral (BS.index bs i)       :: Int
              b' = fromIntegral (BS.index bs (i + 1)) :: Int
              c' = fromIntegral (BS.index bs (i + 2)) :: Int
              c0 = a' `shiftR` 2
              c1 = ((a' .&. 0x03) `shiftL` 4) .|. (b' `shiftR` 4)
              c2 = ((b' .&. 0x0F) `shiftL` 2) .|. (c' `shiftR` 6)
              c3 = c' .&. 0x3F
          in enc c0 : enc c1 : enc c2 : enc c3 : go (i + 3)

-- | Base64 alphabet (standard RFC 4648 set) held as a strict
-- 'BS.ByteString' for O(1) 'BS.index' lookup.
alphabetBS :: BS.ByteString
alphabetBS = BS.pack . map (fromIntegral . fromEnum) $
  ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" :: String)
