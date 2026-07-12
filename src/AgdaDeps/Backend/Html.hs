{-# LANGUAGE TemplateHaskell #-}
-- | HTML output (v2 schema). Two modes:
--
-- * 'renderHtml' (default) — a single self-contained @deps.html@ with
--   the full v2 @graph.json@ inlined as a JS literal.
--
-- * 'renderLazyHtml' (with @--lazy@) — a small shell @deps.html@ plus
--   sibling @graph.json@ and per-module @modules\/\<Module\>.json@,
--   @snippets\/\<Module\>.json@ files, loaded on demand via @fetch()@.
--
-- The v2 wire shape lives in 'AgdaDeps.Backend.GraphJson'; this module
-- only stitches the resulting JSON into the HTML template.
module AgdaDeps.Backend.Html
  ( renderHtml
  , renderLazyHtml
  , LazyOutput(..)
    -- * Lower-level entry: caller supplies a full 'GraphInput'.
  , renderHtmlFromInput
  ) where

import Data.List ( intercalate, isPrefixOf )
import Data.Map ( Map )
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Word ( Word64 )

import Data.FileEmbed ( embedStringFile )

import Agda.Syntax.Abstract.Name ( QName )
import Agda.Utils.Hash ( hashString )

import AgdaDeps.Deps    ( hashQName, moduleKey )
import AgdaDeps.Options ( ColorPalette(..), View(..) )
import AgdaDeps.Source  ( Snippet(..) )
import AgdaDeps.Util    ( jsString )

import AgdaDeps.Backend.GraphJson
  ( GraphInput(..), GraphJsonOutput(..)
  , ModuleDetailJson(mdjFileName, mdjEpoch, mdjContent)
  , buildGraphJson
  , snippetBundleFilename
  )

-- ** Public API

-- | Render the dependency graph as a single self-contained HTML
-- document. The v2 graph.json is inlined as a JS literal.
renderHtml
  :: View                   -- ^ which view template to use
  -> ColorPalette
  -> Bool                   -- ^ @--gzip@ enabled (passed through to template).
  -> Maybe FilePath         -- ^ @--agda-html-dir@ base (Nothing = no source links).
  -> Map QName Snippet      -- ^ per-definition source snippets (@--with-source@)
  -> GraphInput             -- ^ shared graph data (from "AgdaDeps.Backend")
  -> String
renderHtml view palette gzipEnabled agdaHtmlDir snippetMap gi =
  let gi' = gi { giWithSource     = not (M.null snippetMap)
               , giSnippetModules = snippetModulesOf snippetMap
               }
  in renderHtmlFromInput view palette gzipEnabled agdaHtmlDir gi'

-- | Render HTML straight from a 'GraphInput'. The high-level
-- 'renderHtml' is a wrapper around this for callers that build the
-- input from the per-field defaults; 'AgdaDeps.SkipAgda' uses this
-- directly so it can set 'giExtraModules' for the source-scan-only
-- module set.
renderHtmlFromInput :: View -> ColorPalette -> Bool -> Maybe FilePath -> GraphInput -> String
renderHtmlFromInput view palette gzipEnabled agdaHtmlDir gi =
  let gjo          = buildGraphJson gi
      withSourceJs = if giWithSource gi then "true" else "false"
  in htmlTemplate view palette gzipEnabled agdaHtmlDir TemplateInline (gjoGraphJson gjo) withSourceJs

-- | The fan-out of files for the lazy HTML output mode.
--
-- The module-detail and snippet entries carry a content @epoch@
-- ('Word64') alongside the filename and content, so the
-- incremental-serialise path can skip rewriting an unchanged file
-- without forcing its (lazy) content thunk.
data LazyOutput = LazyOutput
  { lazyShellHtml      :: String
  , lazyGraphJson      :: String
  , lazyModuleDetails  :: [(FilePath, Word64, String)]
    -- ^ @(filename-only, epoch, content)@ to write under @modules/@.
  , lazySnippetBundles :: [(FilePath, Word64, String)]
    -- ^ @(filename-only, epoch, content)@ to write under @snippets/@.
  }

-- | Render the dependency graph as a small page shell plus separate
-- JSON files.
renderLazyHtml
  :: View                   -- ^ which view template to use
  -> ColorPalette
  -> Bool                   -- ^ @--gzip@ enabled.
  -> Maybe FilePath         -- ^ @--agda-html-dir@ base (Nothing = no source links).
  -> Map QName Snippet      -- ^ per-definition source snippets (@--with-source@)
  -> GraphInput             -- ^ shared graph data (from "AgdaDeps.Backend")
  -> LazyOutput
