-- | Template-Haskell helper behind "BuildInfo". Lives in its own module
-- because GHC's stage restriction forbids a top-level splice from using
-- a generator defined in the same module.
--
-- 'gitRevisionE' queries @git@ at build time and lifts the
-- short revision into a string literal, registering @.git/HEAD@ and the
-- resolved ref as dependent files so a checkout retriggers
-- recompilation. Environment overrides support tarball builds without @.git@.
module BuildInfoTH
  ( gitRevisionE
  ) where

import           Control.Exception          (SomeException, try)
import           Control.Monad              (filterM)
import           Language.Haskell.TH         (Exp, Q, loc_filename, location, runIO)
import           Language.Haskell.TH.Syntax  (addDependentFile, lift)
import           System.Directory            (doesFileExist, makeAbsolute)
import           System.Environment          (lookupEnv)
import           System.Exit                 (ExitCode (..))
import           System.FilePath             (takeDirectory)
import           System.Process              (readProcessWithExitCode)

-- | Capture the git revision at compile time as a string-literal 'Exp'.
gitRevisionE :: Q Exp
gitRevisionE = do
  source <- loc_filename <$> location
  root <- runIO $ makeAbsolute (takeDirectory $ takeDirectory source)
  files <- runIO $ listGitFiles root
  mapM_ addDependentFile files
  rev <- runIO $ captureGit root
  lift rev

-- | Track HEAD, its symbolic ref and packed refs, including in worktrees.
-- Used purely for 'addDependentFile' recompilation tracking.
listGitFiles :: FilePath -> IO [FilePath]
listGitFiles root = do
  ref <- runGit root ["symbolic-ref", "-q", "HEAD"]
  paths <- mapM (\name -> runGit root ["rev-parse", "--path-format=absolute", "--git-path", name])
    (["HEAD", "packed-refs"] ++ maybe [] (pure . trim) ref)
  filterM doesFileExist [trim path | Just path <- paths]

-- | Run a @git@ command at build time, returning its stdout on success
-- and 'Nothing' on any failure (no git, no repo, non-zero exit). Never
-- throws — a tarball build just gets 'Nothing'.
runGit :: FilePath -> [String] -> IO (Maybe String)
runGit root args = do
  r <- try (readProcessWithExitCode "git" (["-C", root] ++ args) "")
         :: IO (Either SomeException (ExitCode, String, String))
  pure $ case r of
    Right (ExitSuccess, out, _) -> Just out
    _                           -> Nothing

-- | Prefer @AGDA_BUILD_REVISION@; otherwise use git with a dirty @+@ suffix,
-- falling back to @AGDA_DEPS_GIT_REV@ and then @"unknown"@ outside a checkout.
captureGit :: FilePath -> IO String
captureGit root = do
  explicit <- revisionFromEnv "AGDA_BUILD_REVISION"
  case explicit of
    Just revision -> pure revision
    Nothing -> do
      mrev <- runGit root ["rev-parse", "--short=12", "HEAD"]
      case mrev of
        Nothing  -> do
          maybe "unknown" id <$> revisionFromEnv "AGDA_DEPS_GIT_REV"
        Just rev -> do
          dirty <- gitDirty root
          pure (trim rev ++ if dirty then "+" else "")

-- Build fingerprints occupy one line in diagnostics and graph metadata.
revisionFromEnv :: String -> IO (Maybe String)
revisionFromEnv name = do
  value <- lookupEnv name
  pure $ case value of
    Just revision | not (null (trim revision)), all (`notElem` "\r\n") revision ->
      Just (trim revision)
    _ -> Nothing

trim :: String -> String
trim = reverse . dropWhile (`elem` (" \r\n\t" :: String)) . reverse

-- | True when @git status --porcelain@ reports any change.
gitDirty :: FilePath -> IO Bool
gitDirty root = maybe False (not . null . trim) <$> runGit root ["status", "--porcelain"]
