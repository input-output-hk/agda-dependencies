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
  , themeSlug
  , allThemes
  , parseTheme
  , applyTheme

    -- * Discovery + loading
  , ConfigOrigin(..)
  , describeOrigin
  , findConfigPath
  , findConfigPathFrom
  , discoverConfigPathFrom
  , loadConfig

    -- * Merge
  , applyConfig

    -- * Sample config
  , showDefaultsYaml

  ) where

import Control.Exception ( try, SomeException, displayException )
import Data.Aeson ( FromJSON(..), withObject, (.:?), withText )
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Types as A
import qualified Data.Text as T
import qualified Data.Yaml as Y

import Data.Maybe ( fromMaybe )
import System.Directory ( doesFileExist, getCurrentDirectory )
import System.Environment ( lookupEnv )
import System.Exit ( die )
import System.FilePath ( (</>) )

import AgdaDeps.Arguments ( absoluteAt )
import AgdaDeps.Options
  ( Options(..), OutputFormat(..), JsonMode(..)
  , ColorPalette(..), defaultPalette, defaultOptions, applyCliPalette
  , formatSlug, jsonModeSlug
  , allFormats, allJsonModes, parseSlug
  , validateColor, validateMinTermDepth
  )
import AgdaDeps.Util ( firstExistingFile, nearestAgdaLibAncestor )

-- | YAML config payload. Every field is 'Maybe' so an empty file
-- (@{}@) is valid and individual omissions leave the underlying
-- 'Options' default in place.
data Config = Config
  { cfgOutDir          :: Maybe FilePath
  , cfgFormat          :: Maybe OutputFormat
  , cfgTheme           :: Maybe Theme
  , cfgColorDefined    :: Maybe String
  , cfgColorPostulate  :: Maybe String
  , cfgColorHole       :: Maybe String
  , cfgColorFailed     :: Maybe String
  , cfgLazy            :: Maybe Bool
  , cfgExcludeModules  :: Maybe [String]
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
  } deriving (Show)

defaultConfig :: Config
defaultConfig = Config
  { cfgOutDir          = Nothing
  , cfgFormat          = Nothing
  , cfgTheme           = Nothing
  , cfgColorDefined    = Nothing
  , cfgColorPostulate  = Nothing
  , cfgColorHole       = Nothing
  , cfgColorFailed     = Nothing
  , cfgLazy            = Nothing
  , cfgExcludeModules  = Nothing
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
  }

-- | Preset colour palette. Individual @--color-*@ CLI flags layer on
-- top of a theme, each overriding the slot it targets.
data Theme = ThemeDefault | ThemeLight | ThemeDark | ThemeColorblind
  deriving (Show, Eq)

-- | Canonical slug for a 'Theme'.
themeSlug :: Theme -> String
themeSlug ThemeDefault    = "default"
themeSlug ThemeLight      = "light"
themeSlug ThemeDark       = "dark"
themeSlug ThemeColorblind = "colorblind"

-- | Every 'Theme', in the order accepted values are listed to the user.
-- Single source of truth for @--theme@ \/ @theme:@ (see 'AgdaDeps.Options.allFormats').
allThemes :: [Theme]
allThemes = [ThemeDefault, ThemeLight, ThemeDark, ThemeColorblind]

-- | Parse the @--theme@ / @theme:@ value.
parseTheme :: String -> Either String Theme
parseTheme = parseSlug "theme" themeSlug allThemes

-- | Apply a theme's base palette, preserving explicit CLI colour choices.
-- Config loading starts without CLI choices and overlays YAML colours next.
applyTheme :: Theme -> Options -> Options
applyTheme t = applyCliPalette (themePalette t)

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
  parseJSON = parseEnum "format" (parseSlug "format" formatSlug allFormats)

instance FromJSON JsonMode where
  parseJSON = parseEnum "json-mode" (parseSlug "json-mode" jsonModeSlug allJsonModes)

instance FromJSON Theme where
  parseJSON = parseEnum "theme" parseTheme

-- | An omitted field keeps the default; a supplied value (including null)
-- must pass its parser. Keep the key in diagnostics for domain failures too.
validatedField
  :: A.Object -> A.Key -> (A.Value -> A.Parser a) -> A.Parser (Maybe a)
validatedField o key parse =
  traverse parse (KM.lookup key o) A.<?> A.Key key

parseColor :: A.Value -> A.Parser String
parseColor = withText "a hex colour of the form #RRGGBB (quote it in YAML)" $
  either fail pure . validateColor . T.unpack

