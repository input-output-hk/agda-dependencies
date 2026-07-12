{-# LANGUAGE ScopedTypeVariables #-}
-- | Source-snippet extraction for the HTML drawer.
--
-- Drives Agda's own @HtmlBackend@ to render every loaded module to a
-- temp directory, then slices each definition's paragraph out of the
-- resulting highlighted @<pre class="Agda">@ block. The slices keep
-- Agda's anchors and semantic classes, so the drawer can colour them
-- without re-tokenising.
module AgdaDeps.Source
  ( -- * Snippets
    Snippet(..)

    -- * Locating a binding site
  , srcLocOf

    -- * Top-level helper
  , collectHighlightedSnippets

    -- * Lower-level helpers (exposed for testing)
  , paragraphBounds
  , extractPreBlock
  , sliceHtmlByLine
  ) where

import Control.Exception ( catch, IOException )
import Control.Monad ( forM_ )
import Control.Monad.IO.Class ( MonadIO(liftIO) )

import Data.Char ( isSpace )
import qualified Data.IntSet as IS
import qualified Data.IORef as IORef
import Data.Map ( Map )
import qualified Data.Map as M
import Data.Maybe ( catMaybes )
import Data.Word ( Word32 )

import System.Directory ( doesFileExist, createDirectoryIfMissing, removeDirectoryRecursive )
import System.FilePath ( (</>) )

import Data.List ( isPrefixOf )

import Agda.Syntax.Abstract.Name ( QName, nameBindingSite )
import Agda.Syntax.Internal ( qnameName, qnameModule )
import Agda.Syntax.Position ( rStart, posLine, rangeFile, rangeFilePath )
import Agda.Syntax.TopLevelModuleName ( TopLevelModuleName )

import Agda.Utils.FileName ( filePath )
import qualified Agda.Utils.Maybe.Strict as Strict

import Agda.Syntax.Common.Pretty ( prettyShow )

import Agda.Interaction.Highlighting.HTML.Base
  ( HtmlOptions(..), HtmlHighlight(..)
  , srcFileOfInterface, defaultPageGen, runLogHtmlWith )
import Agda.TypeChecking.Monad ( TCM )
import Agda.TypeChecking.Monad.Base ( miInterface )
import Agda.TypeChecking.Monad.Imports ( getVisitedModules )

import AgdaDeps.Options ( isExcludedModule )

-- | The extracted source snippet for a definition: the contiguous
-- non-blank block of lines around its binding site, plus the 1-indexed
-- line number where that block starts (used for the gutter in the HTML
-- drawer).
data Snippet = Snippet
  { snippetStartLine :: !Int
  , snippetText      :: !String
  } deriving (Show)

-- | Resolve a 'QName' to @(source file path, 1-indexed line number)@ of
-- its *binding* occurrence. 'Nothing' for names with no associated
-- source range (synthetic / generated names) or whose range carries no
-- file (built-ins).
srcLocOf :: QName -> Maybe (FilePath, Word32)
srcLocOf qn = do
  let bindRange = nameBindingSite (qnameName qn)
  rf <- case rangeFile bindRange of
          Strict.Just rf -> Just rf
          Strict.Nothing -> Nothing
  p  <- rStart bindRange
  return (filePath (rangeFilePath rf), posLine p)

-- | Generate Agda's syntax-highlighted HTML for every visited module
-- and, for each given 'QName', slice out a highlighted snippet
-- containing its definition's paragraph.
--
-- The flow:
--
-- 1. Pick a temp directory under @outDir@ and run Agda's
--    'defaultPageGen' for each loaded module — this writes the same
--    @\<Module\>.html@ files that @agda --html@ produces.
-- 2. Read each file and extract the inner @\<pre class="Agda"\>@ block.
-- 3. For each 'QName', read its @.agda@ source file to find the
--    paragraph (run of non-blank lines) around the binding line,
--    then 'sliceHtmlByLine' the matching span out of the highlighted
--    @\<pre\>@ — preserving Agda's anchors and class attributes.
-- 4. Remove the temp directory.
collectHighlightedSnippets
  :: [String]     -- ^ Module-name prefixes to skip (from @--no-source-for@).
                  --   Matching modules are not rendered to HTML, and any
                  --   'QName' homed in one of them yields no snippet.
  -> FilePath -> [QName] -> TCM (Map QName Snippet)
collectHighlightedSnippets noSrcPrefixes outDir qns = do
  visited <- getVisitedModules
  let -- Keep modules that don't match any --no-source-for prefix;
      -- excluded modules are not rendered to HTML and yield no snippets.
      keepModule :: TopLevelModuleName -> Bool
      keepModule m = not (isExcludedModule noSrcPrefixes (prettyShow m))
      tlms   = filter keepModule (M.keys visited)
      tmpDir = outDir </> ".agda-deps-html"

  -- (1) Generate the per-module HTML files.
  liftIO $ createDirectoryIfMissing True tmpDir
  let opts = HtmlOptions
        { htmlOptDir = tmpDir
        , htmlOptHighlight = HighlightAll
        , htmlOptHighlightOccurrences = False
        , htmlOptCssFile = Nothing
        }
  forM_ tlms $ \tlmn -> case M.lookup tlmn visited of
    Nothing -> return ()
    Just mi -> liftIO . runLogHtmlWith (\_ -> return ()) $
      defaultPageGen opts (srcFileOfInterface tlmn (miInterface mi))

  -- (2) Read each generated file and extract its <pre> body.
  let preForModule :: TopLevelModuleName -> IO (Maybe String)
      preForModule tlmn = do
        let path = tmpDir </> prettyShow tlmn ++ ".html"
        exists <- doesFileExist path
        if not exists
          then return Nothing
          else extractPreBlock <$> readFile path
  tlmHtmlPairs <- liftIO $ mapM (\m -> fmap (\h -> (m, h)) (preForModule m)) tlms
  let tlmHtmlMap :: Map TopLevelModuleName String
      tlmHtmlMap = M.fromList [ (m, h) | (m, Just h) <- tlmHtmlPairs ]

  -- (3) For each QName: look up the .agda file from the binding-site
  -- range, find the paragraph bounds via the source text, then slice
  -- the highlighted <pre> for its top-level module.
  srcCache <- liftIO $ IORef.newIORef M.empty
  result <- liftIO $ M.fromList . catMaybes <$>
    mapM (snippetFor tlmHtmlMap srcCache) qns

  -- (4) Best-effort cleanup of the temp dir.
  liftIO $ removeDirectoryRecursive tmpDir `catch`
    (\(_ :: IOException) -> return ())

  return result

-- | Compute a snippet for a single 'QName' given the per-module
-- highlighted @\<pre\>@ bodies and a source-file line cache.
snippetFor
  :: Map TopLevelModuleName String                  -- per-module rendered <pre> body
  -> IORef.IORef (Map FilePath (Maybe [String]))    -- .agda source line cache
  -> QName
  -> IO (Maybe (QName, Snippet))
snippetFor tlmHtmlMap srcCache qn =
  case srcLocOf qn of
    Nothing            -> return Nothing
    Just (path, line1) -> do
      mLines <- readFileCached srcCache path
      case mLines of
        Nothing  -> return Nothing
        Just lns -> case paragraphBounds lns (fromIntegral line1) of
          Nothing       -> return Nothing
          Just (l1, l2) ->
            case findTopLevelForQName (M.keys tlmHtmlMap) qn of
              Nothing -> return Nothing
              Just tlmn ->
                case M.lookup tlmn tlmHtmlMap of
                  Nothing  -> return Nothing
                  Just pre -> do
                    let html = sliceHtmlByLine pre l1 l2
                    return $ Just (qn, Snippet { snippetStartLine = l1
                                               , snippetText      = html })

-- | Pick the top-level module name whose own 'ModuleName' is a prefix
-- of the 'QName'\'s @qnameModule@. (Longest-match wins.)
findTopLevelForQName :: [TopLevelModuleName] -> QName -> Maybe TopLevelModuleName
findTopLevelForQName tlms qn =
  let qmStr = prettyShow (qnameModule qn)
      candidates = [ tlmn
                   | tlmn <- tlms
                   , let s = prettyShow tlmn
                   , s == qmStr || (s ++ ".") `isPrefixOf` qmStr
                   ]
      best = foldr (\a b -> if length (prettyShow a) >= length (prettyShow b) then a else b)
  in case candidates of
       []     -> Nothing
       (x:xs) -> Just (best x xs)

readFileCached
  :: IORef.IORef (Map FilePath (Maybe [String]))
  -> FilePath -> IO (Maybe [String])
readFileCached cache path = do
  m <- IORef.readIORef cache
  case M.lookup path m of
    Just cached -> return cached
    Nothing     -> do
      exists <- doesFileExist path
      loaded <- if exists then Just . lines <$> readFile path else return Nothing
      IORef.modifyIORef' cache (M.insert path loaded)
      return loaded

-- | Paragraph (run of non-blank lines) around a 1-indexed line. Returns
-- the 1-indexed @(startLine, endLine)@ inclusive bounds.
paragraphBounds :: [String] -> Int -> Maybe (Int, Int)
paragraphBounds allLines line1Based =
  let n      = length allLines
      idx0   = line1Based - 1
      -- 0-indexed blank-line numbers, for O(1) membership while walking
      -- outward.
      blanks = IS.fromList [ i | (i, l) <- zip [0 ..] allLines, all isSpace l ]

      walkBack i
        | i <= 0                     = 0
        | (i - 1) `IS.member` blanks = i
        | otherwise                  = walkBack (i - 1)

      walkForward i
        | i >= n - 1                 = n - 1
        | (i + 1) `IS.member` blanks = i
        | otherwise                  = walkForward (i + 1)
  in if idx0 < 0 || idx0 >= n
     then Nothing
     else Just (walkBack idx0 + 1, walkForward idx0 + 1)

-- | Pull the content between @\<pre class="Agda"\>@ and @\</pre\>@ out
-- of a full Agda HTML page. Returns 'Nothing' if either tag is missing.
extractPreBlock :: String -> Maybe String
extractPreBlock html = do
  let startTag = "<pre class=\"Agda\">"
  afterStart <- stripUntilAfter startTag html
  let (body, _rest) = breakOnStr "</pre>" afterStart
  return body
  where
    stripUntilAfter :: String -> String -> Maybe String
    stripUntilAfter needle s
      | take (length needle) s == needle = Just (drop (length needle) s)
      | otherwise = case s of
          (_:cs) -> stripUntilAfter needle cs
          []     -> Nothing

    breakOnStr :: String -> String -> (String, String)
    breakOnStr needle = go ""
      where
        go acc s
          | take (length needle) s == needle = (reverse acc, s)
          | otherwise = case s of
              (c:cs) -> go (c:acc) cs
              []     -> (reverse acc, [])

-- | Slice an Agda-rendered @\<pre\>@ body to the substring covering
-- source lines @[startLine..endLine]@ (1-indexed). Counts line
-- boundaries only at literal @\\n@ characters outside any tag, so the
-- output stays balanced.
sliceHtmlByLine :: String -> Int -> Int -> String
sliceHtmlByLine s startLine endLine = go False 1 [] s
  where
    go _     _    acc [] = reverse acc
    go inTag line acc (c:cs)
      | line > endLine = reverse acc
      | otherwise =
          let inRange = line >= startLine && line <= endLine
              acc'    = if inRange then c:acc else acc
              inTag'  = case c of
                          '<' -> True
                          '>' | inTag -> False
                          _   -> inTag
              line'   = if not inTag && c == '\n' then line + 1 else line
          in go inTag' line' acc' cs
