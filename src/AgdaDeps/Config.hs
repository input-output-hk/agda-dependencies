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
-- defaults \< config \< CLI.
--
-- 'loadConfig' / 'discoverConfigPath' do the IO; the merge
-- ('applyConfig') and theme application ('applyTheme') are pure
-- record-overlay functions. The @FromJSON@ instances for
-- 'OutputFormat' / 'JsonMode' / 'View' / 'Theme' live here so
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

import Data.Maybe ( fromMaybe )
import System.Directory
  ( doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory )
import System.Environment ( lookupEnv )
import System.Exit ( die )
import System.FilePath
  ( (</>), takeDirectory, takeExtension )

import AgdaDeps.Options
  ( Options(..), OutputFormat(..), JsonMode(..), View(..)
  , ColorPalette(..), defaultPalette
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
  parseJSON = withObject "agda-deps config" $ \o -> do
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

    stripPrefix p s
      | take (length p) s == p = Just (drop (length p) s)
      | otherwise              = Nothing

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
      | Just v <- stripEq "-o=" a       = matchExt v
      | Just v <- stripEq "--out-dir=" a = matchExt v
      | otherwise = pickValue rest

    stripEq p s
      | take (length p) s == p = Just (drop (length p) s)
      | otherwise              = Nothing

    matchExt :: FilePath -> Maybe String
    matchExt v = case takeExtension v of
      ".html" -> Just "html"
      ".json" -> Just "json"
      ".dot"  -> Just "dot"
      _       -> Nothing

