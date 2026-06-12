{-# LANGUAGE ScopedTypeVariables #-}

-- | Template-Haskell helper behind "BuildInfo", in its own module for
-- the GHC stage restriction.
--
-- 'gitRevisionE' shells out to @git@ once at build time and lifts the
-- short revision into a string literal, registering @.git/HEAD@ and the
-- resolved ref as dependent files so a checkout retriggers
-- recompilation. Any git failure yields @"unknown"@.
module BuildInfoTH
  ( gitRevisionE
  ) where

import           Control.Exception          (SomeException, catch, try)
import           Control.Monad              (filterM)
import           Language.Haskell.TH         (Exp, Q, runIO)
import           Language.Haskell.TH.Syntax  (addDependentFile, lift)
import           System.Directory            (doesFileExist)
import           System.Environment          (lookupEnv)
import           System.Exit                 (ExitCode (..))
import           System.Process              (readProcessWithExitCode)

-- | Capture the git revision at compile time as a string-literal 'Exp'.
gitRevisionE :: Q Exp
gitRevisionE = do
  files <- runIO listGitFiles
  mapM_ addDependentFile files
  rev <- runIO captureGit
  lift rev

-- | @.git/HEAD@ plus the file the symbolic ref points at, when they
-- exist. Used purely for 'addDependentFile' recompilation tracking.
listGitFiles :: IO [FilePath]
listGitFiles = do
  let headFile = ".git/HEAD"
  he <- doesFileExist headFile
  if not he
    then pure []
    else do
      contents <- readFile headFile `catch` \(_ :: SomeException) -> pure ""
      let refFile = case words contents of
            ["ref:", r] -> [".git/" ++ r]
            _           -> []
      refs <- filterM doesFileExist refFile
      pure (headFile : refs)

-- | Run a @git@ command at build time, returning its stdout on success
-- and 'Nothing' on any failure (no git, no repo, non-zero exit).
runGit :: [String] -> IO (Maybe String)
runGit args = do
  r <- try (readProcessWithExitCode "git" args "")
         :: IO (Either SomeException (ExitCode, String, String))
  pure $ case r of
    Right (ExitSuccess, out, _) -> Just out
    _                           -> Nothing

-- | The short revision, with a @+@ suffix when the tree is dirty.
--
-- When @git@ yields a revision (the common dev build, in-tree), that
-- wins and the result is byte-identical to before. When @git@ fails —
-- notably an sdist build under @cabal install@, which has no @.git@ —
-- fall back to the @AGDA_DEPS_GIT_REV@ environment variable so an
-- installer can still stamp the revision
-- (@AGDA_DEPS_GIT_REV=$(git rev-parse --short=12 HEAD) cabal install …@);
-- only if that is also unset do we report @"unknown"@.
captureGit :: IO String
captureGit = do
  mrev <- runGit ["rev-parse", "--short=12", "HEAD"]
  case mrev of
    Just rev -> do
      dirty <- gitDirty
      pure (trim rev ++ if dirty then "+" else "")
    Nothing  -> do
      menv <- lookupEnv "AGDA_DEPS_GIT_REV"
      pure $ case menv of
        Just v | not (null (trim v)) -> trim v
        _                            -> "unknown"
  where
    trim = reverse . dropWhile (`elem` (" \r\n\t" :: String)) . reverse

-- | True when @git status --porcelain@ reports any change.
gitDirty :: IO Bool
gitDirty = maybe False (not . all (`elem` (" \r\n\t" :: String))) <$> runGit ["status", "--porcelain"]
