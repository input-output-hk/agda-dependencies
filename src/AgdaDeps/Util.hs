{-# LANGUAGE CPP #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Small, general-purpose helpers shared by the other AgdaDeps
-- modules: with-function detection ('isWithFun'), case-tree leaf access
-- ('ccDone'), hex colour parsing ('isValidHexColor', 'parseHexColor'),
-- string splitting ('splitOn'), JSON encoding ('jsString', 'jArray',
-- 'jObj'), source-file recognition ('looksLikeAgdaSource') and
-- project discovery ('nearestAgdaLibAncestor', 'firstExistingFile').
module AgdaDeps.Util
  ( -- * Agda with-function compatibility (2.8 / 2.9)
    isWithFun
  , ccDone

    -- * Hex colour parsing
  , isValidHexColor
  , parseHexColor

    -- * String / enum helpers
  , splitOn
  , fromCode

    -- * JSON helpers
  , jsString
  , jsB64Raw
  , jArray
  , jObj
  , jStrArray
  , jStrMap
  , jStrArrMap

    -- * Source-file recognition
  , looksLikeAgdaSource

    -- * Project discovery (shared by Main, Config, LibResolve)
  , agdaLibFilesIn
  , nearestAgdaLibAncestor
  , firstExistingFile
  , underCwd
  ) where

import Control.Exception ( catch, IOException )
import Data.Char ( isHexDigit )
import Data.IORef ( newIORef, readIORef, modifyIORef' )
import Data.List ( intercalate, isSuffixOf )
import qualified Data.Map.Strict as M
import Data.Word ( Word8 )
import Numeric ( readHex, showHex )
import System.Directory
  ( canonicalizePath, doesDirectoryExist, doesFileExist, getCurrentDirectory
  , listDirectory )
import System.FilePath
  ( (</>), dropTrailingPathSeparator, equalFilePath, splitDirectories
  , takeDirectory, takeExtension )

import Agda.TypeChecking.CompiledClause ( CompiledClauses', pattern Done )
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

#else
-- Agda 2.8: @funWith :: Maybe QName@ (@Nothing@ / @Just helper@).
isWithFun :: Maybe a -> Bool
isWithFun = isJust
#endif

-- | A case-tree leaf: @Just (bound variables, body)@ for a @Done@ node,
-- 'Nothing' for @Case@ and @Fail@. Abstracts the one 2.8\/2.9 difference in
-- the case-tree API — 2.9 turned @Done@ into a pattern synonym over @CCDone@,
-- adding the originating clause number and a recursion flag — so
-- "AgdaDeps.MatchConstant" needs no CPP of its own.
--
-- The count is what a caller wants far more often than the names: at a leaf
-- every pattern is a variable, so it /is/ the size of the body's context.
-- Deliberately drops the name suggestions (and 2.9's clause number): they
-- differ between leaves with identical bodies, so anything comparing leaves
-- must not see them.
ccDone :: CompiledClauses' a -> Maybe (Int, a)
#if MIN_VERSION_Agda(2,9,0)
ccDone (Done _ _ xs b) = Just (length xs, b)
#else
ccDone (Done xs b)     = Just (length xs, b)
#endif
ccDone _               = Nothing

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

-- | Split on every occurrence of a separator: @splitOn '.' "A.B" ==
-- ["A","B"]@, and @splitOn c ""  == [""]@.
splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (chunk, [])       -> [chunk]
  (chunk, _ : rest) -> chunk : splitOn c rest

-- | Invert an enum's code function by enumerating every constructor, so
-- a decoder cannot drift from the encoder it mirrors.
fromCode :: (Bounded a, Enum a, Eq c) => (a -> c) -> c -> Maybe a
fromCode code c = lookup c [ (code x, x) | x <- [minBound .. maxBound] ]

-- | JSON-escape a Haskell 'String' and wrap it in double quotes. The
-- @<@ \/ @>@ \/ @&@ \/ @'@ escapes are part of the wire bytes (consumers
-- embed @graph.json@ in HTML @<script>@ blocks), so keep them.
--
-- A 'ShowS' fold: each unescaped char is one @cons@ and the closing
-- quote is the base accumulator, so no trailing append pass. Sits on
-- every emitted JSON string, so it multiplies across output.
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

-- | @{ "k": v, … }@ — a JSON object from already-encoded values, in the
-- given association-list order (callers supply ascending where
-- determinism matters). The @{…}@ counterpart of 'jArray'.
jObj :: [(String, String)] -> String
jObj kvs = "{" ++ intercalate "," [ jsString k ++ ":" ++ v | (k, v) <- kvs ] ++ "}"

-- | @[ "s", … ]@ — a JSON array of (escaped) strings.
jStrArray :: [String] -> String
jStrArray = jArray jsString

-- | @{ "k": "v", … }@ — a JSON object of string values.
jStrMap :: [(String, String)] -> String
jStrMap = jObj . map (fmap jsString)

-- | @{ "k": [ "s", … ], … }@ — a JSON object of string-array values.
jStrArrMap :: [(String, [String])] -> String
jStrArrMap = jObj . map (fmap jStrArray)

-- | True for paths that look like an Agda source file by extension.
-- Used to recognise positional arguments to the executable and to
-- filter directory listings during the source-scan pre-compute.
looksLikeAgdaSource :: String -> Bool
looksLikeAgdaSource p = any (`isSuffixOf` p)
  [ ".agda", ".lagda", ".lagda.md", ".lagda.rst", ".lagda.tex"
  , ".lagda.org", ".lagda.tree", ".lagda.typ"
  ]

-- | The @*.agda-lib@ files directly inside @d@ (none if @d@ is missing).
agdaLibFilesIn :: FilePath -> IO [FilePath]
agdaLibFilesIn d = do
  exists <- doesDirectoryExist d
  if not exists then pure [] else
    map (d </>) . filter ((== ".agda-lib") . takeExtension) <$> listDirectory d

-- | The nearest ancestor of @d@ (@d@ itself included) that contains an
-- @*.agda-lib@ file.
nearestAgdaLibAncestor :: FilePath -> IO (Maybe FilePath)
nearestAgdaLibAncestor d = do
  libs <- agdaLibFilesIn d
  let up = takeDirectory d
  if not (null libs) then pure (Just d)
    else if up == d then pure Nothing
    else nearestAgdaLibAncestor up

-- | The first path in the list that names an existing file.
firstExistingFile :: [FilePath] -> IO (Maybe FilePath)
firstExistingFile []       = pure Nothing
firstExistingFile (p : ps) = do
  e <- doesFileExist p
  if e then pure (Just p) else firstExistingFile ps

-- | Classify source files by their resolved location relative to the project
-- root (the cwd once 'Main' has settled it). Compare whole path components:
-- @project-old@ is not inside @project@. Symlinks pointing out are external;
-- aliases resolving in are internal. Missing files / resolution errors are
-- external. Memoise each spelling for this run; callers stay single-threaded.
underCwd :: IO (FilePath -> IO Bool)
underCwd = do
  root <- canonicalizePath =<< getCurrentDirectory
  let rootParts = splitDirectories (dropTrailingPathSeparator root)
      classify p = (do
        exists <- doesFileExist p
        if not exists then pure False else do
          resolved <- canonicalizePath p
          let parts = splitDirectories resolved
          pure $ length rootParts <= length parts
              && and (zipWith equalFilePath rootParts parts))
        `catch` \(_ :: IOException) -> pure False
  cache <- newIORef M.empty
  pure $ \p -> do
    cached <- M.lookup p <$> readIORef cache
    case cached of
      Just inside -> pure inside
      Nothing -> do
        inside <- classify p
        modifyIORef' cache (M.insert p inside)
        pure inside
