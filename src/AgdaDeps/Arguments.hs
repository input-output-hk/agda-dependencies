{-# LANGUAGE PatternGuards #-}
-- | One syntax-only argv pass, driven by the actual backend and Agda option
-- descriptors. Preserve order, values and the end-of-options boundary; never
-- inspect an option's value as another flag or positional source file.
module AgdaDeps.Arguments
  ( Argument(..)
  , normalizeArguments, renderArguments, option
  , hasOption, hasBareOption, lastOptionValue, withoutOptions, selectOptions
  , sourceRoots, firstSource, canonicalizeArguments, absoluteAt
  , inferredFormat
  ) where

import Prelude hiding ( foldl' )
import Data.List ( find, isPrefixOf, foldl' )
import Data.Maybe ( listToMaybe )
import System.Directory ( canonicalizePath )
import System.FilePath ( (</>), isAbsolute, takeDirectory, takeExtension )

import Agda.Utils.GetOpt
  ( OptDescr(..), ArgDescr(..), ArgOrder(Permute), getOpt' )
import AgdaDeps.Options ( OutputFormat, allFormats, formatSlug )
import AgdaDeps.Util ( looksLikeAgdaSource )

data Argument
  = Flag String (Maybe String) [String]
    -- ^ Canonical flag name, optional value, equivalent argv spelling.
  | Positional String
  | EndOptions
  | Unknown String
  deriving (Eq, Show)

-- | Construct a known flag. Short values must stay attached, since an
-- optional argument never consumes the next token in GetOpt.
option :: String -> Maybe String -> Argument
option name value = Flag name value [name ++ suffix]
  where
    suffix = case value of
      Nothing -> ""
      Just v | "--" `isPrefixOf` name -> '=' : v
             | otherwise -> v

normalizeArguments :: [OptDescr ()] -> [String] -> Either String [Argument]
normalizeArguments descriptors = go
  where
    go [] = Right []
    go ("--" : rest) = Right (EndOptions : map Positional rest)
    go (a@('-':'-':body) : rest) =
      let (name, suffix) = break (== '=') body
          attached = case suffix of [] -> Nothing; _:v -> Just v
          matches = [ d | d@(Option _ names _ _) <- descriptors, name `elem` names ]
      in case matches of
           [] -> (Unknown a :) <$> go rest
           [Option _ names arity _] ->
             consume a (maybe a ("--" ++) (listToMaybe names)) arity attached rest
           _ -> syntaxError [a]
    go (a@('-':c:body) : rest) =
      let matches = [ d | d@(Option names _ _ _) <- descriptors, c `elem` names ]
          spelling = ['-', c]
          remaining = if null body then rest else ('-' : body) : rest
      in case matches of
           [] -> (Unknown spelling :) <$> go remaining
           [Option _ names arity _] ->
             let name = maybe spelling ("--" ++) (listToMaybe names)
             in case arity of
                  NoArg _ -> (option name Nothing :) <$> go remaining
                  _ -> consume spelling name arity
                         (if null body then Nothing else Just body) rest
           _ -> syntaxError [a]
    go (a : rest) = (Positional a :) <$> go rest

    consume spelling name arity attached rest = case (arity, attached, rest) of
      (NoArg _, Nothing, _) -> (option name Nothing :) <$> go rest
      (NoArg _, Just value, _) -> syntaxError [spelling ++ "=" ++ value]
      (ReqArg _ _, Nothing, []) -> syntaxError [spelling]
      (ReqArg _ _, Nothing, value : more) -> (option name (Just value) :) <$> go more
      (ReqArg _ _, Just value, _) -> (option name (Just value) :) <$> go rest
      (OptArg _ _, value, _) -> (option name value :) <$> go rest

    -- Use upstream diagnostics, including the version-specific ambiguity
    -- rendering; this pass does not execute any option action.
    syntaxError tokens =
      let (_, _, _, errors) = getOpt' Permute descriptors tokens
      in Left (concat errors)

renderArguments :: [Argument] -> [String]
renderArguments = concatMap render
  where
    render (Flag _ _ tokens) = tokens
    render (Positional p) = [p]
    render EndOptions = ["--"]
    render (Unknown a) = [a]

hasOption :: String -> [Argument] -> Bool
hasOption name = any (\a -> case a of Flag n _ _ -> n == name; _ -> False)

hasBareOption :: String -> [Argument] -> Bool
hasBareOption name = any (\a -> case a of Flag n Nothing _ -> n == name; _ -> False)

lastOptionValue :: String -> [Argument] -> Maybe String
lastOptionValue name = foldl' pick Nothing
  where
    pick _ (Flag n value _) | n == name = value
    pick old _ = old

withoutOptions :: [String] -> [Argument] -> [Argument]
withoutOptions names = filter (\a -> case a of Flag n _ _ -> n `notElem` names; _ -> True)

selectOptions :: [OptDescr a] -> [Argument] -> [Argument]
selectOptions descriptors = filter selected
  where
    names = concat [map ("--" ++) long ++ map (\c -> ['-', c]) short
                   | Option short long _ _ <- descriptors]
    selected (Flag name _ _) = name `elem` names
    selected _ = False

sourceRoots :: [Argument] -> [FilePath]
sourceRoots = concatMap root
  where
    root (Flag "--include-path" (Just path) _) = [path]
    root (Positional path) | looksLikeAgdaSource path = [takeDirectory path]
    root _ = []

firstSource :: [Argument] -> Maybe FilePath
firstSource args = case find isSource args of
  Just (Positional path) -> Just path
  _ -> Nothing
  where
    isSource (Positional path) = looksLikeAgdaSource path
    isSource _ = False

absoluteAt :: FilePath -> FilePath -> IO FilePath
absoluteAt base path
  | isAbsolute path = pure path
  | otherwise = canonicalizePath (base </> path)

canonicalizeArguments :: FilePath -> [Argument] -> IO [Argument]
canonicalizeArguments base = mapM absolute
  where
    absolute (Flag name (Just path) _) | name `elem` pathFlags =
      option name . Just <$> absoluteAt base path
    absolute (Positional path) | looksLikeAgdaSource path =
      Positional <$> absoluteAt base path
    absolute arg = pure arg
    pathFlags = ["--out-dir", "--include-path", "--config", "--library-file",
                 "--cache-dir", "--compile-dir"]

-- | Only the last CLI output destination participates. Explicit --format
-- wins; a directory or unknown extension does not inherit an earlier -o.
inferredFormat :: [Argument] -> Maybe OutputFormat
inferredFormat args
  | hasOption "--format" args = Nothing
  | otherwise = do
      path <- lastOptionValue "--out-dir" args
      lookup (takeExtension path) [('.' : formatSlug f, f) | f <- allFormats]
