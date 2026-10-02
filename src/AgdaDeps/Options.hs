{-# LANGUAGE DeriveGeneric #-}
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

    -- * Slug tables
  , parseSlug

    -- * Definition state
  , DefState(..)
  , defStateCode
  , colorFor

    -- * Colour palette
  , ColorPalette(..)
  , defaultPalette
  , applyCliPalette

    -- * Options
  , Options(..)
  , defaultOptions
  , lazyTreeOutput

    -- * Shared scalar validation
  , validateColor
  , validateMinTermDepth

    -- * CLI option parsers
  , outdirOpt
  , formatOpt
  , lazyOpt
  , colorOpt
  , excludeOpt
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
  , withTypeTermsOpt
  , withSignaturesOpt
  , normaliseSignaturesOpt
  , showImplicitOpt

    -- * Module-exclusion predicate
  , isExcludedModule
  ) where

import Control.DeepSeq ( NFData )
import Control.Monad.Except ( MonadError(throwError) )
import Data.Binary ( Binary(..) )
import qualified Data.Binary as B
import Data.List ( intercalate, isPrefixOf )
import Data.Word ( Word8 )
import GHC.Generics ( Generic )

import AgdaDeps.Util ( fromCode, isValidHexColor )

-- | DOT or JSON output. HTML rendering lives in @agda-plotter@, which
-- reads the @graph.json@ this emits.
data OutputFormat = FmtDot | FmtJson
  deriving (Show, Eq, Generic)

-- | How @--format=json@ emits the v2 graph. Packed: CSR adjacency +
-- per-def state as base64 typed arrays. Expanded: definitions as records,
-- edges as qname pairs.
data JsonMode = JsonPacked | JsonExpanded
  deriving (Show, Eq, Generic)

instance NFData JsonMode
instance NFData OutputFormat

-- | Canonical CLI slug for an 'OutputFormat'.
formatSlug :: OutputFormat -> String
formatSlug FmtDot  = "dot"
formatSlug FmtJson = "json"

-- | Every 'OutputFormat', in the order accepted values are listed to the
-- user. Together with 'formatSlug' this is the single source of truth for
-- @--format@ \/ @format:@ — CLI parser, YAML parser, and @doctor@ all
-- derive their accepted set from it.
allFormats :: [OutputFormat]
allFormats = [FmtDot, FmtJson]

-- | Canonical CLI slug for a 'JsonMode'.
jsonModeSlug :: JsonMode -> String
jsonModeSlug JsonPacked   = "packed"
jsonModeSlug JsonExpanded = "expanded"

-- | Every 'JsonMode'. See 'allFormats'.
allJsonModes :: [JsonMode]
allJsonModes = [JsonPacked, JsonExpanded]

-- | Resolve a user-supplied slug against a canonical table, or produce the
-- standard \"Unknown …\" diagnostic naming every accepted value. @what@ is
-- how the setting is spelled in the message (@\"--format\"@ for a CLI flag,
-- @\"format\"@ for the YAML key).
parseSlug :: String -> (a -> String) -> [a] -> String -> Either String a
parseSlug what slug vals s = case [ v | v <- vals, slug v == s ] of
  (v:_) -> Right v
  []    -> Left $ "Unknown " ++ what ++ " value: " ++ show s
               ++ ". Expected one of: " ++ intercalate ", " (map slug vals) ++ "."

-- | The state of a definition for the purpose of node colouring.
--
-- 'Failed' is synthetic: there is no real 'Definition' behind it. It
-- tags a bare-module node emitted when Agda's type-checker raised a
-- 'TCErr' under @--keep-going@ (see 'AgdaDeps.Backend.failedModulesRef').
--
-- Constructor order is the schema's @state@ enum order ('Bounded' /
-- 'Enum' enumerate it); the numeric code is 'defStateCode', not
-- 'fromEnum'.
data DefState = Defined | Postulate | Hole | Failed
  deriving (Show, Eq, Enum, Bounded, Generic)

instance NFData DefState

-- | Stable numeric code shared by packed output and the fragment cache.
defStateCode :: DefState -> Word8
defStateCode Defined   = 0
defStateCode Postulate = 1
defStateCode Hole      = 2
defStateCode Failed    = 3

-- | Tagged 'Word8' encoding for the @--incremental@ fragment cache.
instance Binary DefState where
  put = B.putWord8 . defStateCode
  get = B.getWord8 >>= maybe (fail "DefState") pure . fromCode defStateCode

