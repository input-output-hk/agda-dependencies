{-# LANGUAGE FlexibleContexts #-}
-- | Backend configuration: 'Options', its CLI parsers, and the
-- supporting palette / output-format / def-state types.
module AgdaDeps.Options
  ( -- * Output format
    OutputFormat(..)
  , formatSlug
  , allFormats

    -- * JSON emission mode
  , JsonMode(..)
  , jsonModeSlug
  , allJsonModes

    -- * HTML view
  , View(..)
  , viewSlug
  , allViews

    -- * Slug tables
  , parseSlug

    -- * Definition state
  , DefState(..)
  , colorFor

    -- * Colour palette
  , ColorPalette(..)
  , defaultPalette

    -- * Options
  , Options(..)
  , defaultOptions

    -- * CLI option parsers
  , outdirOpt
  , formatOpt
  , viewOpt
  , withSourceOpt
  , agdaHtmlDirOpt
  , lazyOpt
  , colorOpt
  , excludeOpt
  , noSourceForOpt
  , maxSnippetBytesOpt
  , gzipOpt
  , keepGoingOpt
  , skipAgdaOpt
  , incrementalOpt
  , cacheDirOpt
  , packedAnalyticalOpt
  , quietOpt
  , noExternalsOpt
  , jsonModeOpt
  , lenientImportsOpt, resolveDepsOpt
  , withTermHashesOpt
  , minTermDepthOpt
  , withSignaturesOpt
  , normaliseSignaturesOpt
  , showImplicitOpt

    -- * Module-exclusion predicate
  , isExcludedModule
  ) where

import Control.DeepSeq ( NFData(..) )
import Control.Monad.Except ( MonadError(throwError) )
import Data.Binary ( Binary(..) )
import qualified Data.Binary as B
import Data.List ( intercalate, isPrefixOf )

import AgdaDeps.Util ( isValidHexColor )

-- | DOT, HTML, or JSON output.
data OutputFormat = FmtDot | FmtHtml | FmtJson
  deriving (Show, Eq)

-- | How @--format=json@ emits the v2 graph. Packed: CSR adjacency +
-- per-def state as base64 typed arrays. Expanded: definitions as records,
-- edges as qname pairs.
data JsonMode = JsonPacked | JsonExpanded
  deriving (Show, Eq)

instance NFData JsonMode where
  rnf JsonPacked   = ()
  rnf JsonExpanded = ()

instance NFData OutputFormat where
  rnf FmtDot  = ()
  rnf FmtHtml = ()
  rnf FmtJson = ()

-- | Canonical CLI slug for an 'OutputFormat'.
formatSlug :: OutputFormat -> String
formatSlug FmtDot  = "dot"
formatSlug FmtHtml = "html"
formatSlug FmtJson = "json"

-- | Every 'OutputFormat', in the order accepted values are listed to the
-- user. Together with 'formatSlug' this is the single source of truth for
-- @--format@ \/ @format:@ — CLI parser, YAML parser, and @doctor@ all
-- derive their accepted set from it.
allFormats :: [OutputFormat]
allFormats = [FmtDot, FmtHtml, FmtJson]

-- | Canonical CLI slug for a 'JsonMode'.
jsonModeSlug :: JsonMode -> String
jsonModeSlug JsonPacked   = "packed"
jsonModeSlug JsonExpanded = "expanded"

-- | Every 'JsonMode'. See 'allFormats'.
allJsonModes :: [JsonMode]
allJsonModes = [JsonPacked, JsonExpanded]

-- | Resolve a user-supplied slug against a canonical table, or produce the
-- standard \"Unknown …\" diagnostic naming every accepted value. @what@ is
-- how the setting is spelled in the message (@\"--view\"@ for a CLI flag,
-- @\"view\"@ for the YAML key).
parseSlug :: String -> (a -> String) -> [a] -> String -> Either String a
parseSlug what slug vals s = case [ v | v <- vals, slug v == s ] of
  (v:_) -> Right v
  []    -> Left $ "Unknown " ++ what ++ " value: " ++ show s
               ++ ". Expected one of: " ++ intercalate ", " (map slug vals) ++ "."

-- | HTML view variant. Selects which JS app the @--format=html@ output
-- ships. All views consume the same v2 @graph.json@ payload built by
-- "AgdaDeps.Backend.GraphJson"; only the template differs.
data View
  = ViewCytoscape       -- ^ Original cytoscape-compound-graph viewer.
  | ViewIdeThreePane    -- ^ Concept 01: file tree + focused subgraph + source.
  | ViewModuleDagPods   -- ^ Concept 02: top-down DAG of expandable module pods.
  | ViewSourceCentric   -- ^ Concept 06: code-first with minimap.
  | ViewNotionDoc       -- ^ Concept 09: scrollable cross-linked document.
  | ViewWikiBacklinks   -- ^ Concept 10: single-page focus with depends-on / used-by.
  | ViewSigma           -- ^ WebGL module-level renderer via sigma.js + graphology.
  | ViewBigModuleDagPods
    -- ^ Scaling variant of 'ViewModuleDagPods': pre-computed module-DAG
    -- layout (Haskell-side, see 'buildModuleDagLayout') + viewport
    -- virtualisation in the browser. Targets ~100k modules.
  | ViewCriticalPathHoles      -- ^ Concept 12: kanban of proof obligations.
  | ViewProgressDashboard      -- ^ Concept 14: Grafana-style KPI board.
  | ViewCartographicAtlas      -- ^ Concept 15: topographic map metaphor.
  | ViewSunburstHierarchy      -- ^ Concept 16: D3 sunburst over dotted-module tree.
  | ViewReadingOrderNarrative  -- ^ Concept 17: textbook-style topo-ordered scroll.
  | ViewPixelGridOverview      -- ^ Concept 20: every def is a colored tile.
  deriving (Show, Eq)

instance NFData View where
  rnf ViewCytoscape              = ()
  rnf ViewIdeThreePane           = ()
  rnf ViewModuleDagPods          = ()
  rnf ViewSourceCentric          = ()
  rnf ViewNotionDoc              = ()
  rnf ViewWikiBacklinks          = ()
  rnf ViewSigma                  = ()
  rnf ViewBigModuleDagPods       = ()
  rnf ViewCriticalPathHoles      = ()
  rnf ViewProgressDashboard      = ()
  rnf ViewCartographicAtlas      = ()
  rnf ViewSunburstHierarchy      = ()
  rnf ViewReadingOrderNarrative  = ()
  rnf ViewPixelGridOverview      = ()

-- | Every 'View', in the order accepted values are listed to the user.
-- See 'allFormats'.
allViews :: [View]
allViews =
  [ ViewCytoscape, ViewIdeThreePane, ViewModuleDagPods, ViewSourceCentric
  , ViewNotionDoc, ViewWikiBacklinks, ViewSigma, ViewBigModuleDagPods
  , ViewCriticalPathHoles, ViewProgressDashboard, ViewCartographicAtlas
  , ViewSunburstHierarchy, ViewReadingOrderNarrative, ViewPixelGridOverview
  ]

-- | Canonical CLI slug for a 'View'.
viewSlug :: View -> String
viewSlug ViewCytoscape        = "cytoscape"
viewSlug ViewIdeThreePane     = "ide-three-pane"
viewSlug ViewModuleDagPods    = "module-dag-pods"
viewSlug ViewSourceCentric    = "source-centric"
viewSlug ViewNotionDoc        = "notion-doc"
viewSlug ViewWikiBacklinks    = "wiki-backlinks"
viewSlug ViewSigma            = "sigma"
viewSlug ViewBigModuleDagPods       = "big-module-dag-pods"
viewSlug ViewCriticalPathHoles      = "critical-path-holes"
viewSlug ViewProgressDashboard      = "progress-dashboard"
viewSlug ViewCartographicAtlas      = "cartographic-atlas"
viewSlug ViewSunburstHierarchy      = "sunburst-hierarchy"
viewSlug ViewReadingOrderNarrative  = "reading-order-narrative"
viewSlug ViewPixelGridOverview      = "pixel-grid-overview"


-- | The state of a definition for the purpose of node colouring.
--
-- 'Failed' is synthetic: there is no real 'Definition' behind it. It
-- tags a bare-module node emitted when Agda's type-checker raised a
-- 'TCErr' under @--keep-going@ (see 'AgdaDeps.Backend.failedModulesRef').
data DefState = Defined | Postulate | Hole | Failed
  deriving (Show, Eq)

instance NFData DefState where
  rnf Defined   = ()
  rnf Postulate = ()
  rnf Hole      = ()
  rnf Failed    = ()

-- | Tagged 'Word8' encoding for the @--incremental@ fragment cache.
instance Binary DefState where
  put Defined   = B.putWord8 0
  put Postulate = B.putWord8 1
  put Hole      = B.putWord8 2
  put Failed    = B.putWord8 3
  get = B.getWord8 >>= \w -> case w of
    0 -> pure Defined
    1 -> pure Postulate
    2 -> pure Hole
    3 -> pure Failed
    _ -> fail "DefState"

-- | Hex (\"#rrggbb\") colours for each 'DefState'.
data ColorPalette = ColorPalette
  { colorDefined   :: String
  , colorPostulate :: String
  , colorHole      :: String
  , colorFailed    :: String
  } deriving (Show, Eq)

instance NFData ColorPalette where
  rnf (ColorPalette a b c d) = rnf a `seq` rnf b `seq` rnf c `seq` rnf d `seq` ()

defaultPalette :: ColorPalette
defaultPalette = ColorPalette
  { colorDefined   = "#4caf50"
  , colorPostulate = "#f44336"
  , colorHole      = "#9c27b0"
  , colorFailed    = "#ff9800"
  }

-- | Pick a hex colour from a palette for a given 'DefState'.
colorFor :: ColorPalette -> DefState -> String
colorFor p Defined   = colorDefined   p
colorFor p Postulate = colorPostulate p
colorFor p Hole      = colorHole      p
colorFor p Failed    = colorFailed    p

-- | The full set of backend options, populated from CLI flags.
data Options = Options
  { optOutDir     :: Maybe FilePath
  , optFormat     :: OutputFormat
  , optView       :: View
  , optColors     :: ColorPalette
  , optWithSource :: Bool
  , optLazy       :: Bool
  , optExcludeModules :: [String]
  , optNoSourceFor :: [String]
  , optMaxSnippetBytes :: Maybe Int
  , optGzip :: Bool
  , optKeepGoing :: Bool
  , optSkipAgda :: Bool
  , optQuiet :: Bool
  , optNoExternals :: Bool
  , optJsonMode :: JsonMode
  , optLenientImports :: Bool
  , optWithTermHashes :: Bool
    -- ^ Compute a canonical-form hash for every subterm walked in
    -- @compileDefAD@; emit the per-def @definitionSubtermHashes@ array in
    -- expanded JSON. Off by default. See 'AgdaDeps.TermCanon'.
  , optMinTermDepth   :: !Int
    -- ^ Minimum AST depth at which a subterm's hash gets emitted.
    -- Default 3; @1@ disables filtering. Ignored when
    -- 'optWithTermHashes' is 'False'.
  , optWithSignatures :: Bool
    -- ^ Emit each definition's reified type (@defType@ via @prettyTCM@)
    -- as the per-def @"type"@ field in expanded JSON. Not normalised,
    -- Agda's default printing. Off by default.
  , optNormaliseSignatures :: Bool
    -- ^ @--normalise-signatures@: 'normalise' each type before rendering
    -- under 'optWithSignatures'. Off by default; no effect without it.
  , optShowImplicit   :: Bool
    -- ^ @--signature-implicits@ (named to avoid Agda's own
    -- @--show-implicit@): show implicit + irrelevant args in signatures,
    -- via 'withShowAllArguments'. No effect without 'optWithSignatures'.
  , optIncremental    :: Bool
    -- ^ @--incremental@: per-module fragment cache for the
    -- per-definition backend walk, keyed on the interface hash.
    -- Opt-in; disabled under @--keep-going@. See 'AgdaDeps.FragmentCache'.
  , optCacheDir       :: Maybe FilePath
    -- ^ @--cache-dir=PATH@: override the @--incremental@ cache location
    -- (fragments + serialise manifest). Default
    -- @\<out-dir\>/.agda-deps-cache@; no effect without @--incremental@.
  , optPackedAnalytical :: Bool
    -- ^ @--packed-analytical@: add the per-def analytical arrays
    -- (kind\/line\/access\/type\/subterm hashes) to the packed @defs@
    -- object, so packed carries what expanded does. Off by default
    -- (packed stays byte-identical); only affects @--json-mode=packed@.
  , optAgdaHtmlDir    :: Maybe FilePath
    -- ^ @--agda-html-dir=DIR@: @agda --html@ pages location, resolved by
    -- the browser relative to the generated HTML. When 'Just', views add
    -- an "Open source" link to @DIR\/\<Module.Name\>.html@ (the
    -- @AGDA_HTML_BASE@ prelude var). 'Nothing' disables it.
  }

instance NFData Options where
  rnf (Options d f v c s l e ns ms g k sa q ne jm li wth mtd wsig nsig simp inc cd pa ahd) =
        rnf d  `seq` rnf f  `seq` rnf v  `seq` rnf c  `seq` rnf s
    `seq` rnf l  `seq` rnf e  `seq` rnf ns `seq` rnf ms
    `seq` rnf g  `seq` rnf k  `seq` rnf sa
    `seq` rnf q  `seq` rnf ne `seq` rnf jm `seq` rnf li
    `seq` rnf wth `seq` rnf mtd `seq` rnf wsig
    `seq` rnf nsig `seq` rnf simp `seq` rnf inc `seq` rnf cd `seq` rnf pa `seq` rnf ahd
    `seq` ()

defaultOptions :: Options
defaultOptions = Options
  { optOutDir          = Nothing
  , optFormat          = FmtDot
  , optView            = ViewModuleDagPods
  , optColors          = defaultPalette
  , optWithSource      = False
  , optLazy            = False
  , optExcludeModules  = []
  , optNoSourceFor     = []
  , optMaxSnippetBytes = Just 1000000
  , optGzip            = False
  , optKeepGoing       = False
  , optSkipAgda        = False
  , optQuiet           = False
  , optNoExternals     = False
  , optJsonMode        = JsonPacked
  , optLenientImports  = False
  , optWithTermHashes  = False
  , optMinTermDepth    = 3
  , optWithSignatures  = False
  , optNormaliseSignatures = False
  , optShowImplicit    = False
  , optIncremental     = False
  , optCacheDir        = Nothing
  , optPackedAnalytical = False
  , optAgdaHtmlDir     = Nothing
  }

-- | True when the given module name matches any of the configured
-- exclusion prefixes.
isExcludedModule :: [String] -> String -> Bool
isExcludedModule excludes m = any matches excludes
  where
    matches p = p == m || (p ++ ".") `isPrefixOf` m

-- ** CLI option parsers

outdirOpt :: Monad m => FilePath -> Options -> m Options
outdirOpt dir opts = return opts{ optOutDir = Just dir }

withSourceOpt :: Monad m => Options -> m Options
withSourceOpt opts = return opts{ optWithSource = True }

-- | @--agda-html-dir=DIR@. Stored verbatim; the browser interprets it
-- relative to the generated HTML file, so a relative path is expected.
agdaHtmlDirOpt :: Monad m => String -> Options -> m Options
agdaHtmlDirOpt dir opts = return opts{ optAgdaHtmlDir = Just dir }

lazyOpt :: Monad m => Options -> m Options
lazyOpt opts = return opts{ optLazy = True }

excludeOpt :: Monad m => String -> Options -> m Options
excludeOpt p opts = return opts{ optExcludeModules = p : optExcludeModules opts }

noSourceForOpt :: Monad m => String -> Options -> m Options
noSourceForOpt p opts = return opts{ optNoSourceFor = p : optNoSourceFor opts }

maxSnippetBytesOpt :: MonadError String m => String -> Options -> m Options
maxSnippetBytesOpt s opts = case reads s :: [(Int, String)] of
  [(n, "")] | n == 0 -> return opts{ optMaxSnippetBytes = Nothing }
            | n >  0 -> return opts{ optMaxSnippetBytes = Just n }
  _ -> throwError $
    "Invalid value for --max-snippet-bytes: " ++ show s
      ++ ". Expected a non-negative integer (0 disables the cap)."

gzipOpt :: Monad m => Options -> m Options
gzipOpt opts = return opts{ optGzip = True }

keepGoingOpt :: Monad m => Options -> m Options
keepGoingOpt opts = return opts{ optKeepGoing = True }

skipAgdaOpt :: Monad m => Options -> m Options
skipAgdaOpt opts = return opts{ optSkipAgda = True }

-- | Enable the per-module fragment cache. See 'optIncremental'.
incrementalOpt :: Monad m => Options -> m Options
incrementalOpt opts = return opts{ optIncremental = True }

-- | @--cache-dir=PATH@. Override the @--incremental@ cache location.
cacheDirOpt :: Monad m => FilePath -> Options -> m Options
cacheDirOpt dir opts = return opts{ optCacheDir = Just dir }

-- | @--packed-analytical@. Emit the analytical per-def arrays in packed
-- JSON. See 'optPackedAnalytical'.
packedAnalyticalOpt :: Monad m => Options -> m Options
packedAnalyticalOpt opts = return opts{ optPackedAnalytical = True }

quietOpt :: Monad m => Options -> m Options
quietOpt opts = return opts{ optQuiet = True }

noExternalsOpt :: Monad m => Options -> m Options
noExternalsOpt opts = return opts{ optNoExternals = True }

jsonModeOpt :: MonadError String m => String -> Options -> m Options
jsonModeOpt s opts =
  case parseSlug "--json-mode" jsonModeSlug allJsonModes s of
    Right m -> return opts{ optJsonMode = m }
    Left e  -> throwError e

-- | Parser for @--lenient-imports@. The flag is rewritten to
-- @--allow-unsolved-metas@ in 'Main.hs' before Agda's option parser
-- runs; this entry surfaces it in @--help@.
lenientImportsOpt :: Monad m => Options -> m Options
lenientImportsOpt opts = return opts{ optLenientImports = True }

-- | No-op parser. @--resolve-deps@ is consumed in 'Main.hs' (it
-- expands into @--no-libraries -i …@); this entry surfaces it in
-- @--help@.
resolveDepsOpt :: Monad m => Options -> m Options
resolveDepsOpt opts = return opts

-- | Enable subterm-hash emission. Off by default. See
-- 'AgdaDeps.TermCanon' for the canonicalisation contract.
withTermHashesOpt :: Monad m => Options -> m Options
withTermHashesOpt opts = return opts{ optWithTermHashes = True }

-- | Enable rendered type-signature emission (the per-def @"type"@ field
-- in expanded JSON). Off by default. See 'optWithSignatures'.
withSignaturesOpt :: Monad m => Options -> m Options
withSignaturesOpt opts = return opts{ optWithSignatures = True }

-- | Normalise type signatures before rendering (semantic form). Off by
-- default. Implies nothing on its own — only meaningful with
-- @--with-signatures@. See 'optNormaliseSignatures'.
normaliseSignaturesOpt :: Monad m => Options -> m Options
normaliseSignaturesOpt opts = return opts{ optNormaliseSignatures = True }

-- | Render type signatures with implicit (and irrelevant) arguments
-- shown. Off by default. Only meaningful with @--with-signatures@. See
-- 'optShowImplicit'.
showImplicitOpt :: Monad m => Options -> m Options
showImplicitOpt opts = return opts{ optShowImplicit = True }

-- | Set the minimum subterm AST depth for hash emission.
-- Validates that the value is a positive integer.
minTermDepthOpt :: MonadError String m => String -> Options -> m Options
minTermDepthOpt s opts = case reads s :: [(Int, String)] of
  [(n, "")] | n >= 1 -> return opts{ optMinTermDepth = n }
  _ -> throwError $
    "Invalid value for --min-term-depth: " ++ show s
      ++ ". Expected a positive integer (1 disables the filter)."

formatOpt :: MonadError String m => String -> Options -> m Options
formatOpt s opts = case parseSlug "--format" formatSlug allFormats s of
  Right f -> return opts{ optFormat = f }
  Left e  -> throwError e

viewOpt :: MonadError String m => String -> Options -> m Options
viewOpt s opts = case parseSlug "--view" viewSlug allViews s of
  Right v -> return opts{ optView = v }
  Left e  -> throwError e

-- | Build a CLI option parser that updates a single slot of 'optColors',
-- validating the hex syntax.
colorOpt
  :: MonadError String m
  => String                                   -- ^ flag name (for error message)
  -> (ColorPalette -> String -> ColorPalette) -- ^ palette setter
  -> String -> Options -> m Options
colorOpt flagName setter s opts
  | isValidHexColor s = return opts{ optColors = setter (optColors opts) s }
  | otherwise = throwError $
      "Invalid value for --" ++ flagName ++ ": " ++ show s
        ++ ". Expected a hex colour of the form #RRGGBB."
