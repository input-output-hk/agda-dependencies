{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE PatternGuards #-}
-- | Resolve the project's @.agda-lib@ @depend:@ closure to concrete
-- include directories, constraining Agda's search path to exactly the
-- libraries the project asked for.
--
-- Opt-in via @--resolve-deps@ (or YAML @resolve-deps: true@). On
-- success it injects @--no-libraries@ plus one @-i \<dir\>@ per
-- resolved include directory into argv, before Agda's CLI parser sees
-- it. On any resolution failure (registry missing, library not found,
-- malformed file) it logs a stderr breadcrumb and leaves argv
-- untouched.
module AgdaDeps.LibResolve
  ( wantsResolveDeps
  , stripResolveDepsFlag
  , resolveProjectDepsArgs
  ) where

import Control.Exception ( SomeException, try )
import Data.Char ( isSpace )
import Data.List ( isPrefixOf )
import Data.Maybe ( catMaybes, fromMaybe, mapMaybe )
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import System.Directory
  ( doesDirectoryExist, doesFileExist, getHomeDirectory, listDirectory )
import System.Environment ( lookupEnv )
import System.FilePath ( (</>), takeDirectory, takeExtension, isAbsolute )
import System.IO ( hPutStrLn, stderr )

import AgdaDeps.Util ( dedupOrd )

-- | True when @--resolve-deps@ appears anywhere in argv.
wantsResolveDeps :: [String] -> Bool
wantsResolveDeps = elem "--resolve-deps"

-- | Lift @--resolve-deps@ tokens out of argv so Agda's CLI parser
-- never sees the (to it) unknown flag. Returns the cleaned argv.
stripResolveDepsFlag :: [String] -> [String]
stripResolveDepsFlag = filter (/= "--resolve-deps")

-- | If the project root contains an @.agda-lib@, parse its
-- @depend:@ list, resolve those entries to source directories via
-- Agda's library registry, and return @--no-libraries@ plus one
-- @-i ABSDIR@ per resolved include directory. Empty list on any
-- failure (with a stderr breadcrumb explaining why).
resolveProjectDepsArgs
  :: (String -> IO ())  -- ^ stderr breadcrumb writer (e.g. 'info')
  -> FilePath           -- ^ project root (directory containing the @.agda-lib@)
  -> IO [String]
resolveProjectDepsArgs say root = do
  mLib <- findProjectLibFile root
  case mLib of
    Nothing -> do
      logWarn $
        "--resolve-deps: no .agda-lib found in " ++ root
        ++ "; leaving argv unchanged."
      return []
    Just libPath -> do
      eDeps <- try (readLibFile libPath) :: IO (Either SomeException LibFile)
      case eDeps of
        Left e -> do
          logWarn $
            "--resolve-deps: failed to parse " ++ libPath
            ++ " (" ++ show e ++ "); leaving argv unchanged."
          return []
        Right libFile -> do
          registry <- loadRegistry
          eDirs <- try (resolveClosure registry libFile)
                     :: IO (Either SomeException [FilePath])
          case eDirs of
            Left e -> do
              logWarn $
                "--resolve-deps: closure resolution failed ("
                ++ show e ++ "); leaving argv unchanged."
              return []
            Right [] -> do
              say "--resolve-deps: no transitive depends; leaving argv unchanged."
              return []
            Right dirs -> do
              say $
                "--resolve-deps: pinned " ++ show (length dirs)
                ++ " include dir(s) from " ++ libPath
              return $ "--no-libraries"
                     : concat [ ["-i", d] | d <- dirs ]
  where
    logWarn = hPutStrLn stderr . ("agda-deps: " ++)

-- ** .agda-lib parsing

data LibFile = LibFile
  { libName     :: String
  , libDepends  :: [String]
  , libIncludes :: [FilePath]
  } deriving Show

findProjectLibFile :: FilePath -> IO (Maybe FilePath)
findProjectLibFile root = do
  exists <- doesDirectoryExist root
  if not exists then return Nothing else do
    entries <- listDirectory root
    case [ root </> e | e <- entries, takeExtension e == ".agda-lib" ] of
      (p:_) -> return (Just p)
      []    -> return Nothing

readLibFile :: FilePath -> IO LibFile
readLibFile path = do
  contents <- readFile path
  let !fields  = parseLibContents contents
      dir      = takeDirectory path
      name     = fromMaybe "" (lookup "name" fields)
      includes = words (fromMaybe "" (lookup "include" fields))
      depends  = splitDepends (fromMaybe "" (lookup "depend"  fields))
  return LibFile
    { libName     = name
    , libDepends  = depends
    , libIncludes = map (resolveAgainst dir) includes
    }

-- | Parse a @.agda-lib@. Each top-level field is @name: value@ on
-- one line, with optional continuation lines that begin with
-- whitespace. Minimal parser covering the common case.
parseLibContents :: String -> [(String, String)]
parseLibContents = go . lines
  where
    go [] = []
    go (ln:lns)
      | isBlank ln          = go lns
      | "--" `isPrefixOf` dropSpace ln = go lns
      | Just (k, v) <- splitField ln =
          let (cont, rest) = span isContinuation lns
              full = unwords (v : map dropSpace cont)
          in (k, full) : go rest
      | otherwise = go lns

    isBlank = all isSpace
    isContinuation s = not (null s) && isSpace (head s) && not (isBlank s)
    dropSpace = dropWhile isSpace

    splitField s = case break (== ':') s of
      (k, ':':v)
        | not (null (dropSpace k))
        , all (\c -> c /= ':' && not (isSpace c)) (dropSpace k)
            -> Just (dropSpace k, dropSpace v)
      _ -> Nothing

-- | Split a @depend:@ value into library names. Entries may be
-- separated by commas and\/or whitespace; commas are normalised to
-- spaces before tokenising.
splitDepends :: String -> [String]
splitDepends = words . map (\c -> if c == ',' then ' ' else c)

resolveAgainst :: FilePath -> FilePath -> FilePath
resolveAgainst base p
  | isAbsolute p = p
  | otherwise    = base </> p

-- ** Registry

-- | Map from library name to its parsed @.agda-lib@ file. Caching the
-- parsed 'LibFile' lets 'resolveClosure' read each dependency's
-- @depend:@/@include:@ lists without re-parsing the file.
type Registry = Map.Map String LibFile

loadRegistry :: IO Registry
loadRegistry = do
  mFile <- locateRegistryFile
  case mFile of
    Nothing -> return Map.empty
    Just path -> do
      eContents <- try (readFile path)
                     :: IO (Either SomeException String)
      case eContents of
        Left _    -> return Map.empty
        Right txt -> do
          let candidatePaths = parseRegistry txt
          entries <- catMaybes <$> mapM readRegistryEntry candidatePaths
          return $ Map.fromList entries

readRegistryEntry :: FilePath -> IO (Maybe (String, LibFile))
readRegistryEntry libPath = do
  exists <- doesFileExist libPath
  if not exists then return Nothing else do
    eLib <- try (readLibFile libPath) :: IO (Either SomeException LibFile)
    case eLib of
      Right lf | not (null (libName lf)) -> return (Just (libName lf, lf))
      _ -> return Nothing

-- | Locate Agda's library registry file: @$AGDA_DIR/libraries@ if
-- set, else @$XDG_CONFIG_HOME/agda/libraries@ or @~/.agda/libraries@.
locateRegistryFile :: IO (Maybe FilePath)
locateRegistryFile = do
  mAgdaDir <- lookupEnv "AGDA_DIR"
  candidates <- case mAgdaDir of
    Just d  -> return [d </> "libraries"]
    Nothing -> do
      mXdg <- lookupEnv "XDG_CONFIG_HOME"
      home <- getHomeDirectory
      let xdgPath = case mXdg of
                      Just x | not (null x) -> x </> "agda" </> "libraries"
                      _ -> home </> ".config" </> "agda" </> "libraries"
      return [xdgPath, home </> ".agda" </> "libraries"]
  firstExisting candidates
  where
    firstExisting [] = return Nothing
    firstExisting (p:ps) = do
      ok <- doesFileExist p
      if ok then return (Just p) else firstExisting ps

-- | One library path per line (absolute or @~/...@). Lines starting
-- with @--@ are comments; blank lines are ignored.
parseRegistry :: String -> [FilePath]
parseRegistry = mapMaybe lineToPath . lines
  where
    lineToPath ln =
      let s = trim ln
      in if null s || "--" `isPrefixOf` s
           then Nothing
           else Just s
    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- ** Closure

-- | Walk the @depend:@ tree from a starting library, accumulating
-- include directories. Cycles are guarded by a visited set.
resolveClosure :: Registry -> LibFile -> IO [FilePath]
resolveClosure registry root =
  fmap (dedupOrd . concat) $ go Set.empty (libDepends root)
  where
    go :: Set.Set String -> [String] -> IO [[FilePath]]
    go _ [] = return []
    go seen (dep:rest)
      | Set.member dep seen = go seen rest
      | otherwise = case Map.lookup dep registry of
          Nothing -> do
            hPutStrLn stderr $
              "agda-deps: --resolve-deps: dependency '" ++ dep
              ++ "' not in registry; skipping."
            go (Set.insert dep seen) rest
          -- Read deps/includes from the LibFile parsed during registry load.
          Just lf -> do
            rs <- go (Set.insert dep seen) (libDepends lf ++ rest)
            return (libIncludes lf : rs)