parseMinTermDepth :: A.Value -> A.Parser Int
parseMinTermDepth v = do
  n <- A.prependFailure "Expected a positive integer (1 disables the filter): "
         (parseJSON v)
  either fail pure (validateMinTermDepth n)

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
        cfgTheme           <- o .:? "theme"
        cfgColorDefined    <- validatedField o "color-defined" parseColor
        cfgColorPostulate  <- validatedField o "color-postulate" parseColor
        cfgColorHole       <- validatedField o "color-hole" parseColor
        cfgColorFailed     <- validatedField o "color-failed" parseColor
        cfgLazy            <- o .:? "lazy"
        cfgExcludeModules  <- o .:? "exclude"
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
        cfgMinTermDepth    <- validatedField o "min-term-depth" parseMinTermDepth
        cfgWithSignatures  <- o .:? "with-signatures"
        cfgNormaliseSignatures <- o .:? "normalise-signatures"
        cfgShowImplicit    <- o .:? "signature-implicits"
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
      , optColors          = pal'
      , optLazy            = fromMaybe (optLazy       opts1) (cfgLazy       c)
      , optExcludeModules  = fromMaybe (optExcludeModules opts1) (cfgExcludeModules c)
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
  , "# Output directory. Default: none (usually set with -o on the CLI)."
  , "# Note: a .json / .dot extension selects the format only when given"
  , "# as -o on the command line; here it is just a directory name, so set"
  , "# `format:` below as well."
  , "#out-dir: deps"
  , ""
  , "# Output format: dot | json."
  , "#format: " ++ formatSlug (optFormat defaultOptions)
  , ""
  , "# --- Node colours ----------------------------------------------------------"
  , ""
  , "# Colour preset for the four definition states: default | light | dark |"
  , "# colorblind. The color-* keys below override individual slots. Default: none."
  , "# Used by DOT output. agda-plotter takes the same keys for HTML."
  , "#theme: default"
  , ""
  , "# Per-state node colours (#RRGGBB); quote them so YAML doesn't read # as a"
  , "# comment. D = Defined, P = Postulate, H = Hole, F = Failed (--keep-going)."
  , "#color-defined: " ++ yColor (colorDefined defaultPalette)
  , "#color-postulate: " ++ yColor (colorPostulate defaultPalette)
  , "#color-hole: " ++ yColor (colorHole defaultPalette)
  , "#color-failed: " ++ yColor (colorFailed defaultPalette)
  , ""
  , "# --- JSON output -----------------------------------------------------------"
  , ""
  , "# JSON layout: packed (CSR adjacency + base64 typed arrays) | expanded"
  , "# (arrays of records)."
  , "#json-mode: " ++ jsonModeSlug (optJsonMode defaultOptions)
  , ""
  , "# Split JSON output into a module-level graph.json plus per-module"
  , "# modules/<Module>.json detail files, instead of one deps.json. What"
  , "# agda-plotter's lazy page shell fetches. Needs format: json."
  , "#lazy: " ++ yBool (optLazy defaultOptions)
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
  , "# Gzip the JSON files written by the lazy path. Needs lazy: true."
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

-- ---------------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------------

-- | Which step of the search order produced the config file. Carried for
-- diagnostics (@agda-deps doctor@); the loader itself only needs the path.
data ConfigOrigin
  = OriginFlag                  -- ^ explicit @--config=PATH@.
  | OriginEnv                   -- ^ @$AGDA_DEPS_CONFIG@.
  | OriginCwd                   -- ^ dotfile in the current directory.
  | OriginProjectRoot FilePath  -- ^ dotfile beside the @*.agda-lib@ in this dir.
  deriving (Show, Eq)

-- | One-line English rendering of a 'ConfigOrigin'.
describeOrigin :: ConfigOrigin -> String
describeOrigin OriginFlag            = "named by --config"
describeOrigin OriginEnv             = "named by $AGDA_DEPS_CONFIG"
describeOrigin OriginCwd             = "found in the current directory"
describeOrigin (OriginProjectRoot d) =
  "found in the nearest ancestor with a *.agda-lib (" ++ d ++ ")"

-- | Resolve which config file (if any) should be loaded, keeping the
-- provenance. 'Left' is a user error (a file was named but does not
-- exist); @Right Nothing@ means no config file exists anywhere in the
-- search order, which is not an error.
--
-- Precedence (highest first):
--
--   1. Explicit @--config=PATH@ argument. Missing file is an error.
--   2. @$AGDA_DEPS_CONFIG@ environment variable. Missing file is an error.
--   3. @./.agda-deps.yml@ or @./.agda-deps.yaml@ in the current dir.
--   4. Walk up from cwd to the nearest directory containing a
--      @*.agda-lib@; look for the same two filenames there.
--   5. Nothing — no config applied.
findConfigPath :: Maybe FilePath -> IO (Either String (Maybe (FilePath, ConfigOrigin)))
findConfigPath mp = do
  invocationDir <- getCurrentDirectory
  findConfigPathFrom invocationDir mp

-- | Named paths are relative to the invocation directory even after
-- project discovery changes cwd. Automatic dotfiles use the settled cwd.
findConfigPathFrom
  :: FilePath -> Maybe FilePath
  -> IO (Either String (Maybe (FilePath, ConfigOrigin)))
findConfigPathFrom invocationDir (Just path) = do
  p <- absoluteAt invocationDir path
  exists <- doesFileExist p
  pure $ if exists
    then Right (Just (p, OriginFlag))
    else Left ("agda-deps: --config: file not found: " ++ p)
findConfigPathFrom invocationDir Nothing = do
  mEnv <- lookupEnv "AGDA_DEPS_CONFIG"
  case mEnv of
    Just path | not (null path) -> do
      p <- absoluteAt invocationDir path
      exists <- doesFileExist p
      pure $ if exists
        then Right (Just (p, OriginEnv))
        else Left ("agda-deps: $AGDA_DEPS_CONFIG: file not found: " ++ p)
    _ -> do
      cwd <- getCurrentDirectory
      mCwd <- findConfigIn cwd
      case mCwd of
        Just p  -> pure (Right (Just (p, OriginCwd)))
        Nothing -> nearestAgdaLibAncestor cwd >>= \case
          Just root -> Right . fmap (\p -> (p, OriginProjectRoot root))
                         <$> findConfigIn root
          Nothing   -> pure (Right Nothing)
  where
    findConfigIn :: FilePath -> IO (Maybe FilePath)
    findConfigIn d =
      firstExistingFile [d </> ".agda-deps.yml", d </> ".agda-deps.yaml"]

-- | 'findConfigPath' for the normal run: a named-but-missing file is
-- fatal, and the provenance is discarded.
discoverConfigPathFrom :: FilePath -> Maybe FilePath -> IO (Maybe FilePath)
discoverConfigPathFrom invocationDir mp = findConfigPathFrom invocationDir mp >>= \case
  Left err -> die err
  Right r  -> pure (fmap fst r)

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
