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

    -- * argv inspection (shared by Main + Precompute)
  , candidateDirs
  , looksLikeAgdaSource
  ) where

import Data.Char ( isHexDigit )
import Data.List ( intercalate, isSuffixOf )
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

-- | Strip anonymous-module path segments (the ones 'prettyShow' renders
-- as a bare @_@) from a dotted qualified name, lifting where-block and
-- parameterised-section definitions into their nearest /named/ ancestor
-- module. Agda desugars both @where@ blocks and @module _ (…) where@
-- sections into anonymous internal sub-modules (@Parent._@, nested
-- @Parent._._@), so this is what turns the internal name back into the
-- module a reader thinks of as the owner:
--
--   * @"M._"@   ↦ @"M"@
--   * @"M._._"@ ↦ @"M"@
--   * @"M._.N"@ ↦ @"M.N"@
--   * @"M.f"@   ↦ @"M.f"@   (no anonymous segment — unchanged)
--   * @"M._+_"@ ↦ @"M._+_"@ (mixfix segment, not a bare @_@ — preserved)
--
-- Only whole dot-segments equal to @"_"@ are dropped, so mixfix names
-- such as @_+_@ \/ @_⊔_@ survive untouched. Shared by 'AgdaDeps.Deps.nodeKey'
-- (node identity) and 'AgdaDeps.Deps.moduleKey' (module attribution).
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
jsString :: String -> String
jsString s = '"' : concatMap esc s ++ "\""
  where
    esc '"'  = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc '\b' = "\\b"
    esc '\f' = "\\f"
    esc '<'  = "\\u003c"
    esc '>'  = "\\u003e"
    esc '&'  = "\\u0026"
    esc '\'' = "\\u0027"
    esc c
      | c < '\x20' = "\\u" ++ pad4 (showHex (fromEnum c) "")
      | otherwise  = [c]

    pad4 xs = replicate (4 - length xs) '0' ++ xs

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
      | Just v <- prefix "--include-path=" a = v : go rest
      | looksLikeAgdaSource a = takeDirectory a : go rest
      | otherwise = go rest

    prefix p s
      | take (length p) s == p = Just (drop (length p) s)
      | otherwise              = Nothing

-- | True for paths that look like an Agda source file by extension.
-- Used to recognise positional arguments to the executable and to
-- filter directory listings during the source-scan pre-compute.
looksLikeAgdaSource :: String -> Bool
looksLikeAgdaSource p = any (`isSuffixOf` p)
  [ ".agda", ".lagda", ".lagda.md", ".lagda.rst", ".lagda.tex"
  , ".lagda.org", ".lagda.tree", ".lagda.typ"
  ]
