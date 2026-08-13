{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
-- | @agda-deps doctor@ — a standalone sanity check of the YAML config
-- file. No Agda run, no input module: it resolves the config the way a
-- real run would ("AgdaDeps.Config" discovery), then reports
--
--   * discovery + parse problems (which file, does it parse, is it a mapping);
--   * unknown keys (silently ignored by @FromJSON Config@ — the most common
--     way a config \"does nothing\"), with a did-you-mean suggestion;
--   * per-key type and domain errors (a colour that is not @#RRGGBB@, a
--     negative @max-snippet-bytes@, an unknown @view:@ slug, a @null@ value
--     from an unquoted @#…@ that YAML read as a comment);
--   * coherence: keys that are individually valid but do nothing in
--     combination (@with-source@ without @lazy@, @cache-dir@ without
--     @incremental@, a @view@ under @format: dot@, …).
--
-- Exit status is 1 when any error was found (or, under @--strict@, any
-- warning), 0 otherwise — so it can gate CI.
--
-- The accepted key set here mirrors @FromJSON Config@; the two are
-- diff-checked by @schema\/show_defaults_check.py@ (each key is declared
-- as @field \"\<key\>\" …@ so the guard can find it).
module AgdaDeps.Doctor
  ( isDoctorCommand
  , runDoctor
  ) where

import Control.Exception ( SomeException, displayException, try )
import Control.Monad ( forM, unless )
import Data.Foldable ( toList )
import Data.List ( intercalate, isInfixOf, isSuffixOf, sortOn, stripPrefix )
import Data.Maybe ( catMaybes, fromMaybe, isJust, mapMaybe )

import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types ( JSONPathElement(..) )
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Text as T
import qualified Data.Yaml as Y
import Data.Yaml.Internal ( Warning(..) )

import System.Directory ( doesDirectoryExist, doesFileExist, getCurrentDirectory )
import System.Exit ( exitFailure, exitSuccess, exitWith, ExitCode(..) )
import System.FilePath ( takeExtension, takeFileName )
import System.IO ( hPutStrLn, stderr )

import AgdaDeps.Config
  ( ConfigOrigin, allThemes, describeOrigin, extractConfigArg
  , findConfigPath, themeSlug )
import AgdaDeps.Options
  ( allFormats, allJsonModes, allViews, formatSlug, jsonModeSlug, viewSlug )
import AgdaDeps.Util ( isValidHexColor )

-- ---------------------------------------------------------------------------
-- Command detection + usage
-- ---------------------------------------------------------------------------

-- | True when argv starts with the @doctor@ subcommand. Position is
-- significant: a bare @doctor@ anywhere else in argv is more likely a
-- directory or module name than a command.
isDoctorCommand :: [String] -> Bool
isDoctorCommand (a : _) = a == "doctor"
isDoctorCommand _       = False

doctorUsage :: String
doctorUsage = unlines
  [ "Usage: agda-deps doctor [--config=PATH] [--strict]"
  , ""
  , "Check the YAML config file (.agda-deps.yml) and exit. Reports unknown"
  , "keys, invalid values, and settings that have no effect in combination."
  , "Runs no Agda and needs no input module."
  , ""
  , "  --config=PATH  Check this file instead of the discovered one."
  , "  --strict       Exit non-zero on warnings too, not just errors."
  ]

-- ---------------------------------------------------------------------------
-- Findings
-- ---------------------------------------------------------------------------

-- | Ordered so 'sortOn' floats errors to the top of the report.
data Severity = SevError | SevWarning | SevNote
  deriving (Eq, Ord)

sevLabel :: Severity -> String
sevLabel SevError   = "error"
sevLabel SevWarning = "warning"
sevLabel SevNote    = "note"

data Finding = Finding
  { fSev  :: !Severity
  , fMsg  :: !String          -- ^ one-line statement of the problem
  , fHint :: !(Maybe String)  -- ^ one-line remedy
  }

err, warn, note :: String -> Maybe String -> Finding
err  m h = Finding SevError   m h
warn m h = Finding SevWarning m h
note m h = Finding SevNote    m h

-- | @key: message@, the shape every per-key finding uses.
about :: String -> String -> String
about key msg = key ++ ": " ++ msg

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

-- | Run the doctor over the config file and exit. Takes the full argv
-- (leading @doctor@ included).
runDoctor :: [String] -> IO ()
runDoctor argv
  | any (`elem` ["--help", "-h", "-?"]) argv = putStr doctorUsage >> exitSuccess
  | otherwise = do
      let (mCfgArg, rest) = extractConfigArg argv
          strict = "--strict" `elem` rest
          leftovers = filter (`notElem` ["doctor", "--strict"]) rest
      unless (null leftovers) $ do
        hPutStrLn stderr $
          "agda-deps doctor: unexpected argument(s): " ++ unwords leftovers
        hPutStrLn stderr doctorUsage
        exitWith (ExitFailure 2)

      putStrLn "agda-deps doctor"
      putStrLn ""
      findConfigPath mCfgArg >>= \case
        Left e -> do
          -- A file was named explicitly and is not there: nothing to check.
          putStrLn ("  " ++ padSev SevError ++ stripTool e)
          putStrLn ""
          putStrLn (summaryLine False 1 0)
          exitFailure
        Right Nothing -> do
          cwd <- getCurrentDirectory
          putStrLn ("  config     none found (searched from " ++ cwd ++ ")")
          putStrLn "  order      --config=PATH, $AGDA_DEPS_CONFIG, ./.agda-deps.yml"
          putStrLn "             (or .yaml), then the same names beside the nearest"
          putStrLn "             ancestor *.agda-lib"
          putStrLn ""
          putStrLn "Summary: no config file; every option is at its default."
          exitSuccess
        Right (Just (path, origin)) -> checkFile strict path origin

-- | Check one config file and exit with the appropriate status.
checkFile :: Bool -> FilePath -> ConfigOrigin -> IO ()
checkFile strict path origin = do
  putStrLn ("  config     " ++ path)
  putStrLn ("  origin     " ++ describeOrigin origin)
  -- 'decodeFileWithWarnings', not 'decodeFileEither': it also reports
  -- duplicate keys, which libyaml resolves silently (last one wins).
  parsed <- try (Y.decodeFileWithWarnings path)
              :: IO (Either SomeException
                       (Either Y.ParseException ([Warning], A.Value)))
  findings <- case parsed of
    Left exc -> pure
      [ err ("cannot read the file: " ++ oneLine (displayException exc))
            (Just "check the path and its permissions") ]
    Right (Left perr) -> pure
      [ err ("not valid YAML: " ++ oneLine (Y.prettyPrintParseException perr))
            (Just "YAML is indentation-sensitive; use spaces, never tabs") ]
    -- A comment-only or empty document decodes to Null; that is exactly
    -- what `agda-deps --show-defaults > .agda-deps.yml` produces.
    Right (Right (_, A.Null)) -> do
      putStrLn "  keys       none (file is empty or entirely commented out)"
      pure [ note "no keys are set, so every option keeps its default value"
                  (Just "uncomment the keys you want to change") ]
    Right (Right (ws, A.Object o)) -> do
      putStrLn ("  keys       " ++ show (KM.size o) ++ " set")
      ioFindings <- checkPaths o
      pure (map duplicateKey ws ++ checkKeys o ++ checkCoherence o ++ ioFindings)
    Right (Right (_, v)) -> pure
      [ err ("the top level is " ++ describeValue v ++ ", not a mapping")
            (Just "the file must be a mapping: one `key: value` per line") ]

  let ranked = sortOn fSev findings
      nErr   = length [ () | f <- ranked, fSev f == SevError ]
      nWarn  = length [ () | f <- ranked, fSev f == SevWarning ]

  unless (null ranked) $ do
    putStrLn ""
    mapM_ printFinding ranked
  putStrLn ""
  putStrLn $ if null ranked
    then "Summary: no problems found."
    else summaryLine strict nErr nWarn
  if nErr > 0 || (strict && nWarn > 0) then exitFailure else exitSuccess

-- | @Summary: 2 errors, 1 warning@, plus a reminder when @--strict@ is
-- what turns a warning-only report into a failure.
summaryLine :: Bool -> Int -> Int -> String
summaryLine strict nErr nWarn =
  "Summary: " ++ plural nErr "error" ++ ", " ++ plural nWarn "warning"
    ++ (if strict && nWarn > 0 then " (--strict: warnings fail)" else "")
  where
    plural n w = show n ++ " " ++ w ++ (if n == 1 then "" else "s")

-- | Drop the @agda-deps: @ prefix a shared diagnostic carries for the
-- normal run; inside the report the tool name is already established.
stripTool :: String -> String
stripTool s = fromMaybe s (stripPrefix "agda-deps: " s)

-- | A key written twice. libyaml keeps the last one without a word, so
-- the earlier line is dead text that reads as if it were in effect.
duplicateKey :: Warning -> Finding
duplicateKey (DuplicateKey path) = err
  (about (renderPath path) "is set more than once; only the last value is used")
  (Just "delete the line that does not apply")
  where
    renderPath = intercalate "." . map element
    element (Key k)   = K.toString k
    element (Index i) = "[" ++ show i ++ "]"

printFinding :: Finding -> IO ()
printFinding (Finding sev msg mHint) = do
  putStrLn ("  " ++ padSev sev ++ msg)
  case mHint of
    Nothing -> pure ()
    Just h  -> putStrLn ("  " ++ replicate sevWidth ' ' ++ "fix: " ++ h)

sevWidth :: Int
sevWidth = 9

padSev :: Severity -> String
padSev sev = take sevWidth (sevLabel sev ++ repeat ' ')

-- | Collapse a multi-line library diagnostic onto one line.
oneLine :: String -> String
oneLine = unwords . words

-- ---------------------------------------------------------------------------
-- The key table
-- ---------------------------------------------------------------------------

-- | A domain check on an already-well-typed value: 'Just' a severity and
-- a complaint when the value is out of range.
type Domain a = a -> Maybe (Severity, String)

-- | What a key's value may be, and the domain check on top of the type.
data FieldTy
  = TyBool
  | TyStr     (Domain String)
  | TyInt     (Domain Int)
  | TyEnum    [String]
  | TyStrList (Domain String)  -- ^ check applied per element

field :: String -> FieldTy -> (String, FieldTy)
field = (,)

-- | Every key @FromJSON Config@ reads, with its accepted shape. Kept in
-- lockstep with "AgdaDeps.Config" by @schema\/show_defaults_check.py@.
knownFields :: [(String, FieldTy)]
knownFields =
  [ field "out-dir"              (TyStr nonEmpty)
  , field "format"               (TyEnum (map formatSlug allFormats))
  , field "view"                 (TyEnum (map viewSlug allViews))
  , field "theme"                (TyEnum (map themeSlug allThemes))
  , field "color-defined"        (TyStr hexColor)
  , field "color-postulate"      (TyStr hexColor)
  , field "color-hole"           (TyStr hexColor)
  , field "color-failed"         (TyStr hexColor)
  , field "with-source"          TyBool
  , field "lazy"                 TyBool
  , field "exclude"              (TyStrList modulePrefix)
  , field "no-source-for"        (TyStrList modulePrefix)
  , field "max-snippet-bytes"    (TyInt nonNegative)
  , field "gzip"                 TyBool
  , field "keep-going"           TyBool
  , field "skip-agda"            TyBool
  , field "incremental"          TyBool
  , field "cache-dir"            (TyStr nonEmpty)
  , field "packed-analytical"    TyBool
  , field "quiet"                TyBool
  , field "no-externals"         TyBool
  , field "json-mode"            (TyEnum (map jsonModeSlug allJsonModes))
  , field "lenient-imports"      TyBool
  , field "resolve-deps"         TyBool
  , field "with-term-hashes"     TyBool
  , field "min-term-depth"       (TyInt positive)
  , field "with-signatures"      TyBool
  , field "normalise-signatures" TyBool
  , field "signature-implicits"  TyBool
  , field "agda-html-dir"        (TyStr nonEmpty)
  ]
  where
    nonEmpty s
      | null s    = Just (SevError, "is empty")
      | otherwise = Nothing
    hexColor s
      | isValidHexColor s = Nothing
      | otherwise = Just
          (SevError, show s ++ " is not a colour of the form \"#RRGGBB\"")
    modulePrefix s
      | null s = Just (SevWarning, "has an empty entry, which matches nothing")
      | ".agda" `isSuffixOf` s || "/" `isInfixOf` s = Just
          (SevWarning, show s ++ " looks like a file path; a module-name"
                             ++ " prefix (e.g. Data.List) is expected")
      | otherwise = Nothing
    nonNegative n
      | n < 0     = Just (SevError, show n ++ " is negative, so it is ignored;"
                                           ++ " use 0 to disable the cap")
      | otherwise = Nothing
    positive n
      | n < 1     = Just (SevError, show n ++ " is below the minimum of 1"
                                           ++ " (1 disables the filter)")
      | otherwise = Nothing

knownKeys :: [String]
knownKeys = map fst knownFields

-- | Colour keys get an extra hint, because the usual way to get them
-- wrong is a YAML one: an unquoted @#RRGGBB@ is a comment.
isColorKey :: String -> Bool
isColorKey k = k `elem` [ "color-defined", "color-postulate"
                        , "color-hole", "color-failed" ]

-- ---------------------------------------------------------------------------
-- Key + value checks
-- ---------------------------------------------------------------------------

checkKeys :: A.Object -> [Finding]
checkKeys o = concatMap check (KM.toList o)
  where
    check (k, v) =
      let key = K.toString k
      in case lookup key knownFields of
           Nothing -> [unknownKey key]
           Just ty -> checkValue key ty v

unknownKey :: String -> Finding
unknownKey key = err
  (about key "unknown key; it is silently ignored")
  (case nearest key knownKeys of
     Just alt -> Just ("did you mean `" ++ alt ++ "`?")
     Nothing  -> Just ("run `agda-deps --show-defaults` for every"
                       ++ " accepted key"))

-- | Type- and domain-check one key's value.
checkValue :: String -> FieldTy -> A.Value -> [Finding]
checkValue key _ A.Null =
  [ err (about key "value is null, so the key is ignored")
        (Just (if isColorKey key
                 then "quote the colour — an unquoted #RRGGBB is a YAML"
                      ++ " comment, e.g. " ++ key ++ ": \"#4caf50\""
                 else "give the key a value, or delete the line")) ]
checkValue key ty v = case ty of
  TyBool -> case v of
    A.Bool _ -> []
    _ -> [wrongType key "true or false" v
            (Just "unquoted `true` / `false`; a quoted \"true\" is a string")]
  TyStr dom -> case v of
    A.String t -> domain key (dom (T.unpack t))
    _ -> [wrongType key "a string" v Nothing]
  TyInt dom -> case v of
    A.Number _ -> case A.fromJSON v :: A.Result Int of
      A.Success n -> domain key (dom n)
      A.Error _   -> [wrongType key "a whole number" v Nothing]
    _ -> [wrongType key "a whole number" v Nothing]
  TyEnum slugs -> case v of
    A.String t ->
      let s = T.unpack t
      in if s `elem` slugs
           then []
           else [ err (about key (show s ++ " is not a recognised value"))
                      (Just (case nearest s slugs of
                               Just alt -> "did you mean `" ++ alt ++ "`? one of: "
                                             ++ intercalate ", " slugs
                               Nothing  -> "one of: " ++ intercalate ", " slugs)) ]
    _ -> [wrongType key ("one of: " ++ intercalate ", " slugs) v Nothing]
  TyStrList dom -> case v of
    A.Array xs ->
      let items = toList xs
          bad   = [ wrongType key "a list of strings" x Nothing
                  | x <- items, not (isString x) ]
          doms  = concat [ domain key (dom (T.unpack t))
                         | A.String t <- items ]
      in bad ++ doms
    _ -> [wrongType key "a list" v
            (Just ("write it as a list, e.g. " ++ key ++ ": [Agda.Builtin, Data]"))]
  where
    isString = \case A.String _ -> True; _ -> False
    domain k = maybe [] (\(sev, m) -> [Finding sev (about k m) Nothing])

wrongType :: String -> String -> A.Value -> Maybe String -> Finding
wrongType key expected v hint = err
  (about key ("expected " ++ expected ++ ", got " ++ describeValue v
              ++ " (" ++ showVal v ++ ")"))
  hint

describeValue :: A.Value -> String
describeValue = \case
  A.Null     -> "null"
  A.Bool _   -> "a boolean"
  A.Number _ -> "a number"
  A.String _ -> "a string"
  A.Array _  -> "a list"
  A.Object _ -> "a mapping"

showVal :: A.Value -> String
showVal = truncateTo 40 . LBS.unpack . A.encode
  where
    truncateTo n s
      | length s <= n = s
      | otherwise     = take n s ++ "…"

-- | Closest key by edit distance, when it is close enough to be a
-- plausible typo (a third of the length, at least 1, at most 4).
nearest :: String -> [String] -> Maybe String
nearest s candidates = case sortOn snd scored of
  ((c, d) : _) | d <= budget -> Just c
  _ -> Nothing
  where
    scored = [ (c, editDistance s c) | c <- candidates ]
    budget = max 1 (min 4 (length s `div` 3))

-- | Plain Levenshtein distance; the strings here are short config keys.
editDistance :: String -> String -> Int
editDistance a b = last (foldl step [0 .. length a] b)
  where
    step prev@(p : ps) c = scanl next (p + 1) (zip3 a prev ps)
      where
        next left (ca, diag, up) =
          minimum [left + 1, up + 1, diag + if ca == c then 0 else 1]
    step [] _ = []

-- ---------------------------------------------------------------------------
-- Coherence
-- ---------------------------------------------------------------------------

-- | Cross-key checks: each setting is individually valid, but the
-- combination does nothing (or less than the user expects).
--
-- Read the config alone: CLI flags are layered on top at run time and can
-- rescue any of these, hence 'SevWarning' rather than 'SevError'.
checkCoherence :: A.Object -> [Finding]
checkCoherence o = catMaybes
  [ -- Output format gates most of the feature flags.
    whenTrue "lazy" (fmtNot "html") $
      warn (about "lazy" ("splits HTML output, but format is " ++ fmt))
           (Just "set format: html, or drop lazy")
  , if isTrue "with-source" && fmtNot "html"
      then Just $ warn
        (about "with-source" ("embeds snippets in HTML output, but format is "
                              ++ fmt))
        (Just "set format: html, or drop with-source")
      else whenTrue "with-source" (not (isTrue "lazy")) $
        warn (about "with-source" "has no effect without lazy: true")
             (Just ("add lazy: true (the output then needs HTTP serving),"
                    ++ " or link out with agda-html-dir"))
  , whenSet "no-source-for" (not (isTrue "with-source")) $
      warn (about "no-source-for" "only filters snippets, and with-source is off")
           (Just "add with-source: true, or drop no-source-for")
  , whenSet "max-snippet-bytes" (not (isTrue "with-source")) $
      warn (about "max-snippet-bytes" "only caps snippets, and with-source is off")
           (Just "add with-source: true, or drop max-snippet-bytes")
  , whenSet "view" (fmtNot "html") $
      warn (about "view" ("selects the HTML app, but format is " ++ fmt))
           (Just "set format: html, or drop view")
  , whenSet "agda-html-dir" (fmtNot "html") $
      warn (about "agda-html-dir" ("only links HTML views, but format is " ++ fmt))
           (Just "set format: html, or drop agda-html-dir")
  , whenSet "json-mode" (fmtNot "json") $
      warn (about "json-mode" ("shapes JSON output, but format is " ++ fmt))
           (Just "set format: json, or drop json-mode")
  , whenTrue "packed-analytical" (fmtNot "json") $
      warn (about "packed-analytical" ("only affects JSON output, but format is "
                                       ++ fmt))
           (Just "set format: json, or drop packed-analytical")
  , whenTrue "packed-analytical" (fmtIs "json" && jsonModeIs "expanded") $
      warn (about "packed-analytical"
                  "only adds arrays to packed JSON, and json-mode is expanded")
           (Just "expanded already carries them; drop packed-analytical")
  , jsonOnly "with-signatures" "reified type signatures"
  , jsonOnly "with-term-hashes" "subterm hashes"
  , whenTrue "normalise-signatures" (not (isTrue "with-signatures")) $
      warn (about "normalise-signatures" "has no effect without with-signatures")
           (Just "add with-signatures: true, or drop normalise-signatures")
  , whenTrue "signature-implicits" (not (isTrue "with-signatures")) $
      warn (about "signature-implicits" "has no effect without with-signatures")
           (Just "add with-signatures: true, or drop signature-implicits")
  , whenSet "min-term-depth" (not (isTrue "with-term-hashes")) $
      warn (about "min-term-depth" "has no effect without with-term-hashes")
           (Just "add with-term-hashes: true, or drop min-term-depth")
  , whenTrue "incremental" (isTrue "keep-going") $
      warn (about "incremental" "is disabled under keep-going")
           (Just "drop one of the two; a partial run is never cached")
  , whenSet "cache-dir" (not (isTrue "incremental")) $
      warn (about "cache-dir" "only locates the incremental cache, which is off")
           (Just "add incremental: true, or drop cache-dir")
  , whenTrue "gzip" (isJust mFmt && not (fmtIs "html" && isTrue "lazy")) $
      warn (about "gzip" ("only compresses the JSON files written by the"
                          ++ " lazy HTML path"))
           (Just "use format: html with lazy: true, or drop gzip")
  , if fmtIs "html" && not (isSet "out-dir")
      then Just $ note
        (about "format" "html writes into a directory, and out-dir is not set")
        (Just "pass -o DIR on the command line, or set out-dir here")
      else Nothing
  , do -- out-dir carrying a format extension: inference is CLI-only.
      dir <- str "out-dir"
      f <- mFmt
      let ext = drop 1 (takeExtension dir)
      if ext `elem` map formatSlug allFormats && ext /= f
        then Just $ warn
          (about "out-dir" (show (takeFileName dir) ++ " looks like a "
                            ++ ext ++ " file, but format is " ++ f))
          (Just ("extension-based format inference only applies to -o on the"
                 ++ " command line; set format: " ++ ext ++ " explicitly"))
        else Nothing
  , case filter isSet colorKeys of
      []   -> Nothing
      set_ | isSet "theme" -> Just $ note
        (about "theme" ("sets all four state colours; "
                        ++ intercalate ", " set_
                        ++ (if length set_ == 1
                              then " then overrides its slot"
                              else " then override their slots")))
        Nothing
      _ -> Nothing
  ]
  ++ skipAgdaFindings
  where
    val k     = KM.lookup (K.fromString k) o
    isSet k   = case val k of
      Nothing      -> False
      Just A.Null  -> False  -- an ignored value; already reported
      Just _       -> True
    str k     = case val k of Just (A.String t) -> Just (T.unpack t); _ -> Nothing
    isTrue k  = val k == Just (A.Bool True)
    colorKeys = filter isColorKey knownKeys

    -- An enum key resolves to its default when absent, and to 'Nothing'
    -- when its value is not a recognised slug — 'checkValue' already
    -- reported that, and every check downstream of it would be guesswork.
    resolve k dflt slugs = case str k of
      Nothing -> Just dflt
      Just s | s `elem` slugs -> Just s
             | otherwise      -> Nothing
    mFmt      = resolve "format" "dot" (map formatSlug allFormats)
    mJsonMode = resolve "json-mode" "packed" (map jsonModeSlug allJsonModes)

    -- 'fmt' is for the message text, and is only reached under a
    -- 'fmtIs' / 'fmtNot' guard, both of which imply @isJust mFmt@.
    fmt          = fromMaybe "dot" mFmt
    fmtIs x      = mFmt == Just x
    fmtNot x     = maybe False (/= x) mFmt
    jsonModeIs x = mJsonMode == Just x

    whenTrue k cond f = if isTrue k && cond then Just f else Nothing
    whenSet  k cond f = if isSet  k && cond then Just f else Nothing

    -- with-signatures / with-term-hashes only reach the wire through JSON.
    jsonOnly k what
      | not (isTrue k) = Nothing
      | fmtNot "json" = Just $ warn
          (about k (what ++ " are only emitted in JSON output, but format is "
                    ++ fmt))
          (Just "set format: json, or drop it")
      | fmtIs "json" && jsonModeIs "packed" && not (isTrue "packed-analytical") =
          Just $ warn
          (about k (what ++ " are dropped by packed JSON"))
          (Just "add json-mode: expanded, or packed-analytical: true")
      | otherwise = Nothing

    -- --skip-agda never type-checks, so nothing definition-level survives.
    skipAgdaFindings
      | not (isTrue "skip-agda") = []
      | otherwise = mapMaybe moot
          [ ("with-source",      "there are no definitions to snapshot")
          , ("with-signatures",  "there are no elaborated types")
          , ("with-term-hashes", "there are no elaborated terms")
          , ("incremental",      "nothing is type-checked to cache")
          , ("keep-going",       "there is no type-check to survive")
          , ("lenient-imports",  "Agda is never invoked")
          ]
      where
        moot (k, why) = whenTrue k True $
          warn (about k ("has no effect under skip-agda: " ++ why))
               (Just ("drop skip-agda to get definition-level output,"
                      ++ " or drop " ++ k))

-- ---------------------------------------------------------------------------
-- Filesystem checks
-- ---------------------------------------------------------------------------

-- | The two config keys that name a directory @agda-deps@ will create.
-- A regular file sitting on either path fails the run at write time.
checkPaths :: A.Object -> IO [Finding]
checkPaths o = fmap catMaybes . forM ["out-dir", "cache-dir"] $ \k ->
  case KM.lookup (K.fromString k) o of
    Just (A.String t) | let p = T.unpack t, not (null p) -> do
      isFile <- doesFileExist p
      isDir  <- doesDirectoryExist p
      pure $ if isFile && not isDir
        then Just $ err
          (about k (show (T.unpack t) ++ " exists and is a regular file"))
          (Just "agda-deps creates this path as a directory; move or rename it")
        else Nothing
    _ -> pure Nothing