-- | Hex (\"#rrggbb\") colours for each 'DefState'.
data ColorPalette = ColorPalette
  { colorDefined   :: String
  , colorPostulate :: String
  , colorHole      :: String
  , colorFailed    :: String
  } deriving (Show, Eq, Generic)

instance NFData ColorPalette

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

setColorFor :: DefState -> String -> ColorPalette -> ColorPalette
setColorFor Defined   s p = p{ colorDefined   = s }
setColorFor Postulate s p = p{ colorPostulate = s }
setColorFor Hole      s p = p{ colorHole      = s }
setColorFor Failed    s p = p{ colorFailed    = s }

-- | Replace the base palette while retaining each explicit CLI colour.
-- YAML colours do not mark slots, so a CLI theme still overrides them.
applyCliPalette :: ColorPalette -> Options -> Options
applyCliPalette palette opts = opts
  { optColors = foldl retain palette (optCliColorOverrides opts) }
  where
    retain p state = setColorFor state (colorFor (optColors opts) state) p

-- | The full set of backend options, populated from CLI flags.
data Options = Options
  { optOutDir     :: Maybe FilePath
  , optFormat     :: OutputFormat
  , optColors     :: ColorPalette
  , optCliColorOverrides :: [DefState]
    -- ^ Parser bookkeeping: slots explicitly set by CLI flags. At most
    -- four entries; not a YAML option or serialized cache/wire field.
  , optLazy       :: Bool
    -- ^ @--lazy@: split @--format=json@ output into a module-level
    -- @graph.json@ plus per-module @modules\/\<Module\>.json@ detail
    -- files, instead of one monolithic @deps.json@. Consumed by
    -- @agda-plotter@'s page shell, which fetches them on demand.
  , optExcludeModules :: [String]
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
  , optWithTypeTerms :: Bool
    -- ^ Opt-in structural type DAG, expanded JSON only; no incremental cache.
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
  } deriving (Generic)

-- | Agda's backend interface requires 'NFData' for the options record;
-- the 'Generic' default forces every field, so new fields need no edit.
instance NFData Options

defaultOptions :: Options
defaultOptions = Options
  { optOutDir          = Nothing
  , optFormat          = FmtDot
  , optColors          = defaultPalette
  , optCliColorOverrides = []
  , optLazy            = False
  , optExcludeModules  = []
  , optGzip            = False
  , optKeepGoing       = False
  , optSkipAgda        = False
  , optQuiet           = False
  , optNoExternals     = False
  , optJsonMode        = JsonPacked
  , optLenientImports  = False
  , optWithTermHashes  = False
  , optMinTermDepth    = 3
  , optWithTypeTerms   = False
  , optWithSignatures  = False
  , optNormaliseSignatures = False
  , optShowImplicit    = False
  , optIncremental     = False
  , optCacheDir        = Nothing
  , optPackedAnalytical = False
  }

-- | Whether this run writes the @--lazy@ output /tree/ — a module-level
-- @graph.json@ plus per-module @modules\/\<Module\>.json@ detail files —
-- rather than one monolithic file.
--
-- @--lazy@ only splits the packed form; 'AgdaDeps.Backend.GraphJson'
-- @buildExpandedJson@ has no such split, so the flag is inert under
-- @--json-mode=expanded@. Single source of truth: the graph emitter, the
-- output writer, the no-op skip and the @--skip-agda@ path all ask this
-- one question, and a second copy would be free to drift.
lazyTreeOutput :: Options -> Bool
lazyTreeOutput opts = optLazy opts && optJsonMode opts == JsonPacked

-- | True when the given module name matches any of the configured
-- exclusion prefixes.
isExcludedModule :: [String] -> String -> Bool
isExcludedModule excludes m = any matches excludes
  where
    matches p = p == m || (p ++ ".") `isPrefixOf` m

-- ** CLI option parsers

outdirOpt :: Monad m => FilePath -> Options -> m Options
outdirOpt dir opts = return opts{ optOutDir = Just dir }

lazyOpt :: Monad m => Options -> m Options
lazyOpt opts = return opts{ optLazy = True }

excludeOpt :: Monad m => String -> Options -> m Options
excludeOpt p opts = return opts{ optExcludeModules = p : optExcludeModules opts }

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
  [(n, "")] -> case validateMinTermDepth n of
    Right depth -> return opts{ optMinTermDepth = depth }
    Left e -> invalid e
  _ -> invalid minTermDepthExpected
  where
    invalid e = throwError $
      "Invalid value for --min-term-depth: " ++ show s ++ ". " ++ e

-- | Domain rules shared by CLI parsing, YAML decoding, and doctor.
validateColor :: String -> Either String String
validateColor s
  | isValidHexColor s = Right s
  | otherwise = Left "Expected a hex colour of the form #RRGGBB."

validateMinTermDepth :: Int -> Either String Int
validateMinTermDepth n
  | n >= 1 = Right n
  | otherwise = Left minTermDepthExpected

minTermDepthExpected :: String
minTermDepthExpected = "Expected a positive integer (1 disables the filter)."

formatOpt :: MonadError String m => String -> Options -> m Options
formatOpt s opts = case parseSlug "--format" formatSlug allFormats s of
  Right f -> return opts{ optFormat = f }
  Left e  -> throwError e

-- | Build a CLI option parser that updates a single slot of 'optColors',
-- validating the hex syntax.
colorOpt
  :: MonadError String m
  => String                                   -- ^ flag name (for error message)
  -> DefState                                 -- ^ palette slot
  -> String -> Options -> m Options
colorOpt flagName state s opts = case validateColor s of
  Right color -> return opts
    { optColors = setColorFor state color (optColors opts)
    , optCliColorOverrides = state : filter (/= state) (optCliColorOverrides opts)
    }
  Left e -> throwError $
      "Invalid value for --" ++ flagName ++ ": " ++ show s
        ++ ". " ++ e

withTypeTermsOpt :: Monad m => Options -> m Options
withTypeTermsOpt opts = return opts { optWithTypeTerms = True }