renderLazyHtml view palette gzipEnabled agdaHtmlDir snippetMap giBase =
  let -- Group snippets by their 'moduleKey' (lifted owning module) so the
      -- bundle manifest keys match the graph.json module names. 'foldr'
      -- over 'M.toAscList' with 'insertWith (++)' keeps each module's
      -- entries in ascending-QName order.
      snippetsByModule :: Map String [(QName, Snippet)]
      snippetsByModule =
        foldr (\(qn, sn) -> M.insertWith (++) (moduleKey qn) [(qn, sn)])
              M.empty (M.toAscList snippetMap)
      snippetModules = M.keys snippetsByModule
      gi = giBase { giWithSource     = not (M.null snippetMap)
                  , giSnippetModules = snippetModules
                  , giLazy           = True
                  }
      gjo = buildGraphJson gi

      moduleDetails =
        [ (mdjFileName md, mdjEpoch md, mdjContent md) | md <- gjoModuleDetails gjo ]

      snippetBundles =
        [ ( snippetBundleFilename m
          , snippetBundleEpoch entries
          , renderBundleJson entries
          )
        | (m, entries) <- M.toAscList snippetsByModule
        ]

      withSourceJs = if M.null snippetMap then "false" else "true"
      shellHtml = htmlTemplate view palette gzipEnabled agdaHtmlDir TemplateLazy "" withSourceJs
  in LazyOutput
       { lazyShellHtml      = shellHtml
       , lazyGraphJson      = gjoGraphJson gjo
       , lazyModuleDetails  = moduleDetails
       , lazySnippetBundles = snippetBundles
       }

-- | Sorted list of the modules that have at least one snippet.
snippetModulesOf :: Map QName Snippet -> [String]
snippetModulesOf snippetMap =
  S.toAscList . S.fromList $
    [ moduleKey qn | qn <- M.keys snippetMap ]

-- | Serialise one module's snippets as a JSON object keyed by the
-- node's 'hashQName'.
renderBundleJson :: [(QName, Snippet)] -> String
renderBundleJson entries =
  "{" ++ intercalate "," (map renderEntry entries) ++ "}"
  where
    renderEntry (qn, sn) =
      "\"" ++ show (hashQName qn) ++ "\":"
      ++ "{\"source\":" ++ jsString (snippetText sn)
      ++ ",\"sourceLine\":" ++ show (snippetStartLine sn)
      ++ "}"

-- | Cheap content fingerprint of a snippet bundle, mirroring
-- 'renderBundleJson''s inputs (node id + source + line) without
-- building the JSON. Lets the incremental-serialise path skip
-- rewriting an unchanged bundle.
snippetBundleEpoch :: [(QName, Snippet)] -> Word64
snippetBundleEpoch entries =
  hashString $ concat
    [ show (hashQName qn) ++ "\v" ++ show (snippetStartLine sn)
      ++ "\v" ++ snippetText sn ++ "\f"
    | (qn, sn) <- entries ]

-- ** Template

data TemplateMode = TemplateInline | TemplateLazy

-- | The page shell.  Substitutes a small set of placeholders into the
-- embedded HTML template body. The template is chosen by 'View'.
htmlTemplate :: View -> ColorPalette -> Bool -> Maybe FilePath -> TemplateMode -> String -> String -> String
htmlTemplate view palette gzipEnabled agdaHtmlDir mode graphLit withSourceJson =
  subst
    [ ("__DATA_LOADING_PRELUDE__", dataLoadingPrelude mode graphLit withSourceJson gzipEnabled agdaHtmlDir)
    , ("__COLOR_DEFINED__",        colorDefined   palette)
    , ("__COLOR_POSTULATE__",      colorPostulate palette)
    , ("__COLOR_HOLE__",           colorHole      palette)
    , ("__COLOR_FAILED__",         colorFailed    palette)
    , ("__GZIP_ENABLED__",         if gzipEnabled then "true" else "false")
    ]
    (templateRawFor view)

