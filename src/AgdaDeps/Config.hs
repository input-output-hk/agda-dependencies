{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wno-orphans #-}
-- | YAML config-file support for the @agda-deps@ backend.
--
-- Reads a @.agda-deps.yml@ (or @.agda-deps.yaml@) next to a
-- @*.agda-lib@ or one given via @--config=PATH@; every field is a CLI
-- flag kebab-cased without the leading @--@. Discovery order is
-- explicit \> env \> cwd \> walk-up to project root; merge order is
-- defaults \< config \< CLI. The @FromJSON@ instances live here so
-- "AgdaDeps.Options" stays aeson-free.
module AgdaDeps.Config
  ( -- * Config record
    Config(..)
  , defaultConfig

    -- * Theme presets
  , Theme(..)
  , parseTheme
  , applyTheme

    -- * Discovery + loading
  , discoverConfigPath
  , loadConfig

    -- * Merge
  , applyConfig

    -- * Sample config
  , showDefaultsYaml

    -- * argv helpers
  , extractConfigArg
  , inferFormatFromOutput
  ) where

import Control.Exception ( try, SomeException, displayException )
import Data.Aeson ( FromJSON(..), withObject, (.:?), withText )
import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A
import qualified Data.Text as T
import qualified Data.Yaml as Y

import Data.List ( stripPrefix )
import Data.Maybe ( fromMaybe )
import System.Directory
  ( doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory )
import System.Environment ( lookupEnv )
import System.Exit ( die )
import System.FilePath
  ( (</>), takeDirectory, takeExtension )

import AgdaDeps.Options
  ( Options(..), OutputFormat(..), JsonMode(..), View(..)
  , ColorPalette(..), defaultPalette, defaultOptions
  , viewSlug, formatSlug, jsonModeSlug
  )

-- | YAML config payload. Every field is 'Maybe' so an empty file
-- (@{}@) is valid and individual omissions leave the underlying
-- 'Options' default in place.
data Config = Config
  { cfgOutDir          :: Maybe FilePath
  , cfgFormat          :: Maybe OutputFormat
  , cfgView            :: Maybe View
  , cfgTheme           :: Maybe Theme
  , cfgColorDefined    :: Maybe String
  , cfgColorPostulate  :: Maybe String
  , cfgColorHole       :: Maybe String
  , cfgColorFailed     :: Maybe String
  , cfgWithSource      :: Maybe Bool
  , cfgLazy            :: Maybe Bool
  , cfgExcludeModules  :: Maybe [String]
  , cfgNoSourceFor     :: Maybe [String]
  , cfgMaxSnippetBytes :: Maybe (Maybe Int)
    -- ^ Outer 'Just' means the field was present in the YAML. Inner
    -- 'Nothing' means the user wrote @max-snippet-bytes: 0@ to disable
    -- the cap; matches the CLI's @--max-snippet-bytes=0@ semantics.
  , cfgGzip            :: Maybe Bool
  , cfgKeepGoing       :: Maybe Bool
  , cfgSkipAgda        :: Maybe Bool
  , cfgIncremental     :: Maybe Bool
    -- ^ Mirror of @--incremental@: per-module fragment cache.
  , cfgCacheDir        :: Maybe FilePath
    -- ^ Mirror of @--cache-dir=PATH@.
  , cfgPackedAnalytical :: Maybe Bool
    -- ^ Mirror of @--packed-analytical@.
  , cfgQuiet           :: Maybe Bool
  , cfgNoExternals     :: Maybe Bool
  , cfgJsonMode        :: Maybe JsonMode
  , cfgLenientImports  :: Maybe Bool
  , cfgResolveDeps     :: Maybe Bool
    -- ^ Mirror of @--resolve-deps@. Consumed in 'Main.hs'; kept here
    -- for kebab-case parity in YAML.
  , cfgWithTermHashes  :: Maybe Bool
    -- ^ Mirror of @--with-term-hashes@.
  , cfgMinTermDepth    :: Maybe Int
    -- ^ Mirror of @--min-term-depth=N@.
  , cfgWithSignatures  :: Maybe Bool
    -- ^ Mirror of @--with-signatures@: emit rendered type signatures.
  , cfgNormaliseSignatures :: Maybe Bool
    -- ^ Mirror of @--normalise-signatures@.
  , cfgShowImplicit    :: Maybe Bool
    -- ^ Mirror of @--signature-implicits@ (named to avoid clashing with
    -- Agda's own @--show-implicit@).
  , cfgAgdaHtmlDir     :: Maybe FilePath
    -- ^ Mirror of @--agda-html-dir=DIR@.
  } deriving (Show)

defaultConfig :: Config
defaultConfig = Config
  { cfgOutDir          = Nothing
  , cfgFormat          = Nothing
  , cfgView            = Nothing
  , cfgTheme           = Nothing
  , cfgColorDefined    = Nothing
  , cfgColorPostulate  = Nothing
  , cfgColorHole       = Nothing
  , cfgColorFailed     = Nothing
  , cfgWithSource      = Nothing
  , cfgLazy            = Nothing
  , cfgExcludeModules  = Nothing
  , cfgNoSourceFor     = Nothing
  , cfgMaxSnippetBytes = Nothing
  , cfgGzip            = Nothing
  , cfgKeepGoing       = Nothing
  , cfgSkipAgda        = Nothing
  , cfgIncremental     = Nothing
  , cfgCacheDir        = Nothing
  , cfgPackedAnalytical = Nothing
  , cfgQuiet           = Nothing
  , cfgNoExternals     = Nothing
  , cfgJsonMode        = Nothing
  , cfgLenientImports  = Nothing
  , cfgResolveDeps     = Nothing
  , cfgWithTermHashes  = Nothing
  , cfgMinTermDepth    = Nothing
  , cfgWithSignatures  = Nothing
  , cfgNormaliseSignatures = Nothing
  , cfgShowImplicit    = Nothing
  , cfgAgdaHtmlDir     = Nothing
  }

-- | Preset colour palette. Individual @--color-*@ CLI flags layer on
-- top of a theme, each overriding the slot it targets.
data Theme = ThemeDefault | ThemeLight | ThemeDark | ThemeColorblind
  deriving (Show, Eq)

-- | Parse the @--theme@ / @theme:@ value.
parseTheme :: String -> Either String Theme
parseTheme s = case s of
  "default"    -> Right ThemeDefault
  "light"      -> Right ThemeLight
  "dark"       -> Right ThemeDark
  "colorblind" -> Right ThemeColorblind
  _ -> Left $ "Unknown theme: " ++ show s
           ++ ". Expected one of: default, light, dark, colorblind."

-- | Apply a theme to the colour-palette slots of an 'Options'. The
-- four colours are set; everything else is left alone.
applyTheme :: Theme -> Options -> Options
applyTheme t opts = opts { optColors = themePalette t }

themePalette :: Theme -> ColorPalette
themePalette ThemeDefault    = defaultPalette
themePalette ThemeLight      = defaultPalette
themePalette ThemeDark       = ColorPalette
  { colorDefined   = "#81c784"
  , colorPostulate = "#ef5350"
  , colorHole      = "#ba68c8"
  , colorFailed    = "#ffb74d"
  }
themePalette ThemeColorblind = ColorPalette
  { colorDefined   = "#1b9e77"
  , colorPostulate = "#d95f02"
  , colorHole      = "#7570b3"
  , colorFailed    = "#e7298a"
  }

-- ---------------------------------------------------------------------------
-- FromJSON
-- ---------------------------------------------------------------------------

-- | Parse an enum-as-string field, deferring to the supplied parser
-- (e.g. 'parseTheme'). The result is wrapped 'Right'-ward; a 'Left'
-- becomes an aeson 'fail'.
parseEnum :: String -> (String -> Either String a) -> A.Value -> A.Parser a
parseEnum fieldName parse = withText fieldName $ \t ->
  case parse (T.unpack t) of
    Right v -> pure v
    Left e  -> fail e

instance FromJSON OutputFormat where
  parseJSON = parseEnum "format" $ \case
    "dot"  -> Right FmtDot
    "html" -> Right FmtHtml
    "json" -> Right FmtJson
    s -> Left $ "Unknown format: " ++ show s
              ++ ". Expected one of: dot, html, json."

instance FromJSON JsonMode where
  parseJSON = parseEnum "json-mode" $ \case
    "packed"   -> Right JsonPacked
    "expanded" -> Right JsonExpanded
    s -> Left $ "Unknown json-mode: " ++ show s
              ++ ". Expected one of: packed, expanded."

instance FromJSON View where
  parseJSON = parseEnum "view" $ \case
    "cytoscape"               -> Right ViewCytoscape
    "ide-three-pane"          -> Right ViewIdeThreePane
    "module-dag-pods"         -> Right ViewModuleDagPods
    "source-centric"          -> Right ViewSourceCentric
    "notion-doc"              -> Right ViewNotionDoc
    "wiki-backlinks"          -> Right ViewWikiBacklinks
    "sigma"                   -> Right ViewSigma
    "big-module-dag-pods"     -> Right ViewBigModuleDagPods
    "critical-path-holes"     -> Right ViewCriticalPathHoles
    "progress-dashboard"      -> Right ViewProgressDashboard
    "cartographic-atlas"      -> Right ViewCartographicAtlas
    "sunburst-hierarchy"      -> Right ViewSunburstHierarchy
    "reading-order-narrative" -> Right ViewReadingOrderNarrative
    "pixel-grid-overview"     -> Right ViewPixelGridOverview
    s -> Left $ "Unknown view: " ++ show s

instance FromJSON Theme where
  parseJSON = parseEnum "theme" parseTheme

instance FromJSON Config where
  -- A comment-only (or empty) YAML document decodes to 'Null'. Treat it as
  -- an empty config — all defaults — so a freshly-seeded file from
  -- @agda-deps --show-defaults > .agda-deps.yml@ loads cleanly before the
  -- user uncomments anything.
  parseJSON A.Null = pure defaultConfig
  parseJSON v = withObject "agda-deps config" parseObj v
    where
      parseObj o = do
        cfgOutDir          <- o .:? "out-dir"
        cfgFormat          <- o .:? "format"
        cfgView            <- o .:? "view"
        cfgTheme           <- o .:? "theme"
        cfgColorDefined    <- o .:? "color-defined"
        cfgColorPostulate  <- o .:? "color-postulate"
        cfgColorHole       <- o .:? "color-hole"
        cfgColorFailed     <- o .:? "color-failed"
        cfgWithSource      <- o .:? "with-source"
        cfgLazy            <- o .:? "lazy"
        cfgExcludeModules  <- o .:? "exclude"
        cfgNoSourceFor     <- o .:? "no-source-for"
        -- max-snippet-bytes: number; 0 disables the cap.
        rawMaxSnip         <- o .:? "max-snippet-bytes" :: A.Parser (Maybe Int)
        let cfgMaxSnippetBytes = case rawMaxSnip of
              Nothing -> Nothing
              Just 0  -> Just Nothing
              Just n
                | n > 0     -> Just (Just n)
                | otherwise -> Nothing  -- negatives ignored
        cfgGzip            <- o .:? "gzip"
        cfgKeepGoing       <- o .:? "keep-going"
        cfgSkipAgda        <- o .:? "skip-agda"
        cfgIncremental     <- o .:? "incremental"
        cfgCacheDir        <- o .:? "cache-dir"
        cfgPackedAnalytical <- o .:? "packed-analytical"
        cfgQuiet           <- o .:? "quiet"
        cfgNoExternals     <- o .:? "no-externals"
        cfgJsonMode        <- o .:? "json-mode"
        cfgLenientImports  <- o .:? "lenient-imports"
        cfgResolveDeps     <- o .:? "resolve-deps"
        cfgWithTermHashes  <- o .:? "with-term-hashes"
        cfgMinTermDepth    <- o .:? "min-term-depth"
        cfgWithSignatures  <- o .:? "with-signatures"
        cfgNormaliseSignatures <- o .:? "normalise-signatures"
        cfgShowImplicit    <- o .:? "signature-implicits"
        cfgAgdaHtmlDir     <- o .:? "agda-html-dir"
        pure Config{..}

-- ---------------------------------------------------------------------------
-- Merge
-- ---------------------------------------------------------------------------

-- | Overlay a 'Config' onto an 'Options' record: each 'Just' field
-- replaces the corresponding 'Options' slot; each 'Nothing' leaves it
-- alone. For colours, 'cfgTheme' replaces the whole palette first, then
-- individual @cfg*Color*@ fields override their slots.
applyConfig :: Config -> Options -> Options
applyConfig c opts0 =
  let opts1 = case cfgTheme c of
        Nothing -> opts0
        Just th -> applyTheme th opts0
      pal = optColors opts1
      pal' = pal
        { colorDefined   = fromMaybe (colorDefined   pal) (cfgColorDefined   c)
        , colorPostulate = fromMaybe (colorPostulate pal) (cfgColorPostulate c)
        , colorHole      = fromMaybe (colorHole      pal) (cfgColorHole      c)
        , colorFailed    = fromMaybe (colorFailed    pal) (cfgColorFailed    c)
        }
  in opts1
      { optOutDir          = maybe (optOutDir opts1) Just (cfgOutDir c)
      , optFormat          = fromMaybe (optFormat opts1) (cfgFormat c)
      , optView            = fromMaybe (optView   opts1) (cfgView   c)
      , optColors          = pal'
      , optWithSource      = fromMaybe (optWithSource opts1) (cfgWithSource c)
      , optLazy            = fromMaybe (optLazy       opts1) (cfgLazy       c)
      , optExcludeModules  = fromMaybe (optExcludeModules opts1) (cfgExcludeModules c)
      , optNoSourceFor     = fromMaybe (optNoSourceFor    opts1) (cfgNoSourceFor    c)
      , optMaxSnippetBytes = fromMaybe (optMaxSnippetBytes opts1) (cfgMaxSnippetBytes c)
      , optGzip            = fromMaybe (optGzip       opts1) (cfgGzip       c)
      , optKeepGoing       = fromMaybe (optKeepGoing  opts1) (cfgKeepGoing  c)
      , optSkipAgda        = fromMaybe (optSkipAgda   opts1) (cfgSkipAgda   c)
      , optIncremental     = fromMaybe (optIncremental opts1) (cfgIncremental c)
      , optCacheDir        = maybe (optCacheDir opts1) Just (cfgCacheDir c)
      , optPackedAnalytical = fromMaybe (optPackedAnalytical opts1) (cfgPackedAnalytical c)
      , optQuiet           = fromMaybe (optQuiet      opts1) (cfgQuiet      c)
      , optNoExternals     = fromMaybe (optNoExternals opts1) (cfgNoExternals c)
      , optJsonMode        = fromMaybe (optJsonMode    opts1) (cfgJsonMode    c)
      , optLenientImports  = fromMaybe (optLenientImports opts1) (cfgLenientImports c)
      , optWithTermHashes  = fromMaybe (optWithTermHashes opts1) (cfgWithTermHashes c)
      , optMinTermDepth    = fromMaybe (optMinTermDepth   opts1) (cfgMinTermDepth   c)
      , optWithSignatures  = fromMaybe (optWithSignatures opts1) (cfgWithSignatures c)
      , optNormaliseSignatures = fromMaybe (optNormaliseSignatures opts1) (cfgNormaliseSignatures c)
      , optShowImplicit    = fromMaybe (optShowImplicit   opts1) (cfgShowImplicit   c)
      , optAgdaHtmlDir     = maybe (optAgdaHtmlDir opts1) Just (cfgAgdaHtmlDir c)
      }

-- ---------------------------------------------------------------------------
-- Sample config
-- ---------------------------------------------------------------------------

-- | The text of the sample @.agda-deps.yml@ printed by
-- @agda-deps --show-defaults@: every YAML key with its built-in default
-- value and a one-line description, all commented out so redirecting the
-- output to a file (@agda-deps --show-defaults > .agda-deps.yml@)
-- reproduces the defaults exactly — the user uncomments only the keys
-- they want to override.
--
-- Defaults are read from 'defaultOptions' \/ 'defaultPalette' so they can
-- never drift from the real defaults. Keys and descriptions are kept in
-- sync by hand with the 'FromJSON' 'Config' instance and 'applyConfig';
-- adding a flag means adding its entry here too.
showDefaultsYaml :: String
showDefaultsYaml = unlines $
  [ "# agda-deps configuration (.agda-deps.yml)"
  , "#"
  , "# Written by `agda-deps --show-defaults`. Save it next to your project's"
  , "# *.agda-lib (or point at it with --config=PATH). Every option is shown"
  , "# with its built-in default and commented out; uncomment and edit the ones"
  , "# you want to change. Merge order: defaults < this file < CLI flags."
  , ""
  , "# --- Output ----------------------------------------------------------------"
  , ""
  , "# Output directory or file. Default: none (usually set with -o on the CLI)."
  , "# A .html / .json / .dot extension here also selects the format."
  , "#out-dir: deps"
  , ""
  , "# Output format: dot | html | json."
  , "#format: " ++ formatSlug (optFormat defaultOptions)
  , ""
  , "# HTML view (only used with format: html). One of: cytoscape,"
  , "# ide-three-pane, module-dag-pods, source-centric, notion-doc,"
  , "# wiki-backlinks, sigma, big-module-dag-pods, critical-path-holes,"
  , "# progress-dashboard, cartographic-atlas, sunburst-hierarchy,"
  , "# reading-order-narrative, pixel-grid-overview."
  , "#view: " ++ viewSlug (optView defaultOptions)
  , ""
  , "# --- Node colours ----------------------------------------------------------"
  , ""
  , "# Colour preset for the four definition states: default | light | dark |"
  , "# colorblind. The color-* keys below override individual slots. Default: none."
  , "#theme: default"
  , ""
  , "# Per-state node colours (#RRGGBB); quote them so YAML doesn't read # as a"
  , "# comment. D = Defined, P = Postulate, H = Hole, F = Failed (--keep-going)."
  , "#color-defined: " ++ yColor (colorDefined defaultPalette)
  , "#color-postulate: " ++ yColor (colorPostulate defaultPalette)
  , "#color-hole: " ++ yColor (colorHole defaultPalette)
  , "#color-failed: " ++ yColor (colorFailed defaultPalette)
  , ""
  , "# --- HTML source snippets --------------------------------------------------"
  , ""
  , "# Embed source snippets in the HTML (requires lazy: true; served over HTTP)."
  , "#with-source: " ++ yBool (optWithSource defaultOptions)
  , ""
  , "# Split HTML output into per-module files. Needs an HTTP server: browsers"
  , "# block fetch() on file://."
  , "#lazy: " ++ yBool (optLazy defaultOptions)
  , ""
  , "# Module-name prefixes to exclude from source snippets (with lazy +"
  , "# with-source). Example: [Agda.Builtin, Data]"
  , "#no-source-for: []"
  , ""
  , "# Maximum bytes per embedded source snippet; 0 disables the cap."
  , "#max-snippet-bytes: " ++ maxSnip
  , ""
  , "# Location of `agda --html` pages, resolved by the browser relative to the"
  , "# output HTML; adds an \"Open source\" link. Default: none."
  , "#agda-html-dir: html"
  , ""
  , "# --- JSON output -----------------------------------------------------------"
  , ""
  , "# JSON layout: packed (CSR adjacency + base64 typed arrays) | expanded"
  , "# (arrays of records)."
  , "#json-mode: " ++ jsonModeSlug (optJsonMode defaultOptions)
  , ""
  , "# Add the per-def analytical arrays (kind / line / access / type / subterm)"
  , "# to packed JSON. Only affects json-mode: packed."
  , "#packed-analytical: " ++ yBool (optPackedAnalytical defaultOptions)
  , ""
  , "# --- Type signatures (expanded JSON) ---------------------------------------"
  , ""
  , "# Emit each definition's reified type as the per-def \"type\" field."
  , "#with-signatures: " ++ yBool (optWithSignatures defaultOptions)
  , ""
  , "# Normalise type signatures before rendering. Needs with-signatures."
  , "#normalise-signatures: " ++ yBool (optNormaliseSignatures defaultOptions)
  , ""
  , "# Show implicit / irrelevant arguments in rendered signatures. Needs"
  , "# with-signatures."
  , "#signature-implicits: " ++ yBool (optShowImplicit defaultOptions)
  , ""
  , "# --- Subterm hashes (expanded JSON) ----------------------------------------"
  , ""
  , "# Emit a canonical-form hash for every subterm walked."
  , "#with-term-hashes: " ++ yBool (optWithTermHashes defaultOptions)
  , ""
  , "# Minimum AST depth for an emitted subterm hash; 1 disables the filter."
  , "# Needs with-term-hashes."
  , "#min-term-depth: " ++ show (optMinTermDepth defaultOptions)
  , ""
  , "# --- Filtering -------------------------------------------------------------"
  , ""
  , "# Module-name prefixes to omit from the graph entirely."
  , "# Example: [Agda.Builtin, Data]"
  , "#exclude: []"
  , ""
  , "# Drop definitions from outside the project (library / builtin modules)."
  , "#no-externals: " ++ yBool (optNoExternals defaultOptions)
  , ""
  , "# --- Type-checking pipeline ------------------------------------------------"
  , ""
  , "# Continue past type-check errors; a failing module is tagged F."
  , "#keep-going: " ++ yBool (optKeepGoing defaultOptions)
  , ""
  , "# Skip Agda entirely; build a module-level graph from a source scan."
  , "#skip-agda: " ++ yBool (optSkipAgda defaultOptions)
  , ""
  , "# Tolerate unsolved metas in imported modules (maps to --allow-unsolved-metas)."
  , "#lenient-imports: " ++ yBool (optLenientImports defaultOptions)
  , ""
  , "# Resolve the .agda-lib depend: closure into an explicit -i list (so no"
  , "# libraries file is needed)."
  , "#resolve-deps: false"
  , ""
  , "# --- Caching / misc --------------------------------------------------------"
  , ""
  , "# Per-module fragment cache keyed on the interface hash. Disabled under"
  , "# keep-going."
  , "#incremental: " ++ yBool (optIncremental defaultOptions)
  , ""
  , "# Override the --incremental cache location."
  , "# Default: <out-dir>/.agda-deps-cache."
  , "#cache-dir: .agda-deps-cache"
  , ""
  , "# Gzip the emitted artifacts."
  , "#gzip: " ++ yBool (optGzip defaultOptions)
  , ""
  , "# Suppress progress logging."
  , "#quiet: " ++ yBool (optQuiet defaultOptions)
  ]
  where
    yBool True  = "true"
    yBool False = "false"

    -- Colours start with '#', which YAML would read as a comment: quote them.
    yColor c = "\"" ++ c ++ "\""

    maxSnip = case optMaxSnippetBytes defaultOptions of
      Nothing -> "0"
      Just n  -> show n

-- ---------------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------------

-- | Resolve which config file (if any) should be loaded.
--
-- Precedence (highest first):
--
--   1. Explicit @--config=PATH@ argument. Missing file is an error.
--   2. @$AGDA_DEPS_CONFIG@ environment variable. Missing file is an error.
--   3. @./.agda-deps.yml@ or @./.agda-deps.yaml@ in the current dir.
--   4. Walk up from cwd to the nearest directory containing a
--      @*.agda-lib@; look for the same two filenames there.
--   5. Nothing — no config applied.
discoverConfigPath :: Maybe FilePath -> IO (Maybe FilePath)
discoverConfigPath (Just p) = do
  exists <- doesFileExist p
  if exists
    then pure (Just p)
    else die ("agda-deps: --config: file not found: " ++ p)
discoverConfigPath Nothing = do
  mEnv <- lookupEnv "AGDA_DEPS_CONFIG"
  case mEnv of
    Just p | not (null p) -> do
      exists <- doesFileExist p
      if exists
        then pure (Just p)
        else die ("agda-deps: $AGDA_DEPS_CONFIG: file not found: " ++ p)
    _ -> do
      cwd <- getCurrentDirectory
      mCwd <- findConfigIn cwd
      case mCwd of
        Just p  -> pure (Just p)
        Nothing -> walkUp cwd
  where
    walkUp d = do
      hit <- hasAgdaLib d
      if hit
        then findConfigIn d
        else do
          let up = takeDirectory d
          if up == d then pure Nothing else walkUp up

    hasAgdaLib :: FilePath -> IO Bool
    hasAgdaLib d = doesDirectoryExist d >>= \case
      False -> pure False
      True  -> any ((== ".agda-lib") . takeExtension) <$> listDirectory d

    findConfigIn :: FilePath -> IO (Maybe FilePath)
    findConfigIn d = do
      let candidates = [d </> ".agda-deps.yml", d </> ".agda-deps.yaml"]
      firstExisting candidates

    firstExisting :: [FilePath] -> IO (Maybe FilePath)
    firstExisting []     = pure Nothing
    firstExisting (p:ps) = do
      e <- doesFileExist p
      if e then pure (Just p) else firstExisting ps

-- | Parse a YAML config file. Errors with a diagnostic that names the
-- file path on parse failure.
loadConfig :: FilePath -> IO Config
loadConfig path = do
  res <- try (Y.decodeFileEither path) :: IO (Either SomeException (Either Y.ParseException Config))
  case res of
    Left exc -> die $ "agda-deps: failed to read config file "
                   ++ path ++ ":\n  " ++ displayException exc
    Right (Left perr) -> die $ "agda-deps: failed to parse config file "
                            ++ path ++ ":\n  " ++ Y.prettyPrintParseException perr
    Right (Right cfg) -> pure cfg

-- ---------------------------------------------------------------------------
-- argv helpers
-- ---------------------------------------------------------------------------

-- | Strip the @--config=PATH@ or @--config PATH@ token pair out of
-- argv, returning the parsed path and the cleaned argv. If the flag
-- appears more than once the last occurrence wins.
extractConfigArg :: [String] -> (Maybe FilePath, [String])
extractConfigArg = go Nothing []
  where
    go acc keep [] = (acc, reverse keep)
    go acc keep (a : rest)
      | a == "--config" = case rest of
          (v : rest') -> go (Just v) keep rest'
          []          -> (acc, reverse keep)  -- malformed; left for GetOpt
      | Just v <- stripPrefix "--config=" a =
          go (Just v) keep rest
      | otherwise = go acc (a : keep) rest

-- | Look at @-o@ / @--out-dir=…@ in argv and, if its value has a
-- recognised extension, return the format that should be inferred.
-- Returns 'Nothing' for directories, missing flags, or unrecognised
-- extensions.
inferFormatFromOutput :: [String] -> Maybe String
inferFormatFromOutput = pickValue
  where
    pickValue [] = Nothing
    pickValue (a : rest)
      | a == "-o" || a == "--out-dir" = case rest of
          (v : _) -> matchExt v
          []      -> Nothing
      | Just v <- stripPrefix "-o=" a       = matchExt v
      | Just v <- stripPrefix "--out-dir=" a = matchExt v
      | otherwise = pickValue rest

    matchExt :: FilePath -> Maybe String
    matchExt v = case takeExtension v of
      ".html" -> Just "html"
      ".json" -> Just "json"
      ".dot"  -> Just "dot"
      _       -> Nothing

