{-# LANGUAGE CPP #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Small, general-purpose helpers shared by the other AgdaDeps
-- modules: with-function detection ('isWithFun', 'isWithFun''), hex
-- colour parsing ('isValidHexColor', 'parseHexColor'), list dedup
-- ('dedupOrd'), JSON string escaping ('jsString'), and argv inspection
-- ('candidateDirs', 'looksLikeAgdaSource').
module AgdaDeps.Util
  ( -- * Agda with-function compatibility (2.8 / 2.9)
    isWithFun
  , isWithFun'

    -- * Hex colour parsing
  , isValidHexColor
  , parseHexColor

    -- * List helpers
  , dedupOrd

    -- * Qualified-name helpers
  , liftAnonSegments

    -- * JSON helpers
  , jsString
  , jsB64Raw
  , jArray
  , jStrArray
  , jStrMap
  , jStrArrMap

    -- * argv inspection (shared by Main + Precompute)
  , candidateDirs
  , looksLikeAgdaSource
  ) where

import Data.Char ( isHexDigit )
import Data.List ( intercalate, isSuffixOf, stripPrefix )
import qualified Data.Set as Set
import Data.Word ( Word8 )
import Numeric ( readHex, showHex )
import System.FilePath ( takeDirectory )

#if MIN_VERSION_Agda(2,9,0)
import Agda.TypeChecking.Monad.Base.Types ( IsWithFunction(..) )
#else
import Data.Maybe ( isJust )
#endif

-- | Is this 'Function' a @with@-generated helper? Abstracts over the
-- 2.8 (@Maybe QName@) vs 2.9 (@IsWithFunction QName@) shape of @funWith@
-- so callers (notably "AgdaDeps.Deps") never branch on it.
#if MIN_VERSION_Agda(2,9,0)
isWithFun :: IsWithFunction a -> Bool
isWithFun NoWithFunction    = False
isWithFun (WithFunction _)  = True

-- | Like 'isWithFun', but extracts the with-helper's payload when
-- present.
isWithFun' :: IsWithFunction a -> Maybe a
isWithFun' NoWithFunction    = Nothing
isWithFun' (WithFunction a)  = Just a
#else
-- Agda 2.8: @funWith :: Maybe QName@ (@Nothing@ / @Just helper@).
isWithFun :: Maybe a -> Bool
isWithFun = isJust

isWithFun' :: Maybe a -> Maybe a
isWithFun' = id
#endif

-- | Validate a "#RRGGBB" string. Case-insensitive on the hex digits.
isValidHexColor :: String -> Bool
isValidHexColor ('#':rest) = length rest == 6 && all isHexDigit rest
isValidHexColor _          = False

-- | Parse "#RRGGBB" into a triple of 'Word8'. Caller must ensure validity
-- via 'isValidHexColor'.
parseHexColor :: String -> (Word8, Word8, Word8)
parseHexColor ('#':r1:r2:g1:g2:b1:b2:[]) =
  ( fromIntegral (readByte [r1, r2])
  , fromIntegral (readByte [g1, g2])
  , fromIntegral (readByte [b1, b2])
  )
  where
    readByte s = case readHex s of
      ((n, _):_) -> n :: Int
      _          -> 0
parseHexColor _ = (0, 0, 0)

-- | O(n log n) deduplication preserving first-occurrence order; a
-- drop-in for 'Data.List.nub' when 'Ord' is available.
dedupOrd :: forall a. Ord a => [a] -> [a]
dedupOrd = go Set.empty
  where
    go :: Set.Set a -> [a] -> [a]
    go _    []     = []
    go seen (x:xs)
      | Set.member x seen = go seen xs
      | otherwise         = x : go (Set.insert x seen) xs

-- | Drop bare-@_@ dot-segments from a dotted qualified name, lifting
-- @where@-block and parameterised-section defs (Agda desugars both into
-- anonymous @Parent._@ sub-modules) into their nearest named ancestor:
-- @"M._.N"@ ↦ @"M.N"@, @"M._"@ ↦ @"M"@. Only whole @"_"@ segments are
-- dropped, so mixfix names (@_+_@) survive. Load-bearing for node
-- identity: shared by 'AgdaDeps.Deps.nodeKey' and 'moduleKey'.
liftAnonSegments :: String -> String
liftAnonSegments = intercalate "." . filter (/= "_") . splitDots
  where
    splitDots :: String -> [String]
    splitDots s = case break (== '.') s of
      (seg, [])       -> [seg]
      (seg, _ : rest) -> seg : splitDots rest

-- | JSON-escape a Haskell 'String' and wrap it in double quotes. The
-- escapes (including @<@ \/ @>@ \/ @&@) make the result safe inside
-- both a @<script>@ block and a standalone @.json@ file.
--
-- A 'ShowS' fold: each unescaped char is one @cons@ and the closing
-- quote is the base accumulator, so no trailing append pass. Sits on
-- every emitted JSON/HTML/DOT string, so it multiplies across output.
jsString :: String -> String
jsString s = '"' : foldr escS "\"" s
  where
    escS :: Char -> ShowS
    escS '"'  r = '\\' : '"'  : r
    escS '\\' r = '\\' : '\\' : r
    escS '\n' r = '\\' : 'n'  : r
    escS '\r' r = '\\' : 'r'  : r
    escS '\t' r = '\\' : 't'  : r
    escS '\b' r = '\\' : 'b'  : r
    escS '\f' r = '\\' : 'f'  : r
    escS '<'  r = '\\' : 'u' : '0' : '0' : '3' : 'c' : r
    escS '>'  r = '\\' : 'u' : '0' : '0' : '3' : 'e' : r
    escS '&'  r = '\\' : 'u' : '0' : '0' : '2' : '6' : r
    escS '\'' r = '\\' : 'u' : '0' : '0' : '2' : '7' : r
    escS c    r
      | c < '\x20' = '\\' : 'u' : pad4 (showHex (fromEnum c) "") ++ r
      | otherwise  = c : r

    pad4 xs = replicate (4 - length xs) '0' ++ xs

-- | Quote a string known to contain only JSON-safe characters (the
-- base64 alphabet @[A-Za-z0-9+/=]@), skipping the per-char escape
-- dispatch 'jsString' would run for nothing. Use ONLY for base64 payloads
-- (the packed graph's typed arrays), which dominate that output's byte
-- mass — a non-base64 string could smuggle an unescaped quote.
jsB64Raw :: String -> String
jsB64Raw s = '"' : s ++ "\""

-- | @[ f x, … ]@ — a JSON array rendered with a per-element encoder.
-- The single source of the @[…]@/@,@ layout the wire depends on; shared
-- by "AgdaDeps.Backend.Wire" and "AgdaDeps.Backend.GraphJson" so the
-- expanded and packed/lazy forms stay byte-coherent.
jArray :: (a -> String) -> [a] -> String
jArray f xs = "[" ++ intercalate "," (map f xs) ++ "]"

-- | @[ "s", … ]@ — a JSON array of (escaped) strings.
jStrArray :: [String] -> String
jStrArray = jArray jsString

-- | @{ "k": "v", … }@ — a JSON object of string values, in the given
-- association-list order (callers supply ascending where determinism
-- matters).
jStrMap :: [(String, String)] -> String
jStrMap kvs = "{" ++ intercalate "," [ jsString k ++ ":" ++ jsString v | (k, v) <- kvs ] ++ "}"

-- | @{ "k": [ "s", … ], … }@ — a JSON object of string-array values.
jStrArrMap :: [(String, [String])] -> String
jStrArrMap kvs = "{" ++ intercalate "," [ jsString k ++ ":" ++ jStrArray v | (k, v) <- kvs ] ++ "}"

-- | Directories worth scanning for project sources, lifted from a
-- canonicalised argv: every @-i@ \/ @--include-path@ value, plus the
-- parent directory of any positional @*.agda@ \/ @*.lagda*@ source
-- file. Used by 'Main.discoverProjectRoot' and "AgdaDeps.Precompute".
candidateDirs :: [String] -> [FilePath]
candidateDirs = go
  where
    go [] = []
    go (a:rest)
      | a == "-i" || a == "--include-path"
      , v:rest' <- rest = v : go rest'
      | Just v <- stripPrefix "--include-path=" a = v : go rest
      | looksLikeAgdaSource a = takeDirectory a : go rest
      | otherwise = go rest

-- | True for paths that look like an Agda source file by extension.
-- Used to recognise positional arguments to the executable and to
-- filter directory listings during the source-scan pre-compute.
looksLikeAgdaSource :: String -> Bool
looksLikeAgdaSource p = any (`isSuffixOf` p)
  [ ".agda", ".lagda", ".lagda.md", ".lagda.rst", ".lagda.tex"
  , ".lagda.org", ".lagda.tree", ".lagda.typ"
  ]