-- | The raw HTML template for a given 'View', embedded at compile time.
-- Each view has its own self-contained template file under
-- @src/AgdaDeps/templates/views/@; the legacy cytoscape template stays
-- at @src/AgdaDeps/templates/deps.html.tmpl@.
templateRawFor :: View -> String
templateRawFor ViewCytoscape     = $(embedStringFile "src/AgdaDeps/templates/deps.html.tmpl")
templateRawFor ViewIdeThreePane  = $(embedStringFile "src/AgdaDeps/templates/views/ide-three-pane.html.tmpl")
templateRawFor ViewModuleDagPods = $(embedStringFile "src/AgdaDeps/templates/views/module-dag-pods.html.tmpl")
templateRawFor ViewSourceCentric = $(embedStringFile "src/AgdaDeps/templates/views/source-centric.html.tmpl")
templateRawFor ViewNotionDoc     = $(embedStringFile "src/AgdaDeps/templates/views/notion-doc.html.tmpl")
templateRawFor ViewWikiBacklinks = $(embedStringFile "src/AgdaDeps/templates/views/wiki-backlinks.html.tmpl")
templateRawFor ViewSigma         = $(embedStringFile "src/AgdaDeps/templates/views/sigma.html.tmpl")
templateRawFor ViewBigModuleDagPods = $(embedStringFile "src/AgdaDeps/templates/views/big-module-dag-pods.html.tmpl")
templateRawFor ViewCriticalPathHoles     = $(embedStringFile "src/AgdaDeps/templates/views/critical-path-holes.html.tmpl")
templateRawFor ViewProgressDashboard     = $(embedStringFile "src/AgdaDeps/templates/views/progress-dashboard.html.tmpl")
templateRawFor ViewCartographicAtlas     = $(embedStringFile "src/AgdaDeps/templates/views/cartographic-atlas.html.tmpl")
templateRawFor ViewSunburstHierarchy     = $(embedStringFile "src/AgdaDeps/templates/views/sunburst-hierarchy.html.tmpl")
templateRawFor ViewReadingOrderNarrative = $(embedStringFile "src/AgdaDeps/templates/views/reading-order-narrative.html.tmpl")
templateRawFor ViewPixelGridOverview     = $(embedStringFile "src/AgdaDeps/templates/views/pixel-grid-overview.html.tmpl")

-- | The data-loading prelude that runs before the main app.
dataLoadingPrelude :: TemplateMode -> String -> String -> Bool -> Maybe FilePath -> String
dataLoadingPrelude mode graphLit withSourceJson gzipEnabled agdaHtmlDir = case mode of
  TemplateInline -> intercalate "\n"
    [ "var LAZY = false;"
    , "var WITH_SOURCE = " ++ withSourceJson ++ ";"
    , "var GZIP_ENABLED = " ++ gzipFlag ++ ";"
    , "var AGDA_HTML_BASE = " ++ agdaHtmlBaseLit ++ ";"
    , "var GRAPH = " ++ graphLit ++ ";"
    , "var GRAPH_URL = null;"
    , "var SNIPPETS_BASE = null;"
    , "var MODULES_BASE = null;"
    ]
  TemplateLazy -> intercalate "\n"
    [ "var LAZY = true;"
    , "var WITH_SOURCE = " ++ withSourceJson ++ ";"
    , "var GZIP_ENABLED = " ++ gzipFlag ++ ";"
    , "var AGDA_HTML_BASE = " ++ agdaHtmlBaseLit ++ ";"
    , "var GRAPH = null;"
    , "var GRAPH_URL = 'graph.json';"
    , "var SNIPPETS_BASE = 'snippets/';"
    , "var MODULES_BASE = 'modules/';"
    ]
  where
    gzipFlag = if gzipEnabled then "true" else "false"
    -- Emitted verbatim (browser resolves it relative to the page),
    -- with a single trailing slash so the view can do BASE + file.
    agdaHtmlBaseLit = case agdaHtmlDir of
      Nothing  -> "null"
      Just dir -> jsString (ensureTrailingSlash dir)
    ensureTrailingSlash p
      | null p              = "./"
      | last p == '/'       = p
      | otherwise           = p ++ "/"

-- | Simple text substitution: walk the input once, replacing each
-- occurrence of a known placeholder with its mapped expansion.
subst :: [(String, String)] -> String -> String
subst _   [] = []
subst tbl s@(c:rest) =
  case matchFirst tbl s of
    Just (k, v) -> v ++ subst tbl (drop (length k) s)
    Nothing     -> c : subst tbl rest
  where
    matchFirst []           _   = Nothing
    matchFirst ((k, v):kvs) inp
      | k `isPrefixOf` inp = Just (k, v)
      | otherwise          = matchFirst kvs inp
