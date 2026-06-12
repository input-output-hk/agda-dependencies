{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Pre-compute the module-level dependency graph by scanning Agda
-- source files directly, independent of Agda's type-checker. Under
-- @--keep-going@ this lets the rendered graph include every project
-- module and its import edges even when type-check failures kept some
-- transitive deps from loading.
--
-- 'precomputeFromArgs' walks every directory passed via @-i@ /
-- @--include-path@ (and the parent of each positional source file)
-- for @.agda@ and @.lagda*@ files, line-parsing each to pick out its
-- @module …@ declaration and @import …@ / @open import …@
-- statements. No Agda machinery is involved.
--
-- The heuristic is regex-grade — comments and pragmas are skipped, but
-- string literals containing @import@ could trip it.
module AgdaDeps.Precompute
  ( PrecomputedGraph(..)
  , emptyGraph
  , precomputeFromArgs
  ) where

import Control.Exception ( catch, IOException )
import Control.Monad ( foldM )

import Data.Char ( isAlphaNum, isSpace )
import Data.Maybe ( listToMaybe, mapMaybe )
import qualified Data.Set as Set

import System.Directory
  ( doesDirectoryExist, doesFileExist, listDirectory )
import System.FilePath ( (</>), takeBaseName )

import AgdaDeps.Logging ( info )
import AgdaDeps.Util ( candidateDirs, dedupOrd, looksLikeAgdaSource )

-- | Pre-computed module-level information discovered by scanning
-- @.agda@ sources.
data PrecomputedGraph = PrecomputedGraph
  { precomputedModules :: [String]
    -- ^ Every module name found, deduplicated. Module names use Agda's
    -- dotted form (e.g. @Foo.Bar.Baz@).
  , precomputedImports :: [(String, String)]
    -- ^ @(importer, imported)@ pairs.
  , precomputedSourceFiles :: [FilePath]
    -- ^ Every @.agda@ / @.lagda*@ file found under the @-i@ paths,
    -- absolute paths, deduplicated. Used by the v2 graph.json
    -- filesystem hierarchy.
  , precomputedModuleFiles :: [(String, FilePath)]
    -- ^ Module name → source-file path map. Used by the @--skip-agda@
    -- path (in "AgdaDeps.SkipAgda").
  } deriving (Show)

-- | The trivial empty pre-computed graph. Returned when discovery
-- finds nothing or is disabled.
emptyGraph :: PrecomputedGraph
emptyGraph = PrecomputedGraph [] [] [] []

-- | Drive the scan from a canonicalised argv list. Pulls out every
-- @-i@ \/ @--include-path@ directory plus the parent directory of
-- each positional @.agda@ \/ @.lagda*@ source file, walks them
-- recursively, and returns the combined module + import map.
--
-- Writes a single info line to stderr summarising the discovery
-- (file count, module count, edge count).
precomputeFromArgs :: [String] -> IO PrecomputedGraph
precomputeFromArgs argv = do
  let roots = dedupOrd (candidateDirs argv)
  if null roots
    then return emptyGraph
    else do
      files <- concat <$> mapM discoverAgdaFiles roots
      let files' = dedupOrd files
      modulesAndImports <- mapM scanFile files'
      let pairs       = zip files' modulesAndImports
          valid       = [ (p, m, is) | (p, Just (m, is)) <- pairs ]
          mods        = dedupOrd [ m       | (_, m, _)  <- valid ]
          imports     = dedupOrd [ (m, i)  | (_, m, is) <- valid, i <- is ]
          moduleFiles = dedupOrd [ (m, p)  | (p, m, _)  <- valid ]
      info $
        "agda-deps: pre-compute: " ++ show (length files) ++ " source file(s), "
        ++ show (length mods)    ++ " module(s), "
        ++ show (length imports) ++ " import edge(s) discovered."
      return (PrecomputedGraph mods imports files' moduleFiles)

-- | Recursively list every Agda source file under a directory.
-- Hidden directories (name starting with @.@) are skipped.
discoverAgdaFiles :: FilePath -> IO [FilePath]
discoverAgdaFiles root = do
  exists <- doesDirectoryExist root
  if not exists then return [] else go [] root
  where
    -- Tail-recursive collector accumulating into a single list.
    go acc d = do
      entries <- listDirectory d `catch` \(_ :: IOException) -> return []
      foldM step acc [ d </> e | e <- entries, not (isHidden e) ]

    step acc p = do
      isDir <- doesDirectoryExist p
      if isDir
        then go acc p
        else return $ if looksLikeAgdaSource p then p : acc else acc

    isHidden ('.':_) = True
    isHidden _       = False

scanFile :: FilePath -> IO (Maybe (String, [String]))
scanFile path = do
  exists <- doesFileExist path
  if not exists then return Nothing else do
    contentE <- (Right <$> readFile path) `catch` \(e :: IOException) ->
                  return (Left e)
    case contentE of
      Left _  -> return Nothing
      Right c -> return (parseHeader path (stripBlockComments c))

-- Pull @(moduleName, [import])@ out of the file body. Line-based,
-- over logical Agda lines outside line comments; block comments have
-- already been stripped by 'stripBlockComments'.
--
-- Anonymous top-level declarations (@module _ where@) get rewritten to
-- the file's basename, matching Agda's surface behaviour.
parseHeader :: FilePath -> String -> Maybe (String, [String])
parseHeader path body =
  let cleaned  = map stripLineComment (lines body)
      moduleN  = fmap normaliseAnonymous
               $ listToMaybe (mapMaybe extractModule cleaned)
      importsN = Set.toList . Set.fromList $ concatMap extractImport cleaned
  in fmap (\m -> (m, importsN)) moduleN
  where
    normaliseAnonymous "_" = takeBaseName path
    normaliseAnonymous m   = m

stripLineComment :: String -> String
stripLineComment = go
  where
    go []           = []
    go ('-':'-':_)  = []
    go (c:cs)       = c : go cs

-- Agda's block comments nest, so we maintain a depth counter and
-- only emit characters at depth 0.
stripBlockComments :: String -> String
stripBlockComments = go 0
  where
    go :: Int -> String -> String
    go 0 ('{':'-':rest) = go 1 rest
    go 0 (c:cs)         = c : go 0 cs
    go n ('-':'}':rest) | n > 0 = go (n - 1) rest
    go n ('{':'-':rest) | n > 0 = go (n + 1) rest
    go n (_:cs)         | n > 0 = go n cs
    go _ []             = []

extractModule :: String -> Maybe String
extractModule line =
  case words (dropWhile isSpace line) of
    "module" : name : _ -> Just (sanitiseName name)
    _                   -> Nothing

extractImport :: String -> [String]
extractImport line =
  case words (dropWhile isSpace line) of
    "import"          : name : _ -> [sanitiseName name]
    "open" : "import" : name : _ -> [sanitiseName name]
    _                            -> []

-- Strip trailing punctuation Agda doesn't allow in module names
-- (semicolons, parentheses, … from compact one-liners). The trim is
-- ASCII-only but consistent across all scanned names.
sanitiseName :: String -> String
sanitiseName =
  takeWhile (\c -> c == '.' || c == '_' || c == '\'' || c == '-' || isAlphaNum c)
